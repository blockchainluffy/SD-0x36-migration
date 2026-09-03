// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Step4_EnableModule } from "./Step4_EnableModule.s.sol";
import { Cfg } from "src/Config.sol";
import {
    Choice,
    FinalizationStatus,
    IAuthenticator,
    IAvatarExecutionStrategy,
    ISpace,
    IndexedStrategy,
    MetaTransaction,
    Operation,
    Proposal,
    ProposalStatus,
    Strategy
} from "src/interfaces/ISnapshotX.sol";

/// @title Step 5 — prove the new governance actually governs
/// @notice MIGRATION.md sec 2, doc step 3: "test Snapshot X end-to-end" BEFORE Decent
///         is removed. Runs a real proposal through the new space —
///         propose -> vote -> execute — whose payload moves treasury funds, and
///         asserts the treasury actually moved.
///
///         It then runs three negative controls:
///           * a proposal that loses cannot be executed;
///           * a payload that does not match the proposal's hash is rejected;
///           * a non-whitelisted caller cannot drive the strategy.
///
/// Run:  forge script script/Step5_VerifyVoting.s.sol -vv
contract Step5_VerifyVoting is Step4_EnableModule {
    uint256 internal constant TEST_TRANSFER = 1e18; // 1 SHU

    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _step2();
        _step3();
        _step4();
        _step5();
        _report("Step 5");
        _writeState("5");
    }

    function _step5() internal {
        _banner("STEP 5  |  End-to-end test that Snapshot X voting works");

        // Fund/delegate the simulated electorate first so the treasury readings
        // below only reflect what the proposal itself moves.
        _provisionSimVoters();

        uint256 payeeBefore = shu.balanceOf(Cfg.SIM_PAYEE);
        uint256 treasuryBefore = shu.balanceOf(Cfg.SAFE);

        _section("proposal payload");
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, TEST_TRANSFER),
            operation: Operation.Call,
            salt: 0
        });
        _ok("action: SHU.transfer to", Cfg.SIM_PAYEE);
        _ok("amount (wei):", TEST_TRANSFER);
        _ok("treasury SHU before:", treasuryBefore);

        _section("propose -> vote -> execute");
        uint256 id = _runSnapshotXProposal(txs, "Shutter DAO 0x36: Snapshot X smoke test");

        ISpace s = ISpace(space);
        _section("outcome");
        _ok("proposal id:", id);
        _ok("votes For:", s.votePower(id, Choice.For));
        _ok("votes Against:", s.votePower(id, Choice.Against));
        _ok("votes Abstain:", s.votePower(id, Choice.Abstain));
        check("proposal status", uint256(s.getProposalStatus(id)), uint256(ProposalStatus.Executed));
        checkTrue("quorum reached", s.votePower(id, Choice.For) + s.votePower(id, Choice.Abstain) >= P.quorum);

        _section("treasury effect (the actual proof of control)");
        _ok("payee SHU after:", shu.balanceOf(Cfg.SIM_PAYEE));
        check("payee received the transfer", shu.balanceOf(Cfg.SIM_PAYEE) - payeeBefore, TEST_TRANSFER);
        check("treasury debited", treasuryBefore - shu.balanceOf(Cfg.SAFE), TEST_TRANSFER);

        _section("both governance modules are live during the test window");
        check("Snapshot X strategy enabled", safe.isModuleEnabled(strategy), true);
        check("Azorius still enabled", safe.isModuleEnabled(Cfg.AZORIUS), true);

        _negativeControls();
        _docTestMatrix();
    }

    // =====================================================================
    // Negative controls
    // =====================================================================

    function _negativeControls() internal {
        _banner("STEP 5b  |  Negative controls");

        ISpace s = ISpace(space);
        IAuthenticator auth = IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR);
        IndexedStrategy[] memory userStrategies = _viaShu();

        // --- 1. a losing proposal cannot execute --------------------------
        _section("a rejected proposal cannot be executed");
        MetaTransaction[] memory badTxs = new MetaTransaction[](1);
        badTxs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, 1_000_000e18),
            operation: Operation.Call,
            salt: 1
        });
        bytes memory badPayload = abi.encode(badTxs);
        uint256 badId = s.nextProposalId();

        vm.prank(Cfg.SIM_PROPOSER);
        auth.authenticate(
            space,
            ISpace.propose.selector,
            abi.encode(
                Cfg.SIM_PROPOSER,
                "should fail",
                Strategy({ addr: strategy, params: badPayload }),
                abi.encode(userStrategies)
            )
        );
        if (P.votingDelay > 0) vm.roll(block.number + P.votingDelay);

        // Only an Against vote: quorum over (For + Abstain) is never reached.
        vm.prank(Cfg.SIM_VOTER);
        auth.authenticate(
            space, ISpace.vote.selector, abi.encode(Cfg.SIM_VOTER, badId, Choice.Against, userStrategies, "")
        );
        if (P.minVotingDuration > 0) vm.roll(block.number + P.minVotingDuration);

        uint256 payeeBefore = shu.balanceOf(Cfg.SIM_PAYEE);
        bool reverted;
        try s.execute(badId, badPayload) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("execute() of a rejected proposal reverts", reverted);
        check("no funds moved", shu.balanceOf(Cfg.SIM_PAYEE), payeeBefore);

        // --- 2. payload substitution is rejected ---------------------------
        _section("the executed payload must match the proposal's hash");
        uint256 goodId = s.nextProposalId();
        MetaTransaction[] memory tinyTxs = new MetaTransaction[](1);
        tinyTxs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, uint256(1)),
            operation: Operation.Call,
            salt: 2
        });
        bytes memory goodPayload = abi.encode(tinyTxs);

        vm.prank(Cfg.SIM_PROPOSER);
        auth.authenticate(
            space,
            ISpace.propose.selector,
            abi.encode(
                Cfg.SIM_PROPOSER,
                "payload swap control",
                Strategy({ addr: strategy, params: goodPayload }),
                abi.encode(userStrategies)
            )
        );
        if (P.votingDelay > 0) vm.roll(block.number + P.votingDelay);
        vm.prank(Cfg.SIM_PROPOSER);
        auth.authenticate(
            space, ISpace.vote.selector, abi.encode(Cfg.SIM_PROPOSER, goodId, Choice.For, userStrategies, "")
        );
        // The big voter also votes For, so the proposal clears quorum regardless of its size.
        vm.prank(Cfg.SIM_VOTER);
        auth.authenticate(
            space, ISpace.vote.selector, abi.encode(Cfg.SIM_VOTER, goodId, Choice.For, userStrategies, "")
        );
        if (P.minVotingDuration > 0) vm.roll(block.number + P.minVotingDuration);

        try s.execute(goodId, badPayload) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("execute() with a swapped payload reverts", reverted);

        // The genuine payload still works.
        s.execute(goodId, goodPayload);
        check("genuine payload executes", uint256(s.getProposalStatus(goodId)), uint256(ProposalStatus.Executed));

        _nonSpaceCallerControl(goodPayload);
    }

    /// @dev Only a whitelisted space may drive the strategy; and the Safe has no signing owner.
    function _nonSpaceCallerControl(bytes memory goodPayload) internal {
        _section("only the whitelisted space can drive the strategy");
        Proposal memory forged = Proposal({
            author: Cfg.SIM_PROPOSER,
            startBlockNumber: uint32(block.number - 1),
            executionStrategy: strategy,
            minEndBlockNumber: uint32(block.number - 1),
            maxEndBlockNumber: uint32(block.number + 1000),
            finalizationStatus: FinalizationStatus.Pending,
            executionPayloadHash: keccak256(goodPayload),
            activeVotingStrategies: 1
        });
        bool reverted;
        vm.prank(address(0xbeef));
        try IAvatarExecutionStrategy(strategy).execute(999, forged, type(uint256).max, 0, 0, goodPayload) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("strategy.execute() from a non-space reverts", reverted);

        _section("no multisig backdoor: the sole owner is a contract that cannot sign");
        check("owner count", safe.getOwners().length, 1);
        check("threshold", safe.getThreshold(), 1);
        checkTrue("sole owner has code (cannot produce an ECDSA signature)", Cfg.AZORIUS.code.length > 0);
    }
}

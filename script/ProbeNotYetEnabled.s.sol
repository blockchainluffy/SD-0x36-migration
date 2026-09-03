// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { Step1_CreateSpace } from "./Step1_CreateSpace.s.sol";
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
    ProposalStatus,
    Strategy
} from "src/interfaces/ISnapshotX.sol";

/// @title Probe — what works while the strategy is NOT yet a Safe module?
/// @notice Answers: "if I create the space (and strategy) but hold off on
///         `enableModule`, how much can I test?"
///
///         Deploys space + strategy, deliberately skips `enableModule`, then runs
///         a full proposal through the space and tries to execute it. Afterwards
///         it enables the module and retries the SAME proposal.
///
/// Run:  forge script script/ProbeNotYetEnabled.s.sol -vv
contract ProbeNotYetEnabled is Step1_CreateSpace {
    function run() public override {
        _setUpFork();
        _ensureSpace();

        _banner("PROBE  |  space + strategy live, module NOT enabled");

        // Step 1 already deployed the strategy with the space; the module is what is
        // deliberately missing here.
        checkTrue("strategy deployed", strategy.code.length > 0);
        require(
            !safe.isModuleEnabled(strategy),
            "probe: the strategy is ALREADY a Safe module on this fork, so there is nothing"
            " to probe. Run Step 4 instead."
        );
        check("module NOT enabled", safe.isModuleEnabled(strategy), false);

        // The doc's controller handover, done here with no module enabled, so the veto
        // check below runs as the Security Council multisig.
        _handOverController();

        IAvatarExecutionStrategy st = IAvatarExecutionStrategy(strategy);
        ISpace s = ISpace(space);
        IAuthenticator auth = IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR);

        // --- 1. strategy configuration reads -------------------------------
        _section("1. strategy parameter reads (snapx-strategy.sh check list)");
        check("getStrategyType()", st.getStrategyType(), Cfg.AVATAR_STRATEGY_TYPE);
        check("target()", st.target(), Cfg.SAFE);
        check("owner()", st.owner(), Cfg.SAFE);
        checkQuorum("quorum()", st.quorum(), P.quorum);
        check("isSpaceEnabled(space)", st.isSpaceEnabled(space), 1);

        _provisionSimVoters();

        IndexedStrategy[] memory userStrategies = new IndexedStrategy[](1);
        userStrategies[0] = IndexedStrategy({ index: 0, params: "" });

        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, uint256(1e18)),
            operation: Operation.Call,
            salt: 0
        });
        bytes memory payload = abi.encode(txs);
        uint256 id = s.nextProposalId();

        // --- 2. proposal creation ------------------------------------------
        _section("2. propose() - proposition-power threshold is enforced by the space alone");
        vm.prank(Cfg.SIM_PROPOSER);
        auth.authenticate(
            space,
            ISpace.propose.selector,
            abi.encode(
                Cfg.SIM_PROPOSER,
                "probe: module not yet enabled",
                Strategy({ addr: strategy, params: payload }),
                abi.encode(userStrategies)
            )
        );
        check("proposal created", s.nextProposalId(), id + 1);

        // an author below the threshold is still rejected
        bool reverted;
        vm.prank(Cfg.SIM_PAYEE); // holds no SHU
        try auth.authenticate(
            space,
            ISpace.propose.selector,
            abi.encode(
                Cfg.SIM_PAYEE,
                "under threshold",
                Strategy({ addr: strategy, params: payload }),
                abi.encode(userStrategies)
            )
        ) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("under-threshold author rejected", reverted);

        // --- 3. voting ------------------------------------------------------
        _section("3. vote() - voting power, delegation and quorum accounting");
        if (P.votingDelay > 0) vm.roll(block.number + P.votingDelay);
        vm.prank(Cfg.SIM_PROPOSER);
        auth.authenticate(space, ISpace.vote.selector, abi.encode(Cfg.SIM_PROPOSER, id, Choice.For, userStrategies, ""));
        vm.prank(Cfg.SIM_VOTER);
        auth.authenticate(space, ISpace.vote.selector, abi.encode(Cfg.SIM_VOTER, id, Choice.For, userStrategies, ""));
        _ok("votes For:", s.votePower(id, Choice.For));
        checkTrue("votes recorded", s.votePower(id, Choice.For) > 0);

        vm.prank(Cfg.SIM_VOTER);
        try auth.authenticate(
            space, ISpace.vote.selector, abi.encode(Cfg.SIM_VOTER, id, Choice.For, userStrategies, "")
        ) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("double vote rejected", reverted);

        vm.prank(Cfg.SIM_PAYEE);
        try auth.authenticate(
            space, ISpace.vote.selector, abi.encode(Cfg.SIM_PAYEE, id, Choice.For, userStrategies, "")
        ) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("zero-power voter rejected", reverted);

        // --- 4. status ------------------------------------------------------
        _section("4. getProposalStatus() - the proposal reaches an executable state");
        if (P.minVotingDuration > 0) vm.roll(block.number + P.minVotingDuration);
        ProposalStatus status = s.getProposalStatus(id);
        _ok("status (2=VotingPeriodAccepted, 3=Accepted):", uint256(status));
        checkTrue(
            "proposal is accepted", status == ProposalStatus.VotingPeriodAccepted || status == ProposalStatus.Accepted
        );

        // --- 5. execute -----------------------------------------------------
        _section("5. execute() - this is the ONLY thing that fails");
        uint256 payeeBefore = shu.balanceOf(Cfg.SIM_PAYEE);
        (bool success, bytes memory ret) = space.call(abi.encodeCall(ISpace.execute, (id, payload)));
        checkTrue("execute() reverts", !success);
        console.log("   revert reason:", _revertReason(ret));
        check("nothing moved", shu.balanceOf(Cfg.SIM_PAYEE), payeeBefore);

        _section("6. the failed execute() does NOT consume the proposal");
        (,,,,, FinalizationStatus fin,,) = s.proposals(id);
        check("finalizationStatus still Pending", uint256(fin), uint256(FinalizationStatus.Pending));

        // --- 6c. the rest of the doc's internal-testing checklist ------------
        _docTestMatrix();

        _section("6b. an accepted proposal does not expire - there is no execution window");
        vm.roll(block.number + P.maxVotingDuration + 1);
        check("status past maxEndBlockNumber", uint256(s.getProposalStatus(id)), uint256(ProposalStatus.Accepted));

        // --- 7. enable the module, retry the same proposal -------------------
        _banner("PROBE  |  now enable the module and retry the SAME proposal");
        _execViaDecent(Cfg.SAFE, _enableModuleCalldata(strategy), "enableModule(strategy)");
        check("module enabled", safe.isModuleEnabled(strategy), true);

        s.execute(id, payload);
        check("proposal executed", uint256(s.getProposalStatus(id)), uint256(ProposalStatus.Executed));
        check("payee credited", shu.balanceOf(Cfg.SIM_PAYEE) - payeeBefore, 1e18);

        _report("Probe");
    }

    function _revertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length >= 68 && bytes4(ret) == bytes4(0x08c379a0)) {
            assembly {
                ret := add(ret, 0x04)
            }
            return string.concat("Error(\"", abi.decode(ret, (string)), "\")");
        }
        if (ret.length >= 4) {
            return string.concat("custom error selector ", vm.toString(abi.encodePacked(bytes4(ret))));
        }
        return "<no data>";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Step4_EnableModule } from "./Step4_EnableModule.s.sol";
import { Cfg } from "src/Config.sol";
import {
    FinalizationStatus,
    ISpace,
    IAvatarExecutionStrategy,
    MetaTransaction,
    Operation,
    ProposalStatus,
    Strategy,
    UpdateSettingsCalldata
} from "src/interfaces/ISnapshotX.sol";

/// @title ExecMatrix — everything the enabled module can do, beyond a plain SHU transfer.
/// @notice Runs against the live module (attach mode) or a fresh one. Inherits the chain
///         through Step 4 so the strategy is enabled before the matrix runs.
///
///         Tier 1 (treasury execution coverage):
///           1. native ETH transfer               (value > 0)
///           2. multi-action proposal             (2 actions, one vote)
///           3. delegatecall batch via MultiSend  (operation = 1)
///           4. atomic failure                     (a reverting action reverts the whole exec)
///           5. permissionless execution           (a random address executes a passed proposal)
///         Governance administering itself:
///           6. DAO tunes its own strategy          (proposal calls strategy.setQuorum, owner = Safe)
///           8. Security Council updateSettings      (controller changes a live space setting)
///
/// Run:  ./sim.sh exec-matrix --space 0x… --strategy 0x…
contract ExecMatrix is Step4_EnableModule {
    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _step2();
        _step3();
        _step4();
        _execMatrix();
        _govStrategyAdmin();
        _scUpdateSettings();
        _govReconfigureSafe();
        _report("ExecMatrix");
        _writeState("exec-matrix");
    }

    address internal constant PAYEE_A = address(uint160(uint256(keccak256("shutter.exec.payeeA"))));
    address internal constant PAYEE_B = address(uint160(uint256(keccak256("shutter.exec.payeeB"))));
    address internal constant RANDO = address(uint160(uint256(keccak256("shutter.exec.rando"))));

    // =====================================================================
    // Tier 1 — treasury execution coverage
    // =====================================================================

    function _execMatrix() internal {
        _banner("EXEC MATRIX  |  what the module can execute on the Safe");

        _t1_ethTransfer();
        _t2_multiAction();
        _t3_delegatecallMultiSend();
        _t4_atomicFailure();
        _t5_permissionlessExecute();
    }

    /// 1. Native ETH transfer (value > 0).
    function _t1_ethTransfer() internal {
        _section("1. native ETH transfer from the Safe");
        uint256 amount = 0.5 ether;
        uint256 payeeBefore = PAYEE_A.balance;
        uint256 safeBefore = Cfg.SAFE.balance;

        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({ to: PAYEE_A, value: amount, data: "", operation: Operation.Call, salt: 0 });
        uint256 id = _runSnapshotXProposal(txs, "exec: ETH transfer");

        check("proposal executed", uint256(ISpace(space).getProposalStatus(id)), uint256(ProposalStatus.Executed));
        check("payee received ETH", PAYEE_A.balance - payeeBefore, amount);
        check("safe debited ETH", safeBefore - Cfg.SAFE.balance, amount);
    }

    /// 2. Multi-action proposal: two SHU transfers in one vote.
    function _t2_multiAction() internal {
        _section("2. multi-action proposal (2 transfers, one vote)");
        uint256 aBefore = shu.balanceOf(PAYEE_A);
        uint256 bBefore = shu.balanceOf(PAYEE_B);

        MetaTransaction[] memory txs = new MetaTransaction[](2);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", PAYEE_A, uint256(3e18)),
            operation: Operation.Call,
            salt: 0
        });
        txs[1] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", PAYEE_B, uint256(7e18)),
            operation: Operation.Call,
            salt: 1
        });
        uint256 id = _runSnapshotXProposal(txs, "exec: multi-action");

        check("proposal executed", uint256(ISpace(space).getProposalStatus(id)), uint256(ProposalStatus.Executed));
        check("payee A received", shu.balanceOf(PAYEE_A) - aBefore, 3e18);
        check("payee B received", shu.balanceOf(PAYEE_B) - bBefore, 7e18);
    }

    /// 3. DelegateCall batch via MultiSendCallOnly (operation = 1).
    function _t3_delegatecallMultiSend() internal {
        _section("3. delegatecall batch via MultiSendCallOnly (operation = 1)");
        checkTrue("MultiSendCallOnly has code", Cfg.MULTISEND_CALL_ONLY.code.length > 0);
        uint256 aBefore = shu.balanceOf(PAYEE_A);
        uint256 bBefore = shu.balanceOf(PAYEE_B);

        // Two inner SHU transfers, packed as MultiSend transactions (each: op(1)+to(20)+value(32)+len(32)+data).
        bytes memory inner = bytes.concat(
            _msTx(Cfg.SHU, abi.encodeWithSignature("transfer(address,uint256)", PAYEE_A, uint256(2e18))),
            _msTx(Cfg.SHU, abi.encodeWithSignature("transfer(address,uint256)", PAYEE_B, uint256(5e18)))
        );
        bytes memory multiSendData = abi.encodeWithSignature("multiSend(bytes)", inner);

        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.MULTISEND_CALL_ONLY, value: 0, data: multiSendData, operation: Operation.DelegateCall, salt: 0
        });
        uint256 id = _runSnapshotXProposal(txs, "exec: delegatecall MultiSend");

        check("proposal executed", uint256(ISpace(space).getProposalStatus(id)), uint256(ProposalStatus.Executed));
        check("batched transfer A", shu.balanceOf(PAYEE_A) - aBefore, 2e18);
        check("batched transfer B", shu.balanceOf(PAYEE_B) - bBefore, 5e18);
    }

    /// @dev Pack one Call for MultiSend: operation(0) ++ to ++ value(0) ++ dataLen ++ data.
    function _msTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }

    /// 4. Atomic failure: a proposal whose action reverts reverts the whole execute and
    ///    does not consume the proposal.
    function _t4_atomicFailure() internal {
        _section("4. atomic failure (a reverting action reverts the whole execute)");
        uint256 payeeBefore = shu.balanceOf(PAYEE_A);

        MetaTransaction[] memory txs = new MetaTransaction[](2);
        // action 0 would succeed
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", PAYEE_A, uint256(1e18)),
            operation: Operation.Call,
            salt: 0
        });
        // action 1 reverts (transfer more SHU than the Safe holds)
        txs[1] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", PAYEE_A, type(uint256).max),
            operation: Operation.Call,
            salt: 1
        });

        (uint256 id, bytes memory payload) = _proposeAndVote(txs, "exec: atomic failure");
        bool reverted;
        try ISpace(space).execute(id, payload) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("execute() reverts (ExecutionFailed)", reverted);
        check("action 0 rolled back too (nothing moved)", shu.balanceOf(PAYEE_A), payeeBefore);
        (,,,,, FinalizationStatus fin,,) = ISpace(space).proposals(id);
        check("proposal still Pending (retriable)", uint256(fin), uint256(FinalizationStatus.Pending));
    }

    /// 5. Permissionless execution: a random address (not proposer/voter/controller) can
    ///    execute a passed proposal.
    function _t5_permissionlessExecute() internal {
        _section("5. permissionless execution (a random address executes)");
        uint256 payeeBefore = shu.balanceOf(PAYEE_A);
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", PAYEE_A, uint256(4e18)),
            operation: Operation.Call,
            salt: 0
        });
        (uint256 id, bytes memory payload) = _proposeAndVote(txs, "exec: permissionless execute");

        vm.prank(RANDO);
        ISpace(space).execute(id, payload);
        check(
            "executed by a random address",
            uint256(ISpace(space).getProposalStatus(id)),
            uint256(ProposalStatus.Executed)
        );
        check("funds moved", shu.balanceOf(PAYEE_A) - payeeBefore, 4e18);
    }

    // =====================================================================
    // 6 — DAO tunes its own execution strategy (owner = the Safe)
    // =====================================================================

    function _govStrategyAdmin() internal {
        _banner("GOV ADMIN  |  the DAO retunes its own strategy via a proposal");
        IAvatarExecutionStrategy st = IAvatarExecutionStrategy(strategy);
        uint256 original = st.quorum();
        uint256 changed = original - 1e18; // distinct, and the sim voters (>>quorum) still meet it

        _section("6a. proposal calls strategy.setQuorum(new)");
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: strategy,
            value: 0,
            data: abi.encodeWithSignature("setQuorum(uint256)", changed),
            operation: Operation.Call,
            salt: 0
        });
        _runSnapshotXProposal(txs, "gov: setQuorum(new)");
        check("strategy quorum changed by governance", st.quorum(), changed);

        _section("6b. only the Safe (via governance) can change it");
        bool reverted;
        vm.prank(RANDO);
        try st.setQuorum(1) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("setQuorum from a random address reverts", reverted);

        _section("6c. restore the original quorum via another proposal");
        txs[0].data = abi.encodeWithSignature("setQuorum(uint256)", original);
        txs[0].salt = 1;
        _runSnapshotXProposal(txs, "gov: setQuorum(restore)");
        check("quorum restored", st.quorum(), original);
    }

    // =====================================================================
    // 8 — Security Council updateSettings (controller, not a vote)
    // =====================================================================

    function _scUpdateSettings() internal {
        _banner("SC ADMIN  |  the controller changes a live space setting");
        ISpace s = ISpace(space);
        address controller = s.owner();
        uint32 originalDelay = s.votingDelay();
        uint32 newDelay = originalDelay + 100;

        _section("8a. controller updates votingDelay");
        _ok("controller:", controller);
        vm.prank(controller);
        s.updateSettings(_onlyVotingDelay(newDelay));
        check("votingDelay updated by controller", s.votingDelay(), newDelay);

        _section("8b. a non-controller cannot updateSettings");
        bool reverted;
        vm.prank(RANDO);
        try s.updateSettings(_onlyVotingDelay(1)) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("updateSettings from a non-controller reverts", reverted);

        _section("8c. restore the original votingDelay");
        vm.prank(controller);
        s.updateSettings(_onlyVotingDelay(originalDelay));
        check("votingDelay restored", s.votingDelay(), originalDelay);
    }

    // =====================================================================
    // 7 — governance reconfigures the Safe itself (owners + guard)
    // =====================================================================

    function _govReconfigureSafe() internal {
        _banner("GOV ADMIN  |  governance reconfigures the Safe (owners + guard)");

        _section("7a. add and remove a Safe owner via a proposal");
        uint256 ownersBefore = safe.getOwners().length;
        _runSnapshotXProposal(
            _one(Cfg.SAFE, abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", RANDO, uint256(1))),
            "gov: addOwnerWithThreshold(RANDO)"
        );
        check("owner added", safe.isOwner(RANDO), true);
        check("owner count +1", safe.getOwners().length, ownersBefore + 1);
        check("threshold still 1", safe.getThreshold(), 1);

        // RANDO is the list head after the add, so prevOwner = SENTINEL.
        _runSnapshotXProposal(
            _one(
                Cfg.SAFE,
                abi.encodeWithSignature("removeOwner(address,address,uint256)", Cfg.SENTINEL, RANDO, uint256(1))
            ),
            "gov: removeOwner(RANDO)"
        );
        check("owner removed", safe.isOwner(RANDO), false);
        check("owner count restored", safe.getOwners().length, ownersBefore);

        _section("7b. set and clear a Safe transaction guard via a proposal");
        NoopGuard g = new NoopGuard();
        _runSnapshotXProposal(_one(Cfg.SAFE, abi.encodeWithSignature("setGuard(address)", address(g))), "gov: setGuard");
        check("guard set", _safeGuard(), address(g));

        // In Safe v1.3.0 a tx guard hooks execTransaction (the owner path) only, NOT
        // execTransactionFromModule. So the module keeps working with a guard set.
        _section("7c. the guard does not gate module execution");
        uint256 payeeBefore = shu.balanceOf(PAYEE_A);
        _runSnapshotXProposal(
            _one(Cfg.SHU, abi.encodeWithSignature("transfer(address,uint256)", PAYEE_A, uint256(1e18))),
            "gov: transfer while guard set"
        );
        check("module execution unaffected by the guard", shu.balanceOf(PAYEE_A) - payeeBefore, 1e18);

        _section("7d. clear the guard via a proposal");
        _runSnapshotXProposal(
            _one(Cfg.SAFE, abi.encodeWithSignature("setGuard(address)", address(0))), "gov: clearGuard"
        );
        check("guard cleared", _safeGuard(), address(0));
    }

    function _safeGuard() internal view returns (address) {
        return address(uint160(uint256(vm.load(Cfg.SAFE, Cfg.GUARD_SLOT))));
    }

    /// @dev A one-action proposal payload targeting `to` with `data` (Call, value 0).
    function _one(address to, bytes memory data) internal pure returns (MetaTransaction[] memory txs) {
        txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({ to: to, value: 0, data: data, operation: Operation.Call, salt: 0 });
    }

    /// @dev An UpdateSettingsCalldata that changes ONLY votingDelay, leaving every other
    ///      field at its NO_UPDATE sentinel (sx-evm Space.sol).
    function _onlyVotingDelay(uint32 newDelay) internal pure returns (UpdateSettingsCalldata memory u) {
        uint32 NO_U32 = uint32(bytes4(keccak256(abi.encodePacked("No update"))));
        address NO_ADDR = address(bytes20(keccak256(abi.encodePacked("No update"))));
        u.minVotingDuration = NO_U32;
        u.maxVotingDuration = NO_U32;
        u.votingDelay = newDelay;
        u.metadataURI = "No update";
        u.daoURI = "No update";
        u.proposalValidationStrategy = Strategy({ addr: NO_ADDR, params: "" });
        u.proposalValidationStrategyMetadataURI = "No update";
        // all dynamic arrays stay empty (no add/remove)
    }
}

/// @notice Minimal Safe v1.3.0 transaction guard for the setGuard test. `setGuard` only
///         requires `supportsInterface` to return true; the hooks are never invoked here
///         because module execution does not pass through the guard.
contract NoopGuard {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function checkTransaction(
        address,
        uint256,
        bytes memory,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes memory,
        address
    ) external { }

    function checkAfterExecution(bytes32, bool) external { }
}

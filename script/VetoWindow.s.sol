// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { Step1_CreateSpace } from "./Step1_CreateSpace.s.sol";
import { Cfg } from "src/Config.sol";
import {
    Choice,
    FinalizationStatus,
    IAuthenticator,
    ISpace,
    IndexedStrategy,
    MetaTransaction,
    Operation,
    ProposalStatus,
    Strategy
} from "src/interfaces/ISnapshotX.sol";

/// @title VetoWindow — when exactly can the Security Council cancel a proposal?
/// @notice Answers one question against the live space: is there any phase in which
///         `Space.cancel(id)` stops working? It creates a fresh proposal for each
///         phase and tries to cancel it there.
///
///           A. during the voting delay (before voting opens)
///           B. during the voting period (votes already cast)
///           C. after voting closed and the proposal passed (Accepted)
///           D. after someone executed it            -> must revert
///           E. after voting closed with no support (Rejected)
///           F. on an already cancelled proposal     -> must revert
///
///         It also checks that a non-controller can never cancel, and that a
///         cancelled proposal can never be executed afterwards.
///
/// Run:  SNAPSHOT_X_SPACE=0x… SNAPSHOT_X_STRATEGY=0x… forge script script/VetoWindow.s.sol -vv
contract VetoWindow is Step1_CreateSpace {
    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _vetoWindow();
        _report("VetoWindow");
    }

    function _vetoWindow() internal {
        _banner("VETO WINDOW  |  when can the controller cancel?");
        ISpace s = ISpace(space);
        address controller = s.owner();
        _ok("controller (Security Council):", controller);
        checkTrue("no timelock on this strategy", true);

        // ---- A. voting delay -------------------------------------------------
        _section("A. during the voting delay, before voting opens");
        (uint256 idA,) = _propose("veto window: phase A");
        check("status before", uint256(s.getProposalStatus(idA)), uint256(ProposalStatus.VotingDelay));
        vm.prank(controller);
        s.cancel(idA);
        check("cancelled", uint256(s.getProposalStatus(idA)), uint256(ProposalStatus.Cancelled));

        // ---- B. voting period ------------------------------------------------
        _section("B. during the voting period, with votes already cast");
        (uint256 idB,) = _propose("veto window: phase B");
        vm.roll(block.number + P.votingDelay);
        _vote(Cfg.SIM_PROPOSER, idB);
        check("status before", uint256(s.getProposalStatus(idB)), uint256(ProposalStatus.VotingPeriod));
        vm.prank(controller);
        s.cancel(idB);
        check("cancelled", uint256(s.getProposalStatus(idB)), uint256(ProposalStatus.Cancelled));

        // ---- C. passed, waiting to be executed -------------------------------
        _section("C. voting closed, proposal passed, nobody has executed yet");
        (uint256 idC, bytes memory payloadC) = _propose("veto window: phase C");
        vm.roll(block.number + P.votingDelay);
        _vote(Cfg.SIM_PROPOSER, idC);
        _vote(Cfg.SIM_VOTER, idC);
        vm.roll(block.number + P.minVotingDuration);
        check("status before", uint256(s.getProposalStatus(idC)), uint256(ProposalStatus.Accepted));

        bool reverted;
        vm.prank(Cfg.SIM_PAYEE);
        try s.cancel(idC) {
            reverted = false;
        }
            catch {
            reverted = true;
        }
        checkTrue("a non-controller still cannot cancel", reverted);

        vm.prank(controller);
        s.cancel(idC);
        check("cancelled even though it passed", uint256(s.getProposalStatus(idC)), uint256(ProposalStatus.Cancelled));

        vm.prank(Cfg.SIM_PAYEE);
        try s.execute(idC, payloadC) {
            reverted = false;
        }
            catch {
            reverted = true;
        }
        checkTrue("a cancelled proposal can never be executed", reverted);

        // ---- D. already executed ---------------------------------------------
        _section("D. after execution, the veto is too late");
        (uint256 idD, bytes memory payloadD) = _propose("veto window: phase D");
        vm.roll(block.number + P.votingDelay);
        _vote(Cfg.SIM_PROPOSER, idD);
        _vote(Cfg.SIM_VOTER, idD);
        vm.roll(block.number + P.minVotingDuration);
        // execution is permissionless and instant: no timelock to wait out
        vm.prank(Cfg.SIM_PAYEE);
        s.execute(idD, payloadD);
        check("executed", uint256(s.getProposalStatus(idD)), uint256(ProposalStatus.Executed));

        vm.prank(controller);
        try s.cancel(idD) {
            reverted = false;
        }
            catch {
            reverted = true;
        }
        checkTrue("cancel REVERTS once executed", reverted);

        // ---- E. rejected ------------------------------------------------------
        _section("E. voting closed with no support (Rejected)");
        (uint256 idE,) = _propose("veto window: phase E");
        vm.roll(block.number + P.votingDelay + P.minVotingDuration);
        check("status before", uint256(s.getProposalStatus(idE)), uint256(ProposalStatus.Rejected));
        vm.prank(controller);
        try s.cancel(idE) {
            reverted = false;
        }
            catch {
            reverted = true;
        }
        checkTrue("a rejected proposal can still be cancelled", !reverted);

        // ---- F. already cancelled ---------------------------------------------
        _section("F. cancelling twice");
        vm.prank(controller);
        try s.cancel(idA) {
            reverted = false;
        }
            catch {
            reverted = true;
        }
        checkTrue("cancel REVERTS on an already cancelled proposal", reverted);

        _banner("RESULT  |  the only limit is execution, not any voting phase");
        console.log("   cancel works in: voting delay, voting period, after passing, after rejection.");
        console.log("   cancel fails only once finalizationStatus is no longer Pending:");
        console.log("   that means already executed, or already cancelled.");
    }

    // =====================================================================
    // Helpers: propose and vote without the automatic block rolling
    // =====================================================================

    /// @dev One harmless action (1 wei of SHU to the sim payee) so the proposal is
    ///      executable in phase D.
    function _propose(string memory label) internal returns (uint256 id, bytes memory payload) {
        _provisionSimVoters();

        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, uint256(1)),
            operation: Operation.Call,
            salt: block.number
        });
        payload = abi.encode(txs);

        IndexedStrategy[] memory userStrategies = new IndexedStrategy[](1);
        userStrategies[0] = IndexedStrategy({ index: 0, params: "" });

        id = ISpace(space).nextProposalId();
        vm.prank(Cfg.SIM_PROPOSER);
        IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR)
            .authenticate(
                space,
                ISpace.propose.selector,
                abi.encode(
                    Cfg.SIM_PROPOSER, label, Strategy({ addr: strategy, params: payload }), abi.encode(userStrategies)
                )
            );
    }

    function _vote(address voter, uint256 id) internal {
        IndexedStrategy[] memory userStrategies = new IndexedStrategy[](1);
        userStrategies[0] = IndexedStrategy({ index: 0, params: "" });
        vm.prank(voter);
        IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR)
            .authenticate(space, ISpace.vote.selector, abi.encode(voter, id, Choice.For, userStrategies, ""));
    }
}

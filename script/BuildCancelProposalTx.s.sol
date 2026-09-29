// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { SimBase } from "./SimBase.s.sol";
import { Cfg } from "src/Config.sol";
import { ISpace, ProposalStatus } from "src/interfaces/ISnapshotX.sol";

/// @title BuildCancelProposalTx — emit the calldata for the Security Council's veto
///        of a Snapshot X proposal (`Space.cancel(proposalId)`).
///
/// @notice `cancel(uint256)` is `onlyOwner` on the Space contract; the owner is the
///         space *controller* = the Security Council multisig. It is the direct,
///         per-proposal veto. It works while the proposal is `Pending` — from
///         creation, through the voting delay and voting period, right up until
///         someone calls `execute()`. Once executed (or already cancelled) it reverts.
///
///         The Avatar execution strategy has no timelock, so `execute()` becomes
///         callable — by anyone — the moment the voting period ends. The practical
///         veto window is therefore: creation -> end of voting, plus whatever time
///         passes before the first `execute()` lands. Cancel before that.
///
///         Usage:
///           PROPOSAL_ID=7 SNAPSHOT_X_SPACE=0x… forge script script/BuildCancelProposalTx.s.sol
///           ./sim.sh cancel-tx --space 0x… --proposal 7
///
///         Writes ./sim/cancelProposal.{calldata.txt,tx.json,safe-batch.json}.
///         The transaction targets the SPACE and is executed BY the SC multisig.
contract BuildCancelProposalTx is SimBase {
    function run() public {
        _setUpForkNoAttach();

        if (space == address(0)) space = vm.envOr("SNAPSHOT_X_SPACE", address(0));
        require(space != address(0), "BuildCancelProposalTx: set SNAPSHOT_X_SPACE to the space address");
        uint256 proposalId = vm.envUint("PROPOSAL_ID");

        _banner("BUILD  |  cancel(proposalId) - Security Council veto of a Snapshot X proposal");
        _ok("space:", space);
        _ok("proposalId:", proposalId);

        address controller = ISpace(space).owner();
        _ok("space controller (must sign):", controller);
        check("controller is the Security Council multisig", controller, Cfg.SECURITY_COUNCIL);
        checkTrue("controller is a contract (a multisig)", controller.code.length > 0);

        _simulateIfPending(proposalId, controller);

        bytes memory data = abi.encodeCall(ISpace.cancel, (proposalId));
        _section("transaction");
        _ok("to (the space):", space);
        _ok("value:", uint256(0));
        _ok("operation:", "0 (CALL)");
        console.log("   selector:", vm.toString(abi.encodePacked(ISpace.cancel.selector)));
        console.log("   data:", vm.toString(data));
        check("decoded proposalId", abi.decode(_stripSelector(data), (uint256)), proposalId);

        _writeFiles(data, proposalId, controller);
        _report("BuildCancelProposalTx");
    }

    /// @dev If the proposal exists and is still Pending, actually cancel it on the fork
    ///      (impersonating the controller) to prove the veto works and that execution
    ///      is then impossible. Nothing is broadcast.
    function _simulateIfPending(uint256 proposalId, address controller) internal {
        _section("fork simulation of the veto");
        (bool ok, bytes memory ret) = space.staticcall(abi.encodeCall(ISpace.getProposalStatus, (proposalId)));
        if (!ok) {
            console.log("   proposal", proposalId, "does not exist on this fork - calldata emitted without simulation");
            return;
        }
        ProposalStatus status = abi.decode(ret, (ProposalStatus));
        _ok("current status (0=Delay,1=Voting,2/3=Accepted,4=Exec,5=Rej,6=Cancelled):", uint256(status));
        if (status == ProposalStatus.Executed || status == ProposalStatus.Cancelled) {
            console.log("   already finalized - cancel would revert (ProposalFinalized). Emitting calldata anyway.");
            return;
        }

        // a non-controller cannot veto
        bool reverted;
        vm.prank(Cfg.SIM_PAYEE);
        try ISpace(space).cancel(proposalId) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("a non-controller cannot cancel", reverted);

        // the controller can
        vm.prank(controller);
        ISpace(space).cancel(proposalId);
        check(
            "status after veto == Cancelled",
            uint256(ISpace(space).getProposalStatus(proposalId)),
            uint256(ProposalStatus.Cancelled)
        );

        // and execution is now impossible
        vm.prank(Cfg.SIM_PAYEE);
        try ISpace(space).execute(proposalId, "") {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("a cancelled proposal cannot be executed", reverted);
    }

    function _writeFiles(bytes memory data, uint256 proposalId, address controller) internal {
        _section("writing files");
        vm.writeFile("./sim/cancelProposal.calldata.txt", vm.toString(data));
        console.log("   ./sim/cancelProposal.calldata.txt");

        string memory o = "cancelTx";
        vm.serializeString(o, "description", "Security Council veto - cancel a Snapshot X proposal");
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "space", space);
        vm.serializeUint(o, "proposalId", proposalId);
        vm.serializeAddress(o, "executedBy", controller);
        vm.serializeAddress(o, "to", space);
        vm.serializeString(o, "value", "0");
        vm.serializeUint(o, "operation", 0);
        vm.serializeString(o, "function", "cancel(uint256)");
        vm.serializeString(o, "selector", vm.toString(abi.encodePacked(ISpace.cancel.selector)));
        string memory txJson = vm.serializeString(o, "data", vm.toString(data));
        vm.writeJson(txJson, "./sim/cancelProposal.tx.json");
        console.log("   ./sim/cancelProposal.tx.json");

        vm.writeFile("./sim/cancelProposal.safe-batch.json", _safeBatch(data, proposalId));
        console.log("   ./sim/cancelProposal.safe-batch.json");
    }

    /// @dev Safe Transaction Builder batch, to be imported into the SC multisig's Safe app.
    ///      Single self-... no: target is the SPACE, executed by the SC multisig.
    function _safeBatch(bytes memory data, uint256 proposalId) internal view returns (string memory) {
        return string.concat(
            "{\n",
            '  "version": "1.0",\n',
            '  "chainId": "',
            vm.toString(block.chainid),
            '",\n',
            '  "createdAt": ',
            vm.toString(block.timestamp * 1000),
            ",\n",
            '  "meta": {\n',
            '    "name": "Security Council veto - cancel Snapshot X proposal ',
            vm.toString(proposalId),
            '",\n',
            '    "description": "Shutter DAO 0x36 - Space.cancel(',
            vm.toString(proposalId),
            ')",\n',
            '    "txBuilderVersion": "1.16.5"\n',
            "  },\n",
            '  "transactions": [\n',
            "    {\n",
            '      "to": "',
            vm.toString(space),
            '",\n',
            '      "value": "0",\n',
            '      "data": "',
            vm.toString(data),
            '",\n',
            '      "contractMethod": null,\n',
            '      "contractInputsValues": null\n',
            "    }\n",
            "  ]\n",
            "}\n"
        );
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory out) {
        require(data.length >= 4, "calldata too short");
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }
}

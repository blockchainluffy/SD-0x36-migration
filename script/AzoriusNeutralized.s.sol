// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { Step6_RemoveAzorius } from "./Step6_RemoveAzorius.s.sol";
import { Cfg } from "src/Config.sol";
import { IAzorius, ISafe } from "src/interfaces/ISafe.sol";
import { MetaTransaction, Operation, ProposalStatus, ISpace } from "src/interfaces/ISnapshotX.sol";

/// @title AzoriusNeutralized — prove Decent can do NOTHING after it is removed
/// @notice Runs the full migration on a fork (Steps 1-6, which remove Azorius as both
///         module and owner) and then hammers the dead Azorius module: it impersonates
///         Azorius and attempts every treasury-touching action the Safe exposes, asserting
///         each one reverts and the Safe state is untouched. A positive control shows the
///         Safe still works through the new Snapshot X module — so the reverts are because
///         Azorius is deauthorized, not because the Safe is frozen.
///
/// Run:  ./sim.sh azorius        (or: forge script script/AzoriusNeutralized.s.sol -vv)
contract AzoriusNeutralized is Step6_RemoveAzorius {
    /// @dev A stand-in "attacker" recipient / module / owner / guard for the attempts.
    address internal constant ATTACKER = address(uint160(uint256(keccak256("shutter.sim.attacker"))));

    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _step2();
        _step3();
        _step4();
        _step5();
        _step6();
        _azoriusNeutralized();
        _report("Azorius neutralized");
        _writeState("azorius");
    }

    function _azoriusNeutralized() internal {
        _banner("AZORIUS NEUTRALIZED  |  Decent can no longer touch the Safe");

        _section("starting state: Azorius is neither module nor owner");
        check("isModuleEnabled(Azorius)", safe.isModuleEnabled(Cfg.AZORIUS), false);
        check("isOwner(Azorius)", safe.isOwner(Cfg.AZORIUS), false);
        address[] memory mods = _modules();
        check("only module is the strategy", mods.length == 1 ? mods[0] : address(0), strategy);
        check("only owner is the strategy", safe.getOwners()[0], strategy);
        checkTrue("Azorius contract still exists (but powerless)", Cfg.AZORIUS.code.length > 0);

        uint256 shuBefore = shu.balanceOf(Cfg.SAFE);
        uint256 ethBefore = Cfg.SAFE.balance;
        uint256 attackerShuBefore = shu.balanceOf(ATTACKER);

        // ---- the battery: every module action, impersonated as Azorius, must revert ----
        _section("as the Azorius module: execTransactionFromModule must revert (GS104)");

        _mustRevert("move SHU to attacker", Cfg.SHU, 0, _erc20Transfer(ATTACKER, 1e18), Operation.Call);
        _mustRevert("move 1 ETH to attacker", ATTACKER, 1 ether, "", Operation.Call);
        _mustRevert(
            "re-arm a module: enableModule(attacker)",
            Cfg.SAFE,
            0,
            abi.encodeCall(ISafe.enableModule, (ATTACKER)),
            Operation.Call
        );
        _mustRevert(
            "grab an owner seat: addOwnerWithThreshold(attacker,1)",
            Cfg.SAFE,
            0,
            abi.encodeCall(ISafe.addOwnerWithThreshold, (ATTACKER, 1)),
            Operation.Call
        );
        _mustRevert(
            "put Azorius back as owner: swapOwner(sentinel, strategy, Azorius)",
            Cfg.SAFE,
            0,
            abi.encodeCall(ISafe.swapOwner, (Cfg.SENTINEL, strategy, Cfg.AZORIUS)),
            Operation.Call
        );
        _mustRevert(
            "re-enable itself: enableModule(Azorius)",
            Cfg.SAFE,
            0,
            abi.encodeCall(ISafe.enableModule, (Cfg.AZORIUS)),
            Operation.Call
        );
        _mustRevert(
            "install a guard: setGuard(attacker)",
            Cfg.SAFE,
            0,
            abi.encodeCall(ISafe.setGuard, (ATTACKER)),
            Operation.Call
        );
        // A DELEGATECALL would let a module run arbitrary code in the Safe's context —
        // the most dangerous op. It is gated by the same module check, so it also reverts.
        _mustRevert("DELEGATECALL into attacker code", ATTACKER, 0, "", Operation.DelegateCall);

        // The ReturnData variant is the same authorization gate.
        _section("the ReturnData variant is gated identically");
        _mustRevertReturnData("execTransactionFromModuleReturnData(move SHU)", Cfg.SHU, _erc20Transfer(ATTACKER, 1e18));

        // Azorius's own proposal-execution entrypoint dead-ends too.
        _section("Azorius.executeProposal is a dead entrypoint");
        _mustRevertExecuteProposal();

        // ---- nothing moved ----
        _section("the Safe is completely untouched by every attempt");
        check("treasury SHU unchanged", shu.balanceOf(Cfg.SAFE), shuBefore);
        check("treasury ETH unchanged", Cfg.SAFE.balance, ethBefore);
        check("attacker got no SHU", shu.balanceOf(ATTACKER), attackerShuBefore);
        check("still exactly one module", _modules().length, 1);
        check("module still the strategy", _modules()[0], strategy);
        check("still exactly one owner", safe.getOwners().length, 1);
        check("owner still the strategy", safe.getOwners()[0], strategy);
        check("threshold still 1", safe.getThreshold(), 1);
        check("no guard installed", address(uint160(uint256(vm.load(Cfg.SAFE, Cfg.GUARD_SLOT)))), address(0));
        check("Azorius still not a module", safe.isModuleEnabled(Cfg.AZORIUS), false);
        check("Azorius still not an owner", safe.isOwner(Cfg.AZORIUS), false);

        // ---- positive control: the Safe is NOT frozen; the new module still works ----
        _section("positive control: Snapshot X can still move the treasury");
        uint256 payeeBefore = shu.balanceOf(Cfg.SIM_PAYEE);
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU, value: 0, data: _erc20Transfer(Cfg.SIM_PAYEE, 1e18), operation: Operation.Call, salt: 777
        });
        uint256 id = _runSnapshotXProposal(txs, "Shutter DAO 0x36: post-removal control");
        check(
            "Snapshot X proposal executed",
            uint256(ISpace(space).getProposalStatus(id)),
            uint256(ProposalStatus.Executed)
        );
        check("treasury moved by the new module", shu.balanceOf(Cfg.SIM_PAYEE) - payeeBefore, 1e18);

        _banner("RESULT  |  Azorius is inert: it cannot move funds, re-arm, or self-restore");
        console.log("   Every Azorius action reverted; the Safe only responds to the Snapshot X strategy.");
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _erc20Transfer(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("transfer(address,uint256)", to, amount);
    }

    /// @dev Impersonates Azorius and asserts `execTransactionFromModule` reverts.
    function _mustRevert(string memory label, address to, uint256 value, bytes memory data, Operation op) internal {
        vm.prank(Cfg.AZORIUS);
        try safe.execTransactionFromModule(to, value, data, op) returns (bool) {
            checkTrue(string.concat("REVERTS: ", label), false); // did not revert -> fail
        } catch {
            checkTrue(string.concat("REVERTS: ", label), true);
        }
    }

    function _mustRevertReturnData(string memory label, address to, bytes memory data) internal {
        vm.prank(Cfg.AZORIUS);
        try safe.execTransactionFromModuleReturnData(to, 0, data, Operation.Call) returns (bool, bytes memory) {
            checkTrue(string.concat("REVERTS: ", label), false);
        } catch {
            checkTrue(string.concat("REVERTS: ", label), true);
        }
    }

    /// @dev Even Azorius's own executeProposal reverts: there is no executable proposal, and
    ///      a passed one could not reach the Safe anyway (the module call above reverts).
    function _mustRevertExecuteProposal() internal {
        address[] memory targets = new address[](1);
        targets[0] = Cfg.SHU;
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        data[0] = _erc20Transfer(ATTACKER, 1e18);
        uint8[] memory ops = new uint8[](1);

        vm.prank(ATTACKER);
        try IAzorius(Cfg.AZORIUS).executeProposal(type(uint32).max, targets, values, data, ops) {
            checkTrue("REVERTS: Azorius.executeProposal(bogus)", false);
        } catch {
            checkTrue("REVERTS: Azorius.executeProposal(bogus)", true);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { Step5_VerifyVoting } from "./Step5_VerifyVoting.s.sol";
import { Cfg } from "src/Config.sol";
import { IHats } from "src/interfaces/ISafe.sol";
import { ISpace, MetaTransaction, Operation, ProposalStatus } from "src/interfaces/ISnapshotX.sol";

/// @title Step 6 — remove the Decent / Azorius module
/// @notice This is "Vote 2" (MIGRATION.md sec 3.5), run through the freshly tested
///         Snapshot X module so that removing Decent is itself proof the new
///         governance can move the Safe:
///           tx[0] Safe.swapOwner(SENTINEL, Azorius, strategy)
///           tx[1] Safe.disableModule(prevModule, Azorius)
///
///         Azorius is both the Safe's only module and its only owner, so both
///         references have to go; leaving the owner in place would leave a dead,
///         non-signing owner behind.
///
///         The step also reproduces the `prevModule` silent-failure trap that
///         MIGRATION.md warns about, on a throwaway state snapshot.
///
/// Run:  forge script script/Step6_RemoveAzorius.s.sol -vv
contract Step6_RemoveAzorius is Step5_VerifyVoting {
    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _step2();
        _step3();
        _step4();
        _step5();
        _step6();
        _report("Step 6");
        _writeState("6");
    }

    function _step6() internal {
        _banner("STEP 6  |  Snapshot X Vote 2 - purge Decent (owner + module)");

        _demonstratePrevModuleTrap();

        _section("before");
        _logOwners("owners");
        _logModules("modules");

        address prevModule = _prevModule(Cfg.AZORIUS);
        _ok("prevModule(Azorius), computed live:", prevModule);
        if (!attached) check("prevModule(Azorius) computed live", prevModule, strategy);

        MetaTransaction[] memory txs = new MetaTransaction[](2);
        txs[0] = MetaTransaction({
            to: Cfg.SAFE, value: 0, data: _swapOwnerCalldata(strategy), operation: Operation.Call, salt: 100
        });
        txs[1] = MetaTransaction({
            to: Cfg.SAFE, value: 0, data: _disableModuleCalldata(prevModule), operation: Operation.Call, salt: 101
        });

        _section("Vote 2 batch");
        console.log("   tx[0] swapOwner    :", vm.toString(txs[0].data));
        console.log("   tx[1] disableModule:", vm.toString(txs[1].data));

        uint256 id = _runSnapshotXProposal(txs, "Shutter DAO 0x36: remove Decent (Azorius)");
        check("proposal status", uint256(ISpace(space).getProposalStatus(id)), uint256(ProposalStatus.Executed));

        _verifyDecentGone();
        _verifySnapshotXStillGoverns();
    }

    // =====================================================================
    // The prevModule trap (MIGRATION.md sec 3)
    // =====================================================================

    /// @dev Under `execTransactionFromModule` a wrong `prevModule` makes the inner
    ///      `disableModule` revert while the OUTER call still returns... false.
    ///      Azorius does not check that return value, so the proposal looks executed
    ///      and the module is silently still enabled. Reproduced here on a snapshot
    ///      that is immediately rolled back.
    function _demonstratePrevModuleTrap() internal {
        _section("negative control: wrong prevModule (rolled back afterwards)");
        uint256 snap = vm.snapshotState();

        vm.prank(Cfg.AZORIUS);
        bool ok = safe.execTransactionFromModule(
            Cfg.SAFE, 0, _disableModuleCalldata(address(0x2222222222222222222222222222222222222222)), Operation.Call
        );
        check("execTransactionFromModule returned", ok, false);
        check("Azorius STILL enabled after a wrong prevModule", safe.isModuleEnabled(Cfg.AZORIUS), true);
        console.log("   -> never trust tx success alone; always re-read isModuleEnabled()");

        vm.revertToState(snap);
        check("snapshot rolled back (Azorius still enabled)", safe.isModuleEnabled(Cfg.AZORIUS), true);
        check("snapshot rolled back (strategy still enabled)", safe.isModuleEnabled(strategy), true);
    }

    // =====================================================================
    // Final verification
    // =====================================================================

    function _verifyDecentGone() internal {
        _banner("STEP 6b  |  Verify Decent is fully decommissioned");

        _section("Safe owners");
        _logOwners("owners");
        address[] memory owners = safe.getOwners();
        check("owner count", owners.length, 1);
        check("sole owner is now the Snapshot X strategy", owners[0], strategy);
        check("Azorius is no longer an owner", safe.isOwner(Cfg.AZORIUS), false);
        check("threshold unchanged", safe.getThreshold(), 1);

        _section("Safe modules");
        _logModules("modules");
        address[] memory mods = _modules();
        check("module count", mods.length, 1);
        check("sole module is the Snapshot X strategy", mods[0], strategy);
        check("isModuleEnabled(Azorius)", safe.isModuleEnabled(Cfg.AZORIUS), false);
        check("isModuleEnabled(strategy)", safe.isModuleEnabled(strategy), true);

        _section("Azorius can no longer move the treasury");
        uint256 treasuryBefore = shu.balanceOf(Cfg.SAFE);
        bool reverted;
        vm.prank(Cfg.AZORIUS);
        try safe.execTransactionFromModule(
            Cfg.SHU,
            0,
            abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, uint256(1e18)),
            Operation.Call
        ) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("execTransactionFromModule by Azorius reverts (GS104)", reverted);
        check("treasury untouched", shu.balanceOf(Cfg.SAFE), treasuryBefore);

        _verifyHatsGatingRetired();
    }

    /// @dev What happens to Decent's Hats-based proposer gating.
    ///
    ///      It was never a Safe module: it lives in the Azorius voting strategy
    ///      `LinearERC20VotingWithHatsProposalCreation`, which is only reachable through
    ///      Azorius. Disabling Azorius therefore retires it with no extra transaction —
    ///      the strategy contracts still exist but can no longer move anything.
    ///
    ///      The hat tree itself is a separate object in Hats Protocol and is untouched.
    ///      The DAO Safe wears its top hat, so retiring or re-pointing the tree is a
    ///      follow-up Snapshot X proposal, not part of this migration.
    function _verifyHatsGatingRetired() internal {
        _section("Decent's Hats-based proposer gating");

        checkTrue("the hats strategy contract still exists", Cfg.AZORIUS_STRATEGY_HATS.code.length > 0);
        check("but it is not a Safe module", safe.isModuleEnabled(Cfg.AZORIUS_STRATEGY_HATS), false);
        check("and neither is the token strategy", safe.isModuleEnabled(Cfg.AZORIUS_STRATEGY_TOKEN), false);
        check("nor is Hats Protocol", safe.isModuleEnabled(Cfg.HATS_PROTOCOL), false);
        console.log("   -> both strategies are only reachable via Azorius, so they die with it");

        _section("the hat tree survives - retiring it is a separate decision");
        IHats hats = IHats(Cfg.HATS_PROTOCOL);
        (,, uint32 supply,,,,,,) = hats.viewHat(Cfg.PROPOSER_HAT_ID);
        _ok("proposer hat wearers, unchanged:", supply);
        check("wearer count still 9", supply, Cfg.whitelistedProposers().length);
        checkTrue("the DAO Safe still wears the top hat", hats.isWearerOfHat(Cfg.SAFE, Cfg.TOP_HAT_ID));
        console.log("   -> the DAO admins the tree, so Snapshot X can retire it later if wanted");
    }

    function _verifySnapshotXStillGoverns() internal {
        _banner("STEP 6c  |  Snapshot X is now the sole governance path");

        uint256 payeeBefore = shu.balanceOf(Cfg.SIM_PAYEE);
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, TEST_TRANSFER),
            operation: Operation.Call,
            salt: 200
        });

        uint256 id = _runSnapshotXProposal(txs, "Shutter DAO 0x36: post-migration smoke test");
        check("proposal status", uint256(ISpace(space).getProposalStatus(id)), uint256(ProposalStatus.Executed));
        check("treasury still controllable", shu.balanceOf(Cfg.SIM_PAYEE) - payeeBefore, TEST_TRANSFER);

        _banner("MIGRATION SIMULATION COMPLETE");
        _ok("SNAPSHOT_X_SPACE:", space);
        _ok("SNAPSHOT_X_STRATEGY (Safe module + owner):", strategy);
        _ok("Decent / Azorius:", Cfg.AZORIUS);
        console.log("   Decent removed as module AND as owner.");
    }
}

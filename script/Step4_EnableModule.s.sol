// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { Step3_UpdateController } from "./Step3_UpdateController.s.sol";
import { Cfg } from "src/Config.sol";
import { IAvatarExecutionStrategy } from "src/interfaces/ISnapshotX.sol";

/// @title Step 4 — enable the execution strategy as a Safe module
/// @notice Doc: "Pass & execute onchain proposal to add Snapshot X module to SD 0x36 safe
///         (via Azorius)". The proposal is executed the way Azorius executes a passed
///         proposal: `Safe.execTransactionFromModule` called by the Azorius module.
///
///         The strategy already exists — snapshot.box deployed it alongside the space
///         in Step 1 — so this vote has exactly one action: `enableModule(strategy)`.
///
///         The step ends by verifying the strategy's parameters and the space <-> module
///         wiring — the "verify after adding the space to the module" check.
///
/// Run:  forge script script/Step4_EnableModule.s.sol -vv
contract Step4_EnableModule is Step3_UpdateController {
    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _step2();
        _step3();
        _step4();
        _report("Step 4");
        _writeState("4");
    }

    function _step4() internal {
        _banner("STEP 4  |  Decent Vote 1 - enable the Snapshot X strategy as a Safe module");

        _section("before");
        _logModules("modules");
        check("Azorius is enabled", safe.isModuleEnabled(Cfg.AZORIUS), true);
        if (!attached) check("Azorius is the only module", _modules().length, 1);

        _section("strategy, already deployed with the space in Step 1");
        _ok("strategy:", strategy);
        checkTrue("strategy has code", strategy.code.length > 0);

        if (attached && safe.isModuleEnabled(strategy)) {
            // Vote 1 has already been executed on chain; verify rather than repeat it.
            _section("enableModule already executed on chain");
            check("isModuleEnabled(strategy)", safe.isModuleEnabled(strategy), true);
        } else {
            checkTrue("strategy is not a module yet", !safe.isModuleEnabled(strategy));
            _section("Safe -> Safe.enableModule(strategy)");
            _execViaDecent(Cfg.SAFE, _enableModuleCalldata(strategy), "enableModule(strategy)");
        }

        _verifyStrategyAndWiring();
    }

    // =====================================================================
    // Verification after the module update
    // =====================================================================

    function _verifyStrategyAndWiring() internal {
        _banner("STEP 4b  |  Verify the execution strategy and the space <-> module wiring");

        IAvatarExecutionStrategy st = IAvatarExecutionStrategy(strategy);

        _section("strategy parameters (same asserts as snapx-strategy.sh check)");
        check("getStrategyType()", st.getStrategyType(), Cfg.AVATAR_STRATEGY_TYPE);
        check("target()  (avatar = Safe)", st.target(), Cfg.SAFE);
        check("owner()   (controller = Safe)", st.owner(), Cfg.SAFE);
        checkQuorum("quorum()", st.quorum(), P.quorum);

        _section("space whitelist on the strategy");
        // The only on-chain link between space and strategy: the strategy decides
        // which spaces may call `execute`. The Space contract itself keeps no
        // execution-strategy whitelist — the strategy is named per proposal.
        check("isSpaceEnabled(space)", st.isSpaceEnabled(space), 1);
        check("isSpaceEnabled(random)", st.isSpaceEnabled(address(0xbeef)), 0);
        checkTrue("only the Safe can enable more spaces", st.owner() == Cfg.SAFE);

        _section("Safe module list");
        _logModules("modules");
        address[] memory mods = _modules();
        check("isModuleEnabled(strategy)", safe.isModuleEnabled(strategy), true);
        check("isModuleEnabled(Azorius)", safe.isModuleEnabled(Cfg.AZORIUS), true);
        if (!attached) {
            check("module count", mods.length, 2);
            check("head of list is the new strategy", mods[0], strategy);
            check("Azorius still present", mods[1], Cfg.AZORIUS);
        }

        _section("Safe owners unchanged (Step 5 handles the owner swap)");
        _logOwners("owners");
        address[] memory owners = safe.getOwners();
        check("owner count", owners.length, 1);
        check("threshold", safe.getThreshold(), 1);
        if (!attached) check("owner still Azorius", owners[0], Cfg.AZORIUS);

        _section("prevModule for Step 5, computed live");
        address prev = _prevModule(Cfg.AZORIUS);
        _ok("prevModule(Azorius):", prev);
        if (!attached) check("prevModule(Azorius) == strategy", prev, strategy);
        console.log("   disableModule calldata:", vm.toString(_disableModuleCalldata(prev)));
    }
}

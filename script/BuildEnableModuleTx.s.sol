// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { SimBase } from "./SimBase.s.sol";
import { Cfg } from "src/Config.sol";
import { ISafe } from "src/interfaces/ISafe.sol";
import { IAvatarExecutionStrategy } from "src/interfaces/ISnapshotX.sol";

/// @title BuildEnableModuleTx — emit the executable calldata for enabling the
///        Snapshot X execution strategy as a Zodiac module on the DAO Safe.
///
/// @notice This is Decent "Vote 1": the single action a passed Azorius proposal
///         runs against the Safe. The action is
///
///             to:        0x36bD3044ab68f600f6d3e081056F34f2a58432c4  (the Safe)
///             value:     0
///             operation: 0 (CALL)
///             data:      enableModule(<strategy>)   selector 0x610b5925
///
///         It MUST be executed with `msg.sender == the Safe` (the Safe's
///         ModuleManager only lets the Safe change its own module list), i.e.
///         wrapped as the action of a Decent proposal, executed via
///         `execTransactionFromModule`. The bytes below are that inner action.
///
///         The strategy address only exists once the real Snapshot X space is
///         created, so pass it in:
///
///             SNAPSHOT_X_STRATEGY=0x… forge script script/BuildEnableModuleTx.s.sol
///             ./sim.sh enable-tx --strategy 0x… [--space 0x…]
///
///         If the strategy is already deployed on the fork it is verified first
///         (type, owner == Safe, target == Safe, quorum, and — with --space —
///         that it whitelists the space). If it is not yet deployed the calldata
///         is still emitted, with a warning that verification was skipped.
///
///         Writes three files under ./sim:
///           enableModule.calldata.txt    the raw 0x… calldata, one line
///           enableModule.tx.json         the full transaction, structured
///           enableModule.safe-batch.json Safe Transaction Builder import
contract BuildEnableModuleTx is SimBase {
    function run() public {
        _setUpForkNoAttach();

        // Attach mode (SNAPSHOT_X_SPACE + SNAPSHOT_X_STRATEGY) sets `strategy`.
        // Otherwise take the strategy from SNAPSHOT_X_STRATEGY on its own.
        if (strategy == address(0)) {
            strategy = vm.envOr("SNAPSHOT_X_STRATEGY", address(0));
        }
        require(
            strategy != address(0),
            "BuildEnableModuleTx: set SNAPSHOT_X_STRATEGY to the Avatar execution strategy address"
            " (find it with ./snapx-strategy.sh from-tx <SPACE_CREATE_TX>)"
        );
        if (space == address(0)) space = vm.envOr("SNAPSHOT_X_SPACE", address(0));

        _banner("BUILD  |  enableModule(strategy) transaction for the DAO Safe");
        _ok("safe:", Cfg.SAFE);
        _ok("module (strategy):", strategy);
        if (space != address(0)) _ok("space:", space);

        _verifyIfDeployed();
        require(failCount == 0, "BuildEnableModuleTx: strategy verification failed - refusing to emit the tx");

        bytes memory data = _enableModuleCalldata(strategy);

        _section("transaction");
        _ok("to:", Cfg.SAFE);
        _ok("value:", uint256(0));
        _ok("operation:", "0 (CALL)");
        console.log("   selector:", vm.toString(abi.encodePacked(ISafe.enableModule.selector)));
        console.log("   data:", vm.toString(data));

        // Sanity: the emitted bytes decode back to the strategy.
        check("selector is enableModule(address)", uint256(uint32(ISafe.enableModule.selector)), uint256(0x610b5925));
        check("decoded module == strategy", abi.decode(_stripSelector(data), (address)), strategy);

        _writeFiles(data);
        _report("BuildEnableModuleTx");
    }

    // =====================================================================
    // Best-effort verification (only if the strategy exists on this fork)
    // =====================================================================

    function _verifyIfDeployed() internal {
        if (strategy.code.length == 0) {
            _section("verification SKIPPED");
            console.log("   strategy has no code on this fork - it is not deployed yet.");
            console.log("   The calldata is still valid; re-run once the space/strategy exist to verify.");
            return;
        }

        _section("verifying the strategy before enabling it");
        IAvatarExecutionStrategy st = IAvatarExecutionStrategy(strategy);

        // Safety checks — these gate whether the module is safe to enable, and BLOCK
        // emission if they fail. A module whose owner/target is the Safe and whose type
        // is the Avatar strategy can only ever drive the treasury via a passed vote.
        check("getStrategyType()", st.getStrategyType(), Cfg.AVATAR_STRATEGY_TYPE);
        check("target()  (avatar = Safe)", st.target(), Cfg.SAFE);
        check("owner()   (controller = Safe)", st.owner(), Cfg.SAFE);
        check("not already a module", safe.isModuleEnabled(strategy), false);
        if (space != address(0)) {
            check("isSpaceEnabled(space)", st.isSpaceEnabled(space), 1);
        } else {
            console.log("   (pass --space to also assert isSpaceEnabled(space) == 1)");
        }

        // Quorum is a policy value, not a safety property: it does not make the module
        // dangerous, so a difference from the configured QUORUM is reported, not blocked.
        uint256 q = st.quorum();
        _ok("quorum() on-chain:", q);
        if (q != P.quorum) {
            console.log("   NOTE: differs from configured QUORUM", P.quorum);
            console.log("   (set QUORUM to match if you want the on-chain value asserted; not blocking)");
        }
    }

    // =====================================================================
    // File output
    // =====================================================================

    function _writeFiles(bytes memory data) internal {
        _section("writing files");

        // 1) raw calldata, one line
        vm.writeFile("./sim/enableModule.calldata.txt", vm.toString(data));
        console.log("   ./sim/enableModule.calldata.txt");

        // 2) structured transaction
        string memory o = "enableModuleTx";
        vm.serializeString(
            o, "description", "Enable the Snapshot X execution strategy as a Zodiac module on Shutter DAO 0x36"
        );
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "safe", Cfg.SAFE);
        vm.serializeAddress(o, "module", strategy);
        vm.serializeAddress(o, "to", Cfg.SAFE);
        vm.serializeString(o, "value", "0");
        vm.serializeUint(o, "operation", 0);
        vm.serializeString(o, "function", "enableModule(address)");
        vm.serializeString(o, "selector", vm.toString(abi.encodePacked(ISafe.enableModule.selector)));
        vm.serializeString(
            o, "executeVia", "Decent/Azorius proposal - msg.sender must be the Safe (execTransactionFromModule)"
        );
        vm.serializeBool(o, "strategyVerifiedOnFork", strategy.code.length > 0);
        string memory txJson = vm.serializeString(o, "data", vm.toString(data));
        vm.writeJson(txJson, "./sim/enableModule.tx.json");
        console.log("   ./sim/enableModule.tx.json");

        // 3) Safe Transaction Builder batch (import into the Safe / Zodiac app)
        vm.writeFile("./sim/enableModule.safe-batch.json", _safeBatch(data));
        console.log("   ./sim/enableModule.safe-batch.json");
    }

    /// @dev The Safe Transaction Builder schema, assembled by hand so it matches exactly.
    ///      The batch's single transaction is a self-call on the Safe.
    function _safeBatch(bytes memory data) internal view returns (string memory) {
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
            '    "name": "Enable Snapshot X strategy as Safe module",\n',
            '    "description": "Shutter DAO 0x36 migration - Decent Vote 1: enableModule(strategy)",\n',
            '    "txBuilderVersion": "1.16.5"\n',
            "  },\n",
            '  "transactions": [\n',
            "    {\n",
            '      "to": "',
            vm.toString(Cfg.SAFE),
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

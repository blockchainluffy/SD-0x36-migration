// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { SimBase } from "./SimBase.s.sol";
import { Cfg } from "src/Config.sol";
import { ISafe } from "src/interfaces/ISafe.sol";
import { MetaTransaction, Operation } from "src/interfaces/ISnapshotX.sol";

/// @title BuildVote2Tx — emit the executable data for "Vote 2": retire Decent.
///
/// @notice Vote 2 is a **Snapshot X proposal** (run through the new governance, not
///         Decent) whose Avatar-strategy execution payload is two actions on the Safe:
///
///           tx[0] swapOwner(0x..01, Azorius, strategy)     selector 0xe318b52b
///           tx[1] disableModule(prevModule, Azorius)        selector 0xe009cfde
///
///         Both target the Safe and run via `execTransactionFromModule`, so they can
///         only be executed by the strategy after a proposal passes. `prevModule` is
///         the strategy (it sits at the head of the Safe's module list), recomputed
///         live here so a wrong value can't cause a silent no-op.
///
///         This is NOT a direct Safe transaction: the Safe's sole owner is a contract
///         that cannot sign, so there is no Safe Transaction Builder path. You enter
///         the two actions into the snapshot.box proposal's execution builder.
///
///         Usage:
///           SNAPSHOT_X_STRATEGY=0x… forge script script/BuildVote2Tx.s.sol
///           ./sim.sh vote2-tx --strategy 0x…
///
///         Writes ./sim/vote2.{actions.json,calldata.txt,executionPayload.txt}.
contract BuildVote2Tx is SimBase {
    function run() public {
        _setUpForkNoAttach();

        if (strategy == address(0)) strategy = vm.envOr("SNAPSHOT_X_STRATEGY", address(0));
        require(strategy != address(0), "BuildVote2Tx: set SNAPSHOT_X_STRATEGY (the new module + intended new owner)");

        _banner("BUILD  |  Vote 2 - swapOwner + disableModule (retire Decent)");
        _ok("safe:", Cfg.SAFE);
        _ok("new owner + module (strategy):", strategy);
        _ok("azorius (removed):", Cfg.AZORIUS);

        address prevModule = _verifyAndComputePrev();

        bytes memory swapData = _swapOwnerCalldata(strategy);
        bytes memory disableData = _disableModuleCalldata(prevModule);

        _section("tx[0]  Safe.swapOwner(0x..01, Azorius, strategy)");
        console.log("   to:  ", Cfg.SAFE);
        console.log("   data:", vm.toString(swapData));
        check("swapOwner selector", uint256(uint32(ISafe.swapOwner.selector)), uint256(0xe318b52b));

        _section("tx[1]  Safe.disableModule(prevModule, Azorius)");
        _ok("prevModule (live):", prevModule);
        console.log("   to:  ", Cfg.SAFE);
        console.log("   data:", vm.toString(disableData));
        check("disableModule selector", uint256(uint32(ISafe.disableModule.selector)), uint256(0xe009cfde));

        // The Snapshot X execution payload = abi.encode(MetaTransaction[]).
        MetaTransaction[] memory txs = new MetaTransaction[](2);
        txs[0] = MetaTransaction({ to: Cfg.SAFE, value: 0, data: swapData, operation: Operation.Call, salt: 0 });
        txs[1] = MetaTransaction({ to: Cfg.SAFE, value: 0, data: disableData, operation: Operation.Call, salt: 1 });
        bytes memory payload = abi.encode(txs);

        _section("Snapshot X execution payload");
        console.log("   keccak256(payload):", vm.toString(keccak256(payload)));
        console.log("   NOTE: the hash depends on each action's `salt`; snapshot.box sets its own.");
        console.log("   Enter the two actions above into the proposal builder - do not rely on this hash.");

        _writeFiles(swapData, disableData, prevModule, payload);
        _report("BuildVote2Tx");
    }

    /// @dev Verify the pre-Vote-2 state where possible, and compute prevModule live.
    function _verifyAndComputePrev() internal returns (address prevModule) {
        _section("state check (before Vote 2)");
        if (strategy.code.length == 0) {
            console.log("   strategy has no code on this fork - emitting calldata without verification.");
            // Best guess: strategy is the list head, so prevModule == strategy.
            return strategy;
        }

        bool stratIsModule = safe.isModuleEnabled(strategy);
        bool azoriusIsModule = safe.isModuleEnabled(Cfg.AZORIUS);
        check("strategy is enabled as a module (Vote 1 done)", stratIsModule, true);
        check("Azorius is still a module (not yet removed)", azoriusIsModule, true);

        address[] memory owners = safe.getOwners();
        _ok("current sole owner:", owners.length == 1 ? owners[0] : address(0));
        if (owners.length == 1) {
            check("owner is still Azorius (swap not yet done)", owners[0], Cfg.AZORIUS);
        }

        prevModule = _prevModule(Cfg.AZORIUS);
        check("prevModule(Azorius) == strategy (list head)", prevModule, strategy);
    }

    function _writeFiles(bytes memory swapData, bytes memory disableData, address prevModule, bytes memory payload)
        internal
    {
        _section("writing files");

        vm.writeFile(
            "./sim/vote2.calldata.txt",
            string.concat("swapOwner:     ", vm.toString(swapData), "\ndisableModule: ", vm.toString(disableData), "\n")
        );
        console.log("   ./sim/vote2.calldata.txt");

        vm.writeFile("./sim/vote2.executionPayload.txt", vm.toString(payload));
        console.log("   ./sim/vote2.executionPayload.txt");

        vm.writeFile("./sim/vote2.actions.json", _actionsJson(swapData, disableData, prevModule));
        console.log("   ./sim/vote2.actions.json");

        vm.writeFile("./sim/vote2.safe-batch.json", _safeBatch(swapData, disableData));
        console.log("   ./sim/vote2.safe-batch.json");
    }

    /// @dev Safe Transaction Builder batch (schema version 1.0), the interchange format the
    ///      snapshot.box execution builder and the Safe app both read. Two transactions, in
    ///      order, each a self-call on the Safe with `operation = 0`. `contractMethod` is
    ///      null so the importer uses the raw `data` verbatim rather than re-encoding it.
    function _safeBatch(bytes memory swapData, bytes memory disableData) internal view returns (string memory) {
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
            '    "name": "Shutter DAO 0x36 - Vote 2: retire Decent (Azorius)",\n',
            '    "description": "swapOwner(Azorius -> Snapshot X strategy) + disableModule(Azorius). ',
            'Executed by the Snapshot X Avatar execution strategy after the vote passes.",\n',
            '    "txBuilderVersion": "1.16.5",\n',
            '    "createdFromSafeAddress": "',
            vm.toString(Cfg.SAFE),
            '"\n',
            "  },\n",
            '  "transactions": [\n',
            _batchTx(swapData),
            ",\n",
            _batchTx(disableData),
            "\n  ]\n",
            "}\n"
        );
    }

    /// @dev One Safe Transaction Builder entry: a value-free self-call carrying raw calldata.
    function _batchTx(bytes memory data) internal pure returns (string memory) {
        return string.concat(
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
            "    }"
        );
    }

    /// @dev The two Safe actions, in the shape you enter into the Snapshot X proposal's
    ///      execution (Avatar / Safe module) transaction builder.
    function _actionsJson(bytes memory swapData, bytes memory disableData, address prevModule)
        internal
        view
        returns (string memory)
    {
        string memory head = string.concat(
            "{\n",
            '  "description": "Shutter DAO 0x36 - Vote 2: retire Decent (swapOwner + disableModule), via Snapshot X",\n',
            '  "chainId": "',
            vm.toString(block.chainid),
            '",\n',
            '  "executeVia": "Snapshot X proposal - Avatar execution strategy (execTransactionFromModule)",\n',
            '  "safe": "',
            vm.toString(Cfg.SAFE),
            '",\n',
            '  "module": "',
            vm.toString(strategy),
            '",\n',
            '  "azorius": "',
            vm.toString(Cfg.AZORIUS),
            '",\n',
            '  "prevModule": "',
            vm.toString(prevModule),
            '",\n',
            '  "transactions": [\n'
        );
        return string.concat(head, _swapAction(swapData), ",\n", _disableAction(disableData, prevModule), "\n  ]\n}\n");
    }

    function _swapAction(bytes memory swapData) internal view returns (string memory) {
        return string.concat(
            "    {\n",
            '      "to": "',
            vm.toString(Cfg.SAFE),
            '",\n',
            '      "value": "0",\n',
            '      "operation": 0,\n',
            '      "function": "swapOwner(address,address,address)",\n',
            '      "args": ["0x0000000000000000000000000000000000000001", "',
            vm.toString(Cfg.AZORIUS),
            '", "',
            vm.toString(strategy),
            '"],\n',
            '      "data": "',
            vm.toString(swapData),
            '"\n',
            "    }"
        );
    }

    function _disableAction(bytes memory disableData, address prevModule) internal view returns (string memory) {
        return string.concat(
            "    {\n",
            '      "to": "',
            vm.toString(Cfg.SAFE),
            '",\n',
            '      "value": "0",\n',
            '      "operation": 0,\n',
            '      "function": "disableModule(address,address)",\n',
            '      "args": ["',
            vm.toString(prevModule),
            '", "',
            vm.toString(Cfg.AZORIUS),
            '"],\n',
            '      "data": "',
            vm.toString(disableData),
            '"\n',
            "    }"
        );
    }
}

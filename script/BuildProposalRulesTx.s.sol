// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { ProposalRulesBase } from "./ProposalRulesBase.s.sol";
import { Cfg } from "src/Config.sol";
import { ISpace, Strategy } from "src/interfaces/ISnapshotX.sol";

/// @title BuildProposalRulesTx: emit the Security Council transaction that applies the
///        new proposal rules (50M SHU threshold, whitelist at 50M, one proposal per
///        address per 24h) to the live space.
///
/// @notice The change is `Space.updateSettings`, which is `onlyOwner`: it is signed and
///         executed by the Security Council multisig, the space controller. It is NOT a
///         DAO Safe transaction and NOT a proposal payload: the DAO Safe does not control
///         the space's settings.
///
///         The builder first applies the transaction on a fork, as the controller, and
///         checks the result. Then it writes, under ./sim:
///
///           proposalRules.calldata.txt               raw calldata, one line
///           proposalRules.tx.json                    to / value / operation / data
///           proposalRules.safe-batch.json            Safe Transaction Builder batch for the SC
///           proposalRules.whitelist-tree.json        the new whitelist (to pin on IPFS)
///           proposalRules.whitelist-metadata.json    template, points at the tree
///           proposalRules.validation-metadata.json   template, points at the above
///
///         Usage:
///           ./sim.sh proposal-rules-tx
///           PV_METADATA_URI=ipfs://… ./sim.sh proposal-rules-tx      (final, with metadata)
///           RATE_LIMIT=0 ./sim.sh proposal-rules-tx                  (threshold-only variant)
contract BuildProposalRulesTx is ProposalRulesBase {
    /// @dev The live metadata of allowed strategy 0 (delegated SHU). It does not change.
    string internal constant SHU_STRATEGY_METADATA =
        "ipfs://bafkreidnutyrx4t6q3ztlekzae56sp63pdubod4fndlhfx2xosoivr7v7u";

    function run() public {
        _setUpFork();
        _useLiveSpaceByDefault();
        _loadRules();

        _banner("BUILD  |  updateSettings - new proposal rules (Security Council)");
        _ok("space:", space);
        _ok("rate limit:", R.rateLimit ? "on" : "OFF (threshold-only variant)");

        address controller = ISpace(space).owner();
        _ok("space controller (must sign):", controller);
        check("controller is the Security Council multisig", controller, Cfg.SECURITY_COUNCIL);
        checkTrue("controller is a contract (a multisig)", controller.code.length > 0);

        bytes memory data = _updateSettingsCalldata();
        _printDecoded();
        _simulate(controller, data);
        _writeFiles(data, controller);
        _report("BuildProposalRulesTx");
    }

    function _printDecoded() internal view {
        Strategy memory pv = _newValidationStrategy();
        _section("transaction");
        _ok("to (the space):", space);
        _ok("value:", uint256(0));
        _ok("operation:", "0 (CALL)");
        console.log("   selector:", vm.toString(abi.encodePacked(ISpace.updateSettings.selector)));
        _ok("new validation strategy:", pv.addr);
        if (R.rateLimit) {
            _ok("  cooldown (seconds):", R.cooldown);
            _ok("  proposals per cooldown:", R.maxProposals);
        }
        _ok("  threshold (wei):", R.threshold);
        _ok("  allowed[0] OZ Votes over SHU:", Cfg.OZ_VOTES_VOTING_STRATEGY);
        _ok("  allowed[1] Merkle whitelist:", Cfg.MERKLE_WHITELIST_VOTING_STRATEGY);
        console.log("     new whitelist root:", vm.toString(_rootAt(R.whitelistVp)));
        _ok("  whitelist deemed power each (wei):", uint256(R.whitelistVp));
        _ok("validation metadata URI:", bytes(R.metadataURI).length > 0 ? R.metadataURI : "(empty)");
        if (bytes(R.metadataURI).length == 0) {
            console.log("");
            console.log("   WARNING: PV_METADATA_URI is empty. Pin the three metadata files (see");
            console.log("   docs/PROPOSAL_RULES.md, 'Metadata') and rebuild with PV_METADATA_URI=ipfs://...");
        }
    }

    /// @dev Applies the transaction on the fork exactly as the SC would, then checks it.
    function _simulate(address controller, bytes memory data) internal {
        _section("pre-flight on a fork, sent from the controller");
        (address liveAddr,) = ISpace(space).proposalValidationStrategy();
        _ok("validation strategy now:", liveAddr);

        vm.prank(controller);
        (bool ok,) = space.call(data);
        checkTrue("updateSettings succeeds from the controller", ok);

        Strategy memory want = _newValidationStrategy();
        (address addr, bytes memory params) = ISpace(space).proposalValidationStrategy();
        check("stored validation strategy", addr, want.addr);
        checkBytes("stored params", params, want.params);

        checkTrue("a whitelisted member can propose with the new proof", _tryPropose(_m(7), _viaNewWhitelist(7), "wl"));
        checkRejected("the old 10M proof is rejected", _m(0), _viaOldWhitelist(0), INVALID_PROOF);
        if (R.rateLimit) {
            checkRejected("a second proposal at once is rejected", _m(7), _viaNewWhitelist(7), FAILED_VALIDATION);
        }
    }

    function _m(uint256 i) internal pure returns (address) {
        return Cfg.whitelistedProposers()[i];
    }

    // =====================================================================
    // Files
    // =====================================================================

    function _writeFiles(bytes memory data, address controller) internal {
        _section("writing files");

        vm.writeFile("./sim/proposalRules.calldata.txt", string.concat(vm.toString(data), "\n"));
        console.log("   ./sim/proposalRules.calldata.txt");

        vm.writeFile("./sim/proposalRules.tx.json", _txJson(data, controller));
        console.log("   ./sim/proposalRules.tx.json");

        vm.writeFile("./sim/proposalRules.safe-batch.json", _safeBatch(data, controller));
        console.log("   ./sim/proposalRules.safe-batch.json");

        vm.writeFile("./sim/proposalRules.whitelist-tree.json", _treeJson());
        console.log("   ./sim/proposalRules.whitelist-tree.json");

        vm.writeFile(
            "./sim/proposalRules.whitelist-metadata.json",
            '{"name":"Whitelist","properties":{"symbol":"SHU","decimals":0,"payload":"ipfs://<CID of proposalRules.whitelist-tree.json>"}}\n'
        );
        console.log("   ./sim/proposalRules.whitelist-metadata.json   (template: fill in the CID)");

        vm.writeFile(
            "./sim/proposalRules.validation-metadata.json",
            string.concat(
                '{"strategies_metadata":["',
                SHU_STRATEGY_METADATA,
                '","ipfs://<CID of proposalRules.whitelist-metadata.json>"]}\n'
            )
        );
        console.log("   ./sim/proposalRules.validation-metadata.json  (template: fill in the CID)");
    }

    /// @dev Same shape as the live whitelist tree snapshot.box pinned at space creation.
    function _treeJson() internal view returns (string memory out) {
        address[9] memory a = Cfg.whitelistedProposers();
        out = '{"tree":[';
        for (uint256 i; i < a.length; i++) {
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                '{"address":"',
                vm.toString(a[i]),
                '","votingPower":"',
                vm.toString(uint256(R.whitelistVp)),
                '"}'
            );
        }
        out = string.concat(out, "]}\n");
    }

    function _txJson(bytes memory data, address controller) internal view returns (string memory) {
        return string.concat(
            "{\n",
            '  "description": "Shutter DAO 0x36 - new proposal rules (50M SHU threshold, whitelist at 50M',
            R.rateLimit ? ', one proposal per address per 24h)",\n' : ')",\n',
            '  "chainId": "',
            vm.toString(block.chainid),
            '",\n',
            '  "executedBy": "',
            vm.toString(controller),
            '",\n',
            '  "to": "',
            vm.toString(space),
            '",\n',
            '  "value": "0",\n',
            '  "operation": 0,\n',
            '  "function": "updateSettings((uint32,uint32,uint32,string,string,(address,bytes),string,address[],address[],(address,bytes)[],string[],uint8[]))",\n',
            '  "data": "',
            vm.toString(data),
            '"\n}\n'
        );
    }

    /// @dev Safe Transaction Builder batch (schema 1.0) for the Security Council Safe.
    ///      `contractMethod` is null so the importer sends the raw `data` verbatim.
    function _safeBatch(bytes memory data, address controller) internal view returns (string memory) {
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
            '    "name": "Shutter DAO 0x36 - new Snapshot X proposal rules",\n',
            '    "description": "Space.updateSettings: proposal validation -> 50M SHU threshold, whitelist at 50M',
            R.rateLimit ? ', one proposal per address per 24h.",\n' : '.",\n',
            '    "txBuilderVersion": "1.16.5",\n',
            '    "createdFromSafeAddress": "',
            vm.toString(controller),
            '"\n',
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
}

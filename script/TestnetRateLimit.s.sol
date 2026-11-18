// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";

import { Cfg } from "src/Config.sol";
import { Merkle } from "src/Merkle.sol";
import {
    ISpace,
    IndexedStrategy,
    Strategy,
    UpdateSettingsCalldata,
    WhitelistMember
} from "src/interfaces/ISnapshotX.sol";

/// @title TestnetRateLimit: switch a Sepolia test space to the rate-limited validator.
///
/// @notice Used to test, on testnet.snapshot.box, whether the website can still create
///         proposals once a space uses `PropositionPowerAndActiveProposalsLimiter`.
///
///         MODE=apply (default) reads the space's current `PropositionPower` settings and
///         replaces them with the rate-limited validator. The threshold and the allowed
///         strategies (for example the Merkle whitelist) are copied unchanged. Only the
///         validator contract changes and the limit is added.
///
///         MODE=revert switches back to the plain `PropositionPower` validator, with the
///         same threshold and allowed strategies, so the space works on the website again.
///
///         Both modes change only the proposal validation strategy. The transaction must
///         be sent by the space controller.
///
///         Without `--broadcast` this is a dry run on a Sepolia fork: nothing is sent.
///         With `--broadcast` the transaction is signed with SEPOLIA_PRIVATE_KEY from .env,
///         which must be the key of the space controller.
///
///         Usage:
///           ./sim.sh testnet-rate-limit --space 0x…                          dry run
///           ./sim.sh testnet-rate-limit --space 0x… --broadcast              apply
///           MODE=revert ./sim.sh testnet-rate-limit --space 0x… --broadcast  switch back
///
///         Env:
///           SPACE                   the space (required)
///           SEPOLIA_PRIVATE_KEY     controller's key, needed only with --broadcast
///           MODE                    apply | revert                  (default apply)
///           COOLDOWN                seconds per proposal window      (default 86400)
///           MAX_PROPOSALS           proposals per window             (default 1)
///           WHITELIST               optional "0xaddr:power,0xaddr:power", the whitelist
///                                   as entered on snapshot.box. When set, the dry run
///                                   checks it matches the on-chain root and simulates
///                                   proposals by the first member.
///           PV_METADATA_URI         optional metadata URI to emit    (default empty)
///           SEPOLIA_RPC_URL         RPC                              (default public node)
contract TestnetRateLimit is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    bytes4 internal constant FAILED_VALIDATION = bytes4(keccak256("FailedToPassProposalValidation()"));

    address internal space;

    function run() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com"));
        vm.createSelectFork(rpc);
        require(block.chainid == SEPOLIA_CHAIN_ID, "RPC is not Sepolia");

        space = vm.envAddress("SPACE");
        require(space.code.length > 0, "SPACE has no code on Sepolia");
        string memory mode = vm.envOr("MODE", string("apply"));
        bool applying = keccak256(bytes(mode)) == keccak256("apply");
        require(applying || keccak256(bytes(mode)) == keccak256("revert"), "MODE must be apply or revert");

        address controller = ISpace(space).owner();
        console.log("");
        console.log("== space on Sepolia, block:", block.number);
        console.log("   space:     ", space);
        console.log("   controller:", controller, controller.code.length > 0 ? "(contract)" : "(wallet)");

        (address addr, uint256 cooldown, uint256 maxProposals, uint256 threshold, Strategy[] memory allowed) =
            _currentRules();
        _printRules("current proposal validation", addr, cooldown, maxProposals, threshold, allowed);

        Strategy memory next;
        if (applying) {
            require(
                addr == Cfg.PROPOSITION_POWER_VALIDATION,
                addr == Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION
                    ? "already rate-limited; use MODE=revert to switch back"
                    : "space does not use PropositionPower; nothing to wrap"
            );
            cooldown = vm.envOr("COOLDOWN", uint256(24 hours));
            maxProposals = vm.envOr("MAX_PROPOSALS", uint256(1));
            require(maxProposals > 0, "MAX_PROPOSALS must be at least 1");
            next = Strategy({
                addr: Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION,
                params: abi.encode(cooldown, maxProposals, threshold, allowed)
            });
        } else {
            require(
                addr == Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION, "space is not rate-limited; nothing to revert"
            );
            next = Strategy({ addr: Cfg.PROPOSITION_POWER_VALIDATION, params: abi.encode(threshold, allowed) });
        }

        bytes memory data = abi.encodeCall(ISpace.updateSettings, (_settings(next)));

        // The only transaction in this script. With --broadcast it is signed with
        // SEPOLIA_PRIVATE_KEY, which must belong to the controller. Without a key the
        // change is only applied on the local fork, as the controller, to check it.
        uint256 key = vm.envOr("SEPOLIA_PRIVATE_KEY", uint256(0));
        if (key != 0) {
            require(vm.addr(key) == controller, "SEPOLIA_PRIVATE_KEY is not the space controller");
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast(controller);
        }
        ISpace(space).updateSettings(_settings(next));
        vm.stopBroadcast();

        (address newAddr, uint256 newCooldown, uint256 newMax, uint256 newThreshold, Strategy[] memory newAllowed) =
            _currentRules();
        _printRules("proposal validation after the change", newAddr, newCooldown, newMax, newThreshold, newAllowed);
        (, bytes memory storedParams) = ISpace(space).proposalValidationStrategy();
        require(newAddr == next.addr && keccak256(storedParams) == keccak256(next.params), "stored settings differ");
        require(newThreshold == threshold, "threshold changed");
        console.log("   OK: only the validator changed; threshold and allowed strategies are identical.");

        if (applying) _simulateWhitelistProposals(allowed, cooldown);

        vm.writeFile("./sim/testnet.updateSettings.calldata.txt", string.concat(vm.toString(data), "\n"));
        console.log("");
        console.log("== transaction (sent by the controller with --broadcast)");
        console.log("   to:  ", space);
        console.log("   data written to ./sim/testnet.updateSettings.calldata.txt");
    }

    // =====================================================================
    // Settings
    // =====================================================================

    /// @dev `updateSettings` input that changes ONLY the proposal validation strategy.
    ///      Every other field is left at its NO_UPDATE sentinel (sx-evm Space.sol).
    function _settings(Strategy memory pv) internal view returns (UpdateSettingsCalldata memory u) {
        uint32 NO_U32 = uint32(bytes4(keccak256(abi.encodePacked("No update"))));
        u.minVotingDuration = NO_U32;
        u.maxVotingDuration = NO_U32;
        u.votingDelay = NO_U32;
        u.metadataURI = "No update";
        u.daoURI = "No update";
        u.proposalValidationStrategy = pv;
        u.proposalValidationStrategyMetadataURI = vm.envOr("PV_METADATA_URI", string(""));
    }

    function _currentRules()
        internal
        view
        returns (address addr, uint256 cooldown, uint256 maxProposals, uint256 threshold, Strategy[] memory allowed)
    {
        bytes memory params;
        (addr, params) = ISpace(space).proposalValidationStrategy();
        if (addr == Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION) {
            (cooldown, maxProposals, threshold, allowed) = abi.decode(params, (uint256, uint256, uint256, Strategy[]));
        } else if (addr == Cfg.PROPOSITION_POWER_VALIDATION) {
            (threshold, allowed) = abi.decode(params, (uint256, Strategy[]));
        }
    }

    function _printRules(
        string memory title,
        address addr,
        uint256 cooldown,
        uint256 maxProposals,
        uint256 threshold,
        Strategy[] memory allowed
    ) internal pure {
        console.log("");
        console.log(string.concat("== ", title));
        console.log("   validator:", addr, _validatorName(addr));
        if (addr == Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION) {
            console.log("   cooldown (seconds):    ", cooldown);
            console.log("   proposals per cooldown:", maxProposals);
        }
        console.log("   threshold:", threshold);
        for (uint256 i; i < allowed.length; i++) {
            console.log(
                string.concat("   allowed[", vm.toString(i), "]:"), allowed[i].addr, _strategyName(allowed[i].addr)
            );
            console.log("      params:", vm.toString(allowed[i].params));
        }
    }

    function _validatorName(address a) internal pure returns (string memory) {
        if (a == Cfg.PROPOSITION_POWER_VALIDATION) return "(PropositionPower)";
        if (a == Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION) return "(PropositionPowerAndActiveProposalsLimiter)";
        return "(unknown)";
    }

    function _strategyName(address a) internal pure returns (string memory) {
        if (a == Cfg.MERKLE_WHITELIST_VOTING_STRATEGY) return "(Merkle whitelist)";
        if (a == Cfg.OZ_VOTES_VOTING_STRATEGY) return "(ERC-20 Votes)";
        return "";
    }

    // =====================================================================
    // Optional dry-run check with the whitelist
    // =====================================================================

    /// @dev Only on the local fork (vm.prank is never broadcast). Shows that the new rules
    ///      work on chain: the first member can propose, a second proposal at once is
    ///      rejected, and one is accepted again after the cooldown.
    function _simulateWhitelistProposals(Strategy[] memory allowed, uint256 cooldown) internal {
        string memory list = vm.envOr("WHITELIST", string(""));
        if (bytes(list).length == 0) {
            console.log("");
            console.log("   (set WHITELIST=\"0xaddr:power,...\" to also simulate proposals on the fork)");
            return;
        }

        uint256 wlIndex = type(uint256).max;
        for (uint256 i; i < allowed.length; i++) {
            if (allowed[i].addr == Cfg.MERKLE_WHITELIST_VOTING_STRATEGY) wlIndex = i;
        }
        require(wlIndex != type(uint256).max, "WHITELIST set, but the space has no Merkle whitelist strategy");

        (address[] memory addrs, uint96[] memory powers) = _parseWhitelist(list);
        bytes32[] memory leaves = new bytes32[](addrs.length);
        for (uint256 i; i < addrs.length; i++) {
            leaves[i] = Merkle.whitelistLeaf(addrs[i], powers[i]);
        }
        bytes32 root = Merkle.root(leaves);
        require(root == abi.decode(allowed[wlIndex].params, (bytes32)), "WHITELIST does not match the on-chain root");

        console.log("");
        console.log("== simulated on the fork only (not broadcast)");
        console.log("   WHITELIST matches the on-chain root:", vm.toString(root));
        console.log("   proposer:", addrs[0]);

        IndexedStrategy[] memory user = new IndexedStrategy[](1);
        user[0] = IndexedStrategy({
            index: uint8(wlIndex),
            params: abi.encode(Merkle.proof(leaves, leaves[0]), WhitelistMember({ addr: addrs[0], vp: powers[0] }))
        });

        uint256 t0 = block.timestamp;
        require(_propose(addrs[0], user) == bytes4(0), "first proposal was rejected");
        console.log("   first proposal:              accepted");
        require(_propose(addrs[0], user) == FAILED_VALIDATION, "second proposal was not rate-limited");
        console.log("   second proposal at once:     rejected (FailedToPassProposalValidation)");
        vm.warp(t0 + cooldown);
        require(_propose(addrs[0], user) == bytes4(0), "proposal after the cooldown was rejected");
        console.log("   proposal after the cooldown: accepted");
    }

    /// @dev Proposes through the EthTx authenticator as `author`, with no execution.
    ///      Returns 0 on success, otherwise the revert selector.
    function _propose(address author, IndexedStrategy[] memory user) internal returns (bytes4) {
        Strategy memory noExecution = Strategy({ addr: address(0), params: "" });
        bytes memory data = abi.encode(author, "rate limit test", noExecution, abi.encode(user));
        vm.prank(author);
        (bool ok, bytes memory ret) = Cfg.ETH_TX_AUTHENTICATOR
            .call(abi.encodeWithSignature("authenticate(address,bytes4,bytes)", space, ISpace.propose.selector, data));
        if (ok) return bytes4(0);
        return ret.length >= 4 ? bytes4(ret) : bytes4(0xffffffff);
    }

    function _parseWhitelist(string memory list)
        internal
        pure
        returns (address[] memory addrs, uint96[] memory powers)
    {
        string[] memory entries = vm.split(list, ",");
        addrs = new address[](entries.length);
        powers = new uint96[](entries.length);
        for (uint256 i; i < entries.length; i++) {
            string[] memory pair = vm.split(vm.trim(entries[i]), ":");
            require(pair.length == 2, "WHITELIST entries must be 0xaddr:power");
            addrs[i] = vm.parseAddress(vm.trim(pair[0]));
            powers[i] = uint96(vm.parseUint(vm.trim(pair[1])));
        }
    }
}

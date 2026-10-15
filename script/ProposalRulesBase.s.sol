// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SimBase } from "./SimBase.s.sol";
import { Cfg } from "src/Config.sol";
import { Merkle } from "src/Merkle.sol";
import {
    ISpace,
    IndexedStrategy,
    Strategy,
    UpdateSettingsCalldata,
    WhitelistMember
} from "src/interfaces/ISnapshotX.sol";

/// @title ProposalRulesBase
/// @notice Shared pieces for the proposal-rules change on the live space:
///
///           1. raise the proposition-power threshold from 10M to 50M SHU;
///           2. raise each whitelisted proposer's deemed SHU power from 10M to 50M,
///              so the nine members keep their proposer role;
///           3. allow one proposal per address every 24 hours.
///
///         All three are ONE `Space.updateSettings` call by the space controller (the
///         Security Council) that swaps the proposal validation strategy:
///
///           before  PropositionPower                     (threshold, strategies)
///           after   PropositionPowerAndActiveProposalsLimiter
///                                                         (cooldown, max, threshold, strategies)
///
///         The allowed strategies stay [delegated SHU, Merkle whitelist]; only the
///         whitelist's Merkle root changes (same nine addresses, 50M each).
///
///         RATE_LIMIT=0 builds the threshold-only variant instead: the same 50M changes,
///         but the plain PropositionPower contract and no 24h limit. That variant is the
///         one snapshot.box can display and propose against today (see the doc).
/// @dev    Env overrides: NEW_PROPOSAL_THRESHOLD, NEW_WHITELIST_VP, PROPOSAL_COOLDOWN,
///         MAX_PROPOSALS_PER_COOLDOWN, RATE_LIMIT, PV_METADATA_URI.
abstract contract ProposalRulesBase is SimBase {
    struct Rules {
        bool rateLimit;
        uint256 threshold;
        uint96 whitelistVp;
        uint256 cooldown;
        uint256 maxProposals;
        string metadataURI;
    }

    Rules internal R;

    /// @dev The threshold and whitelist power the live space is expected to have today.
    uint256 internal constant OLD_THRESHOLD = 10_000_000e18;

    function _loadRules() internal {
        R.rateLimit = vm.envOr("RATE_LIMIT", true);
        R.threshold = vm.envOr("NEW_PROPOSAL_THRESHOLD", Cfg.NEW_PROPOSAL_THRESHOLD);
        R.whitelistVp = uint96(vm.envOr("NEW_WHITELIST_VP", uint256(Cfg.NEW_WHITELIST_VP)));
        R.cooldown = vm.envOr("PROPOSAL_COOLDOWN", Cfg.PROPOSAL_COOLDOWN);
        R.maxProposals = vm.envOr("MAX_PROPOSALS_PER_COOLDOWN", Cfg.MAX_PROPOSALS_PER_COOLDOWN);
        // The IPFS document snapshot.box reads to find each allowed strategy's metadata
        // (including where the whitelist tree is). See the doc, "Metadata".
        R.metadataURI = vm.envOr("PV_METADATA_URI", string(""));
    }

    /// @dev Attach mode is the point of these scripts, so default to the live deployment
    ///      when SNAPSHOT_X_SPACE / SNAPSHOT_X_STRATEGY are not set.
    function _useLiveSpaceByDefault() internal {
        if (!attached) {
            attached = true;
            space = Cfg.LIVE_SPACE;
            strategy = Cfg.LIVE_STRATEGY;
            strategyDeployed = true;
        }
    }

    // =====================================================================
    // The new settings
    // =====================================================================

    /// @notice The nine whitelist members at deemed power `vp`, as Merkle leaves.
    function _leavesAt(uint96 vp) internal pure returns (bytes32[] memory leaves) {
        address[9] memory a = Cfg.whitelistedProposers();
        leaves = new bytes32[](a.length);
        for (uint256 i; i < a.length; i++) {
            leaves[i] = Merkle.whitelistLeaf(a[i], vp);
        }
    }

    function _rootAt(uint96 vp) internal pure returns (bytes32) {
        return Merkle.root(_leavesAt(vp));
    }

    /// @notice [delegated SHU, Merkle whitelist at `vp`], in the live order.
    function _allowedStrategiesAt(uint96 vp) internal pure returns (Strategy[] memory out) {
        out = new Strategy[](2);
        out[0] = Strategy({ addr: Cfg.OZ_VOTES_VOTING_STRATEGY, params: abi.encodePacked(Cfg.SHU) });
        out[1] = Strategy({ addr: Cfg.MERKLE_WHITELIST_VOTING_STRATEGY, params: abi.encode(_rootAt(vp)) });
    }

    /// @notice The proposal validation strategy the space should have after the change.
    function _newValidationStrategy() internal view returns (Strategy memory) {
        Strategy[] memory allowed = _allowedStrategiesAt(R.whitelistVp);
        if (R.rateLimit) {
            return Strategy({
                addr: Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION,
                params: abi.encode(R.cooldown, R.maxProposals, R.threshold, allowed)
            });
        }
        return Strategy({ addr: Cfg.PROPOSITION_POWER_VALIDATION, params: abi.encode(R.threshold, allowed) });
    }

    /// @notice `updateSettings` input that changes ONLY the proposal validation strategy.
    ///         Every other field is left at its NO_UPDATE sentinel (sx-evm Space.sol).
    function _newSettings() internal view returns (UpdateSettingsCalldata memory u) {
        uint32 NO_U32 = uint32(bytes4(keccak256(abi.encodePacked("No update"))));
        u.minVotingDuration = NO_U32;
        u.maxVotingDuration = NO_U32;
        u.votingDelay = NO_U32;
        u.metadataURI = "No update";
        u.daoURI = "No update";
        u.proposalValidationStrategy = _newValidationStrategy();
        u.proposalValidationStrategyMetadataURI = R.metadataURI;
        // all dynamic arrays stay empty (no add/remove)
    }

    function _updateSettingsCalldata() internal view returns (bytes memory) {
        return abi.encodeCall(ISpace.updateSettings, (_newSettings()));
    }

    // =====================================================================
    // Reading the live settings
    // =====================================================================

    /// @notice Decodes the live proposal validation strategy, whichever of the two it is.
    function _liveRules()
        internal
        view
        returns (address addr, uint256 cooldown, uint256 maxProposals, uint256 threshold, Strategy[] memory allowed)
    {
        bytes memory params;
        (addr, params) = ISpace(space).proposalValidationStrategy();
        if (addr == Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION) {
            (cooldown, maxProposals, threshold, allowed) = abi.decode(params, (uint256, uint256, uint256, Strategy[]));
        } else {
            (threshold, allowed) = abi.decode(params, (uint256, Strategy[]));
        }
    }

    // =====================================================================
    // Proposal helpers
    // =====================================================================

    /// @notice userParams for a whitelist member proving deemed power `vp`.
    /// @dev    Merkle strategy encoding: abi.encode(bytes32[] proof, Member member).
    function _viaWhitelistAt(uint256 memberIndex, uint96 vp, address claimedAddr)
        internal
        pure
        returns (IndexedStrategy[] memory out)
    {
        bytes32[] memory leaves = _leavesAt(vp);
        WhitelistMember memory member = WhitelistMember({ addr: claimedAddr, vp: vp });
        bytes32[] memory proof = Merkle.proof(leaves, leaves[memberIndex]);
        out = new IndexedStrategy[](1);
        out[0] = IndexedStrategy({ index: 1, params: abi.encode(proof, member) });
    }

    function _viaNewWhitelist(uint256 memberIndex) internal view returns (IndexedStrategy[] memory) {
        return _viaWhitelistAt(memberIndex, R.whitelistVp, Cfg.whitelistedProposers()[memberIndex]);
    }

    function _viaOldWhitelist(uint256 memberIndex) internal pure returns (IndexedStrategy[] memory) {
        return _viaWhitelistAt(memberIndex, Cfg.WHITELIST_VP, Cfg.whitelistedProposers()[memberIndex]);
    }

    // Why a proposal was rejected. Checking the exact error makes sure a "rejected"
    // result comes from the rule being tested and not from some unrelated failure.

    /// @dev sx-evm Space: the validation strategy returned false (too little power, or
    ///      the rate limit was hit).
    bytes4 internal constant FAILED_VALIDATION = bytes4(keccak256("FailedToPassProposalValidation()"));
    /// @dev MerkleWhitelistVotingStrategy: the (address, power) leaf is not in the tree.
    bytes4 internal constant INVALID_PROOF = bytes4(keccak256("InvalidProof()"));
    /// @dev MerkleWhitelistVotingStrategy: the proof is for a different address.
    bytes4 internal constant INVALID_MEMBER = bytes4(keccak256("InvalidMember()"));

    /// @notice Asserts that `author` cannot propose, and that the revert is `want`.
    function checkRejected(string memory label, address author, IndexedStrategy[] memory userStrategies, bytes4 want)
        internal
    {
        bytes memory data = abi.encode(author, label, _proposalExec(), abi.encode(userStrategies));
        vm.prank(author);
        (bool ok, bytes memory ret) = Cfg.ETH_TX_AUTHENTICATOR
            .call(abi.encodeWithSignature("authenticate(address,bytes4,bytes)", space, ISpace.propose.selector, data));
        bytes4 got = ret.length >= 4 ? bytes4(ret) : bytes4(0);
        if (ok) {
            check(label, string("accepted"), string("rejected"));
        } else {
            check(label, vm.toString(abi.encodePacked(got)), vm.toString(abi.encodePacked(want)));
        }
    }

    function _proposalExec() internal view returns (Strategy memory) {
        return Strategy({ addr: strategy, params: _vetoPayload() });
    }

    /// @notice A sim-only SHU holder with exactly `amount` of delegated voting power.
    /// @dev    SIM-ONLY. Funded out of the treasury on the fork so the threshold can be
    ///         tested at its exact edge. Rolls one block so the votes are readable.
    function _holderWith(string memory name, uint256 amount) internal returns (address holder) {
        holder = address(uint160(uint256(keccak256(abi.encodePacked("shutter.sim.holder.", name)))));
        _topUp(holder, amount);
        vm.prank(holder);
        shu.delegate(holder);
        vm.roll(block.number + 1);
    }

    /// @dev Brings `holder`'s balance to exactly `amount` (from the treasury, sim-only).
    function _topUp(address holder, uint256 amount) internal {
        uint256 have = shu.balanceOf(holder);
        if (amount > have) {
            vm.prank(Cfg.SAFE);
            require(shu.transfer(holder, amount - have), "holder funding failed");
        }
    }
}

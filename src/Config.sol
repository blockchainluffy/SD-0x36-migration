// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Cfg
/// @notice Every fixed address the Shutter DAO 0x36 migration touches, in one place.
/// @dev    DAO values were read from Ethereum mainnet (see MIGRATION.md sec 1).
///         Snapshot X values come from snapshot-labs/sx-evm `deployments/ethereum.json`.
library Cfg {
    // ---------------------------------------------------------------------
    // Shutter DAO 0x36 (Ethereum mainnet)
    // ---------------------------------------------------------------------

    /// @notice The DAO Safe: treasury, avatar and target of every governance action.
    address internal constant SAFE = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;

    /// @notice Decent / Azorius Zodiac module. Currently the Safe's only module AND only owner.
    address internal constant AZORIUS = 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e;

    /// @notice Azorius freeze guard, owned by the Security Council.
    address internal constant FREEZE_GUARD = 0xB04f553c482063a99B10C55033b56BD50b6B0334;

    // ---------------------------------------------------------------------
    // How Decent gates proposal creation today.
    //
    // NOT a Safe module. Azorius holds a list of *voting strategies*, and each
    // strategy decides for itself who may open a proposal:
    //
    //   AZORIUS_STRATEGY_HATS  requiredProposerWeight() == 0, but the author must
    //                          wear PROPOSER_HAT_ID in Hats Protocol.
    //   AZORIUS_STRATEGY_TOKEN requiredProposerWeight() == 1,000,000 SHU, no hat.
    //
    // Both die with Azorius: they are only reachable through the module, so
    // `disableModule(Azorius)` retires them without any extra transaction.
    // ---------------------------------------------------------------------

    /// @notice Azorius `LinearERC20VotingWithHatsProposalCreation` strategy.
    address internal constant AZORIUS_STRATEGY_HATS = 0x7FF645b803FF3Bc890e3568B503BC1F37d32Edd1;

    /// @notice Azorius `LinearERC20Voting` strategy — 1M SHU to propose.
    address internal constant AZORIUS_STRATEGY_TOKEN = 0x4b29d8B250B8b442ECfCd3a4e3D91933d2db720F;

    /// @notice Hats Protocol v1 on Ethereum mainnet.
    address internal constant HATS_PROTOCOL = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;

    /// @notice The proposer hat, tree 64 hat 64.1.2. Its nine wearers are exactly the
    ///         nine addresses the migration doc puts in the Snapshot X whitelist.
    uint256 internal constant PROPOSER_HAT_ID = 0x0000004000010002000000000000000000000000000000000000000000000000;

    /// @notice Top hat of tree 64. Worn by the DAO Safe, so the DAO admins the tree.
    uint256 internal constant TOP_HAT_ID = 0x0000004000000000000000000000000000000000000000000000000000000000;

    /// @notice Decent's proposer threshold on the token-gated strategy.
    uint256 internal constant DECENT_PROPOSER_THRESHOLD = 1_000_000e18;

    /// @notice Security Council multisig. Intended Snapshot X space controller.
    address internal constant SECURITY_COUNCIL = 0x3ea731dAF66D6A7980549f90152CD9A761B9c0C0;

    /// @notice SHU, an ERC20Votes token (CLOCK_MODE = mode=blocknumber).
    address internal constant SHU = 0xe485E2f1bab389C08721B291f6b59780feC83Fd7;

    /// @notice The doc's "Delegation contract address". Delegation type is ERC-20 Votes, so
    ///         delegation is native to the token — this IS the SHU token. It is not a
    ///         separate on-chain object and is not a Space.initialize parameter; the voting
    ///         strategy reads it via getPastVotes. The rest of the doc's DELEGATIONS section
    ///         (API name, type, subgraph URL) is off-chain snapshot.box metadata.
    address internal constant DELEGATION_CONTRACT = SHU;

    /// @notice Head/tail marker of the Safe's owner and module linked lists.
    address internal constant SENTINEL = 0x0000000000000000000000000000000000000001;

    /// @notice keccak256("guard_manager.guard.address") — Safe v1.3.0 guard storage slot.
    bytes32 internal constant GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    // ---------------------------------------------------------------------
    // Snapshot X / sx-evm (Ethereum mainnet)
    // ---------------------------------------------------------------------

    address internal constant PROXY_FACTORY = 0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c;
    address internal constant SPACE_IMPL = 0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D;
    address internal constant AVATAR_EXECUTION_STRATEGY_IMPL = 0xecE4f6b01a2d7FF5A9765cA44162D453fC455e42;
    address internal constant OZ_VOTES_VOTING_STRATEGY = 0x2c8631584474E750CEdF2Fb6A904f2e84777Aefe;
    address internal constant ETH_TX_AUTHENTICATOR = 0xBA06E6cCb877C332181A6867c05c8b746A21Aed1;
    address internal constant ETH_SIG_AUTHENTICATOR = 0x95CF9B585fDb12DeB78002B5643dFF8fe67a496D;
    address internal constant PROPOSITION_POWER_VALIDATION = 0x6D9d6D08EF6b26348Bd18F1FC8D953696b7cf311;
    address internal constant WHITELIST_VOTING_STRATEGY = 0x3CEE21A33751A2722413fF62dEC3dEc48e7748A4;
    /// @notice The whitelist variant the snapshot.box UI actually deploys: stores a merkle
    ///         root in params (not the member array). This is what a real space uses.
    address internal constant MERKLE_WHITELIST_VOTING_STRATEGY = 0x34f0AfFF5A739bBf3E285615F50e40ddAaf2A829;

    /// @notice `getStrategyType()` of AvatarExecutionStrategy.
    string internal constant AVATAR_STRATEGY_TYPE = "SimpleQuorumAvatar";

    // ---------------------------------------------------------------------
    // Proposal-validation whitelist — doc, "PROPOSAL VALIDATION STRATEGY 2"
    //
    // Nine addresses given 10,000,000 SHU of proposition power each so they can
    // open proposals without holding SHU. The Snapshot X equivalent of Decent's
    // nine role-assigned proposers.
    // ---------------------------------------------------------------------

    /// @notice 10,000,000 SHU — the per-member voting power in the whitelist.
    uint96 internal constant WHITELIST_VP = 10_000_000e18;

    function whitelistedProposers() internal pure returns (address[9] memory) {
        return [
            0xffFA76e332cA7afaae3931cb5d513B7fd681C4CF,
            0xe52C39327FF7576bAEc3DBFeF0787bd62dB6d726,
            0xDffDb9BeeA2aB3151BcBcf37a01EE8726F22ed94,
            0x61C2dAE896f93e5f0f10425914CE7868eE8A0e44,
            0x06c2c4dB3776D500636DE63e4F109386dCBa6Ae2,
            0x1F3D3A7A9c548bE39539b39D7400302753E20591,
            0x057928bc52bD08e4D7cE24bF47E01cE99E074048,
            0x302a65C78da31B9ec333c62B90d35D2e70fb3f4E,
            0x0f853a4c50763e0553Ac44E2546C0178B417c0Ba
        ];
    }

    // ---------------------------------------------------------------------
    // Simulation-only actors (never real addresses)
    // ---------------------------------------------------------------------

    address internal constant SIM_PROPOSER = address(uint160(uint256(keccak256("shutter.sim.proposer"))));
    address internal constant SIM_VOTER = address(uint160(uint256(keccak256("shutter.sim.voter"))));
    address internal constant SIM_PAYEE = address(uint160(uint256(keccak256("shutter.sim.payee"))));

    /// @notice Stand-in for the doc's "Punit's dev address": the wallet that signs
    ///         "Create" on snapshot.box and is the space's controller until it is
    ///         handed to the Security Council. Override with SPACE_DEPLOYER.
    address internal constant SIM_DEV_WALLET = address(uint160(uint256(keccak256("shutter.sim.dev-wallet"))));
}

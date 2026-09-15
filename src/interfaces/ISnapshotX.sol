// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ---------------------------------------------------------------------------
// Minimal, ABI-exact mirrors of snapshot-labs/sx-evm.
//
// Field order and types are copied verbatim from sx-evm `src/types.sol` so that
// `abi.encode` here produces byte-identical calldata to the deployed contracts.
// Only what the migration needs is declared.
// ---------------------------------------------------------------------------

/// @dev Mirrors Safe's `Enum.Operation`, used inside MetaTransaction.
enum Operation {
    Call,
    DelegateCall
}

enum Choice {
    Against,
    For,
    Abstain
}

enum FinalizationStatus {
    Pending,
    Executed,
    Cancelled
}

enum ProposalStatus {
    VotingDelay,
    VotingPeriod,
    VotingPeriodAccepted,
    Accepted,
    Executed,
    Rejected,
    Cancelled
}

struct Strategy {
    address addr;
    bytes params;
}

/// @notice One entry of WhitelistVotingStrategy's `params` (sx-evm `WhitelistVotingStrategy.Member`).
struct WhitelistMember {
    address addr;
    uint96 vp;
}

struct IndexedStrategy {
    uint8 index;
    bytes params;
}

struct MetaTransaction {
    address to;
    uint256 value;
    bytes data;
    Operation operation;
    uint256 salt;
}

/// @dev `IExecutionStrategy executionStrategy` is declared as `address` here; the ABI is identical.
struct Proposal {
    address author;
    uint32 startBlockNumber;
    address executionStrategy;
    uint32 minEndBlockNumber;
    uint32 maxEndBlockNumber;
    FinalizationStatus finalizationStatus;
    bytes32 executionPayloadHash;
    uint256 activeVotingStrategies;
}

/// @dev Mirrors sx-evm `UpdateSettingsCalldata`. Fields left at their NO_UPDATE sentinel
///      are ignored by `Space.updateSettings`.
struct UpdateSettingsCalldata {
    uint32 minVotingDuration;
    uint32 maxVotingDuration;
    uint32 votingDelay;
    string metadataURI;
    string daoURI;
    Strategy proposalValidationStrategy;
    string proposalValidationStrategyMetadataURI;
    address[] authenticatorsToAdd;
    address[] authenticatorsToRemove;
    Strategy[] votingStrategiesToAdd;
    string[] votingStrategyMetadataURIsToAdd;
    uint8[] votingStrategiesToRemove;
}

struct InitializeCalldata {
    address owner;
    uint32 votingDelay;
    uint32 minVotingDuration;
    uint32 maxVotingDuration;
    Strategy proposalValidationStrategy;
    string proposalValidationStrategyMetadataURI;
    string daoURI;
    string metadataURI;
    Strategy[] votingStrategies;
    string[] votingStrategyMetadataURIs;
    address[] authenticators;
}

interface IProxyFactory {
    event ProxyDeployed(address implementation, address proxy);

    function deployProxy(address implementation, bytes memory initializer, uint256 saltNonce) external;

    function predictProxyAddress(address implementation, bytes32 salt) external view returns (address);
}

interface ISpace {
    function initialize(InitializeCalldata calldata input) external;

    function propose(
        address author,
        string calldata metadataURI,
        Strategy calldata executionStrategy,
        bytes calldata userProposalValidationParams
    ) external;

    function vote(
        address voter,
        uint256 proposalId,
        Choice choice,
        IndexedStrategy[] calldata userVotingStrategies,
        string calldata metadataURI
    ) external;

    function execute(uint256 proposalId, bytes calldata executionPayload) external;

    /// @notice Controller-only. The Security Council's veto: a Pending proposal can be
    ///         cancelled at any point before it executes.
    function cancel(uint256 proposalId) external;

    function updateSettings(UpdateSettingsCalldata calldata input) external;

    /// @notice Controller-only. Used to hand the space from the deploying wallet to the
    ///         Security Council multisig.
    function transferOwnership(address newOwner) external;

    // --- state -----------------------------------------------------------
    function owner() external view returns (address);

    function daoURI() external view returns (string memory);

    function votingDelay() external view returns (uint32);

    function minVotingDuration() external view returns (uint32);

    function maxVotingDuration() external view returns (uint32);

    function nextProposalId() external view returns (uint256);

    function nextVotingStrategyIndex() external view returns (uint8);

    function activeVotingStrategies() external view returns (uint256);

    function votingStrategies(uint8 index) external view returns (address addr, bytes memory params);

    function proposalValidationStrategy() external view returns (address addr, bytes memory params);

    function authenticators(address auth) external view returns (uint256);

    function votePower(uint256 proposalId, Choice choice) external view returns (uint256);

    function getProposalStatus(uint256 proposalId) external view returns (ProposalStatus);

    function proposals(uint256 proposalId)
        external
        view
        returns (
            address author,
            uint32 startBlockNumber,
            address executionStrategy,
            uint32 minEndBlockNumber,
            uint32 maxEndBlockNumber,
            FinalizationStatus finalizationStatus,
            bytes32 executionPayloadHash,
            uint256 activeVotingStrategies
        );
}

/// @notice sx-evm AvatarExecutionStrategy (+ SimpleQuorumExecutionStrategy + SpaceManager).
interface IAvatarExecutionStrategy {
    function setUp(bytes memory initParams) external;

    function getStrategyType() external view returns (string memory);

    function target() external view returns (address);

    function owner() external view returns (address);

    function quorum() external view returns (uint256);

    function isSpaceEnabled(address space) external view returns (uint256);

    function enableSpace(address space) external;

    function disableSpace(address space) external;

    function setQuorum(uint256 newQuorum) external;

    function setTarget(address newTarget) external;

    /// @dev Guarded by `onlySpace`: only a whitelisted space can drive the avatar.
    function execute(
        uint256 proposalId,
        Proposal memory proposal,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        bytes memory payload
    ) external;
}

interface IAuthenticator {
    function authenticate(address target, bytes4 functionSelector, bytes calldata data) external;
}

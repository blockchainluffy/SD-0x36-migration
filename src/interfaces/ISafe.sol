// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Operation } from "./ISnapshotX.sol";

/// @notice The slice of Safe v1.3.0 the migration uses.
interface ISafe {
    // --- module manager --------------------------------------------------
    function enableModule(address module) external;

    function disableModule(address prevModule, address module) external;

    function isModuleEnabled(address module) external view returns (bool);

    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);

    function execTransactionFromModule(address to, uint256 value, bytes memory data, Operation operation)
        external
        returns (bool success);

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, Operation operation)
        external
        returns (bool success, bytes memory returnData);

    // --- owner manager ---------------------------------------------------
    function swapOwner(address prevOwner, address oldOwner, address newOwner) external;

    function addOwnerWithThreshold(address owner, uint256 threshold) external;

    function removeOwner(address prevOwner, address owner, uint256 threshold) external;

    function getOwners() external view returns (address[] memory);

    function isOwner(address owner) external view returns (bool);

    function getThreshold() external view returns (uint256);

    function setGuard(address guard) external;

    // --- misc ------------------------------------------------------------
    function VERSION() external view returns (string memory);

    function nonce() external view returns (uint256);
}

/// @notice SHU: ERC20 + ERC20Votes.
interface IShu {
    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function delegate(address delegatee) external;

    function delegates(address account) external view returns (address);

    function getVotes(address account) external view returns (uint256);

    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);

    function CLOCK_MODE() external view returns (string memory);
}

/// @notice Read-only slice of the Decent (Azorius) module, used for reporting only.
interface IAzorius {
    function avatar() external view returns (address);

    function target() external view returns (address);

    function owner() external view returns (address);

    function timelockPeriod() external view returns (uint32);

    function executionPeriod() external view returns (uint32);

    function totalProposalCount() external view returns (uint256);

    function getGuard() external view returns (address);

    function getStrategies(address start, uint256 count)
        external
        view
        returns (address[] memory strategies, address next);

    /// @notice Azorius's own proposal-execution entrypoint. Ultimately calls the Safe via
    ///         `execTransactionFromModule`, so it is dead once the module is disabled.
    function executeProposal(
        uint32 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory data,
        uint8[] memory operations
    ) external;
}

/// @notice An Azorius linear-ERC20 voting strategy. `getWhitelistedHatIds` and
///         `hatsContract` only exist on the `…WithHatsProposalCreation` variant.
interface IAzoriusStrategy {
    function governanceToken() external view returns (address);

    function votingPeriod() external view returns (uint32);

    function requiredProposerWeight() external view returns (uint256);

    function quorumNumerator() external view returns (uint256);

    function isProposer(address account) external view returns (bool);

    function getWhitelistedHatIds() external view returns (uint256[] memory);

    function hatsContract() external view returns (address);
}

/// @notice The slice of Hats Protocol v1 the migration needs.
interface IHats {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);

    function viewHat(uint256 hatId)
        external
        view
        returns (
            string memory details,
            uint32 maxSupply,
            uint32 supply,
            address eligibility,
            address toggle,
            string memory imageURI,
            uint16 lastHatId,
            bool mutable_,
            bool active
        );
}

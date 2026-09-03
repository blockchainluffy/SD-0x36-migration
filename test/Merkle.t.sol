// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Merkle } from "src/Merkle.sol";
import { Cfg } from "src/Config.sol";

/// @notice Locks the OZ StandardMerkleTree reconstruction to the on-chain root of the
///         real Shutter DAO 0x36 space (0x594E…B769), verified independently with cast.
contract MerkleTest is Test {
    bytes32 constant REAL_ROOT = 0x3be9b6c829fc4038f587288180e7e082aed3260994c9b7458057c13b6693cf01;

    function test_root_matches_real_space() public pure {
        address[9] memory a = Cfg.whitelistedProposers();
        bytes32[] memory leaves = new bytes32[](a.length);
        for (uint256 i; i < a.length; i++) {
            leaves[i] = Merkle.whitelistLeaf(a[i], Cfg.WHITELIST_VP);
        }
        assertEq(Merkle.root(leaves), REAL_ROOT, "reconstructed root != on-chain root");
    }

    function test_proof_verifies_for_every_member() public pure {
        address[9] memory a = Cfg.whitelistedProposers();
        bytes32[] memory leaves = new bytes32[](a.length);
        for (uint256 i; i < a.length; i++) {
            leaves[i] = Merkle.whitelistLeaf(a[i], Cfg.WHITELIST_VP);
        }
        bytes32 root = Merkle.root(leaves);
        for (uint256 i; i < a.length; i++) {
            bytes32[] memory proof = Merkle.proof(leaves, leaves[i]);
            assertTrue(_verify(proof, root, leaves[i]), "proof failed");
        }
    }

    // OZ MerkleProof.verify (sorted-pair).
    function _verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i; i < proof.length; i++) {
            h = h <= proof[i] ? keccak256(abi.encodePacked(h, proof[i])) : keccak256(abi.encodePacked(proof[i], h));
        }
        return h == root;
    }
}

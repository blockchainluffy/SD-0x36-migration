// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Merkle
/// @notice Rebuilds an OpenZeppelin `StandardMerkleTree` in-memory: root computation
///         and proof extraction, matching the OpenZeppelin merkle-tree JS library exactly (the library
///         snapshot.box uses to build whitelist trees).
/// @dev    Leaf hashing (double keccak of the abi-encoded value) is the caller's job —
///         see `whitelistLeaf`. This library takes pre-hashed leaves.
///
///         OZ specifics reproduced here:
///           * leaves are sorted ascending by hash before the tree is built;
///           * internal nodes use commutative (sorted-pair) hashing;
///           * leaves are placed in reverse order at the tail of a (2n-1)-node array.
library Merkle {
    /// @notice Leaf hash for a `MerkleWhitelistVotingStrategy.Member(address,uint96)`.
    /// @dev    Mirrors the strategy: keccak256(bytes.concat(keccak256(abi.encode(addr, vp)))).
    function whitelistLeaf(address addr, uint96 vp) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(addr, vp))));
    }

    /// @notice Sorts `leaves` ascending in place (selection sort; N is tiny).
    function sortAscending(bytes32[] memory leaves) internal pure {
        for (uint256 i = 0; i < leaves.length; i++) {
            uint256 min = i;
            for (uint256 j = i + 1; j < leaves.length; j++) {
                if (leaves[j] < leaves[min]) min = j;
            }
            if (min != i) {
                (leaves[i], leaves[min]) = (leaves[min], leaves[i]);
            }
        }
    }

    /// @dev The full node array of the tree (root at index 0), from ALREADY-SORTED leaves.
    function _build(bytes32[] memory sortedLeaves) private pure returns (bytes32[] memory tree) {
        uint256 n = sortedLeaves.length;
        require(n > 0, "empty tree");
        tree = new bytes32[](2 * n - 1);
        for (uint256 i = 0; i < n; i++) {
            tree[tree.length - 1 - i] = sortedLeaves[i];
        }
        for (uint256 i = tree.length - 1 - n;; i--) {
            tree[i] = _hashPair(tree[2 * i + 1], tree[2 * i + 2]);
            if (i == 0) break;
        }
    }

    /// @notice Root of the OZ StandardMerkleTree over `leaves` (any order; sorted internally).
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 1) return leaves[0];
        bytes32[] memory sorted = _copy(leaves);
        sortAscending(sorted);
        return _build(sorted)[0];
    }

    /// @notice The proof for `leaf`, in the format `MerkleProof.verify` expects.
    /// @dev    Reverts if `leaf` is not among `leaves`.
    function proof(bytes32[] memory leaves, bytes32 leaf) internal pure returns (bytes32[] memory) {
        bytes32[] memory sorted = _copy(leaves);
        sortAscending(sorted);
        bytes32[] memory tree = _build(sorted);

        // Locate the leaf's node index in the tree (tail, reversed).
        uint256 n = sorted.length;
        uint256 nodeIndex = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            if (sorted[i] == leaf) {
                nodeIndex = tree.length - 1 - i;
                break;
            }
        }
        require(nodeIndex != type(uint256).max, "leaf not in tree");

        // Walk up to the root, collecting siblings.
        bytes32[] memory tmp = new bytes32[](tree.length);
        uint256 count;
        while (nodeIndex > 0) {
            uint256 sibling = nodeIndex % 2 == 1 ? nodeIndex + 1 : nodeIndex - 1;
            tmp[count++] = tree[sibling];
            nodeIndex = (nodeIndex - 1) / 2;
        }
        bytes32[] memory out = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = tmp[i];
        }
        return out;
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _copy(bytes32[] memory a) private pure returns (bytes32[] memory b) {
        b = new bytes32[](a.length);
        for (uint256 i = 0; i < a.length; i++) {
            b[i] = a[i];
        }
    }
}

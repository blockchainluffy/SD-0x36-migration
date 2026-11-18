// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";

/// @title CheckSepoliaToken: read a Sepolia ERC20's decimals and one address's balance.
///
/// @notice Read-only. Used to prepare the testnet rehearsal of the new proposal rules on
///         testnet.snapshot.box. Prints the token's name, symbol, decimals and total
///         supply, then the balance of ACCOUNT, both raw and in whole tokens.
///
///         It also reports whether the token supports ERC20Votes (`getVotes`,
///         `delegates`). The Snapshot X "ERC-20 Votes" voting strategy reads delegated
///         votes, so a token without them gives every holder zero voting power there.
///
///         Usage:
///           ACCOUNT=0x… forge script script/CheckSepoliaToken.s.sol
///           ./sim.sh token-balance --account 0x… [--token 0x…]
///
///         Env: ACCOUNT (required), TOKEN (default: the dummy token below),
///              SEPOLIA_RPC_URL (default: a public Sepolia node).
contract CheckSepoliaToken is Script {
    /// @dev The dummy ERC20 deployed on Sepolia for the testnet rehearsal.
    address internal constant DEFAULT_TOKEN = 0xa3098a53d336dD6685A23F77815B6a3Cde18E281;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    function run() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com"));
        address token = vm.envOr("TOKEN", DEFAULT_TOKEN);
        address account = vm.envAddress("ACCOUNT");

        vm.createSelectFork(rpc);
        require(block.chainid == SEPOLIA_CHAIN_ID, "RPC is not Sepolia");
        require(token.code.length > 0, "TOKEN has no code on Sepolia");

        console.log("");
        console.log("== token on Sepolia, block:", block.number);
        console.log("   address:     ", token);
        console.log("   name:        ", _string(token, "name()"));
        console.log("   symbol:      ", _string(token, "symbol()"));

        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && ret.length >= 32, "token has no decimals()");
        uint8 decimals = abi.decode(ret, (uint8));
        console.log("   decimals:    ", decimals);

        uint256 supply = _uint(token, abi.encodeWithSignature("totalSupply()"));
        console.log("   total supply:", _format(supply, decimals));

        uint256 balance = _uint(token, abi.encodeWithSignature("balanceOf(address)", account));
        console.log("");
        console.log("== balance");
        console.log("   account:     ", account);
        console.log("   raw:         ", balance);
        console.log("   tokens:      ", _format(balance, decimals));

        console.log("");
        console.log("== ERC20Votes support (needed by the Snapshot X 'ERC-20 Votes' strategy)");
        (bool hasVotes, bytes memory votes) = token.staticcall(abi.encodeWithSignature("getVotes(address)", account));
        (bool hasDelegates, bytes memory delegatee) =
            token.staticcall(abi.encodeWithSignature("delegates(address)", account));
        if (hasVotes && hasDelegates) {
            console.log("   supported:    yes");
            console.log("   delegated to: ", abi.decode(delegatee, (address)));
            console.log("   votes:        ", _format(abi.decode(votes, (uint256)), decimals));
        } else {
            console.log("   supported:    NO - getVotes/delegates revert. This is a plain ERC20,");
            console.log("   so the 'ERC-20 Votes' strategy would give every holder 0 voting power.");
        }
    }

    function _uint(address token, bytes memory data) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(data);
        require(ok && ret.length >= 32, "token call failed");
        return abi.decode(ret, (uint256));
    }

    /// @dev name() and symbol() are optional in ERC20, so a missing one prints "(none)".
    function _string(address token, string memory sig) internal view returns (string memory) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length < 64) return "(none)";
        return abi.decode(ret, (string));
    }

    /// @dev `amount` in whole tokens, e.g. 1234500 with 6 decimals -> "1.2345".
    function _format(uint256 amount, uint8 decimals) internal pure returns (string memory) {
        uint256 unit = 10 ** uint256(decimals);
        string memory whole = vm.toString(amount / unit);
        uint256 frac = amount % unit;
        if (frac == 0) return whole;

        bytes memory digits = bytes(vm.toString(frac));
        bytes memory padded = new bytes(decimals);
        uint256 pad = decimals - digits.length;
        for (uint256 i; i < decimals; i++) {
            padded[i] = i < pad ? bytes1("0") : digits[i - pad];
        }
        uint256 end = decimals;
        while (end > 0 && padded[end - 1] == "0") end--;
        bytes memory trimmed = new bytes(end);
        for (uint256 i; i < end; i++) {
            trimmed[i] = padded[i];
        }
        return string.concat(whole, ".", string(trimmed));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { Step1_CreateSpace } from "./Step1_CreateSpace.s.sol";
import { Cfg } from "src/Config.sol";
import { Merkle } from "src/Merkle.sol";
import { ISafe } from "src/interfaces/ISafe.sol";
import {
    IAvatarExecutionStrategy,
    IProxyFactory,
    ISpace,
    Strategy,
    WhitelistMember
} from "src/interfaces/ISnapshotX.sol";

/// @title Step 2 — verify the space, and pre-flight the Step 3 transactions
/// @notice Reads every parameter back off the freshly created Space proxy and
///         asserts it against the migration parameters, then prints and decodes
///         the exact calldata Step 3 will execute so it can be eyeballed before
///         it is ever put in front of a real vote.
///
/// Run:  forge script script/Step2_VerifySpace.s.sol -vv
contract Step2_VerifySpace is Step1_CreateSpace {
    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _step2();
        _report("Step 2");
        _writeState("2");
    }

    function _step2() internal {
        _banner("STEP 2  |  Verify the Snapshot X space parameters");

        ISpace s = ISpace(space);

        _section("identity");
        _ok("space:", space);
        if (!attached) {
            check("space address == predicted", space, _predict(Cfg.SPACE_IMPL, P.spaceDeployer, P.spaceSaltNonce));
        }
        checkTrue("space has code", space.code.length > 0);

        _section("controller & timing");
        if (attached) {
            _ok("current controller:", s.owner());
            checkTrue("space has a controller", s.owner() != address(0));
        } else {
            check("owner at creation (dev wallet)", s.owner(), P.spaceControllerInitial);
        }
        check("votingDelay (blocks)", s.votingDelay(), P.votingDelay);
        check("minVotingDuration (blocks)", s.minVotingDuration(), P.minVotingDuration);
        check("maxVotingDuration (blocks)", s.maxVotingDuration(), P.maxVotingDuration);
        check("daoURI", s.daoURI(), P.daoURI);
        if (attached) {
            // A live space has already had proposals; only a fresh one starts at 1.
            checkTrue("nextProposalId >= 1 (space initialised)", s.nextProposalId() >= 1);
        } else {
            check("nextProposalId", s.nextProposalId(), 1);
        }

        _section("voting strategies");
        check("registered strategy count", s.nextVotingStrategyIndex(), 1);
        check("activeVotingStrategies bitmap", s.activeVotingStrategies(), 1);
        (address vsAddr, bytes memory vsParams) = s.votingStrategies(0);
        check("strategy[0] address", vsAddr, Cfg.OZ_VOTES_VOTING_STRATEGY);
        checkBytes("strategy[0] params (SHU)", vsParams, abi.encodePacked(Cfg.SHU));
        check("strategy[0] token decoded", address(bytes20(vsParams)), Cfg.SHU);

        _section("proposal validation");
        (address pvAddr, bytes memory pvParams) = s.proposalValidationStrategy();
        check("validation strategy", pvAddr, Cfg.PROPOSITION_POWER_VALIDATION);
        (uint256 threshold, Strategy[] memory allowed) = abi.decode(pvParams, (uint256, Strategy[]));
        check("proposal threshold (SHU wei)", threshold, P.proposalThreshold);
        check("allowed strategy count", allowed.length, 2);
        check("allowed[0] = SHU voting power", allowed[0].addr, Cfg.OZ_VOTES_VOTING_STRATEGY);
        check("allowed[0] token", address(bytes20(allowed[0].params)), Cfg.SHU);

        _verifyWhitelist(allowed[1]);

        _section("delegation (doc: DELEGATIONS)");
        // Delegation type is ERC-20 Votes, so delegation is native to the token and there is
        // no separate on-chain delegation object. The doc's "Delegation contract address" is
        // therefore the SHU token, and it is the SAME address the voting strategy reads.
        check("doc delegation contract == SHU", Cfg.DELEGATION_CONTRACT, Cfg.SHU);
        check("delegation contract == voting-strategy token", Cfg.DELEGATION_CONTRACT, address(bytes20(vsParams)));
        // It genuinely supports ERC20Votes delegation (delegate / delegates / getPastVotes),
        // which is what OZVotesVotingStrategy.getVotingPower calls.
        checkTrue("delegation contract exposes ERC20Votes", Cfg.DELEGATION_CONTRACT.code.length > 0);
        check("delegates() reads back", shu.delegates(address(0)), address(0));
        check("clock is blocknumber (matches Snapshot X)", shu.CLOCK_MODE(), "mode=blocknumber&from=default");
        console.log("   NB: delegation API name / URL / type are off-chain snapshot.box metadata (no on-chain field)");

        _section("authenticators");
        check("EthTxAuthenticator enabled", s.authenticators(Cfg.ETH_TX_AUTHENTICATOR), 1);
        check("EthSigAuthenticator enabled", s.authenticators(Cfg.ETH_SIG_AUTHENTICATOR), 1);
        check("VanillaAuthenticator NOT enabled", s.authenticators(0xb9BE0a0093933968E3B4c4fC5d939B6c1Fe45142), 0);
        check("random address NOT an authenticator", s.authenticators(address(0xdead)), 0);

        _section(attached ? "current Safe state" : "treasury untouched by Step 1");
        _logOwners("owners");
        _logModules("modules");
        check("Azorius still enabled", safe.isModuleEnabled(Cfg.AZORIUS), true);
        if (attached) {
            _ok("strategy is a Safe module:", safe.isModuleEnabled(strategy) ? "yes" : "not yet");
        } else {
            check("Azorius still the only module", _modules().length, 1);
            check("strategy not yet a module", safe.isModuleEnabled(strategy), false);
        }

        {
            _section("execution strategy (deployed alongside the space)");
            IAvatarExecutionStrategy st = IAvatarExecutionStrategy(strategy);
            check("getStrategyType()", st.getStrategyType(), Cfg.AVATAR_STRATEGY_TYPE);
            check("target()  (doc: Safe address)", st.target(), Cfg.SAFE);
            check("owner()   (doc: Controller address)", st.owner(), Cfg.SAFE);
            checkQuorum("quorum()  (doc: 30,000,000 SHU)", st.quorum(), P.quorum);
            check("isSpaceEnabled(space)", st.isSpaceEnabled(space), 1);
        }

        _preflightStep3();
    }

    /// @dev Proposal-validation strategy 2 is a whitelist. Two encodings exist and both are
    ///      verified against the same nine doc addresses at 10M SHU each:
    ///        * plain  WhitelistVotingStrategy  — params = abi.encode(Member[]) (member array)
    ///        * merkle MerkleWhitelistVotingStrategy — params = abi.encode(bytes32 root)
    ///      The snapshot.box UI deploys the MERKLE variant, so a real space lands here.
    function _verifyWhitelist(Strategy memory wl) internal {
        _section("proposal validation strategy 2: whitelist");
        address[9] memory expected = Cfg.whitelistedProposers();

        if (wl.addr == Cfg.MERKLE_WHITELIST_VOTING_STRATEGY) {
            check("allowed[1] = merkle whitelist (UI default)", wl.addr, Cfg.MERKLE_WHITELIST_VOTING_STRATEGY);
            bytes32 onchainRoot = abi.decode(wl.params, (bytes32));
            bytes32 expectedRoot = _docWhitelistRoot();
            check("merkle root commits to the 9 doc addresses @ 10M each", onchainRoot, expectedRoot);
        } else if (wl.addr == Cfg.WHITELIST_VOTING_STRATEGY) {
            check("allowed[1] = plain whitelist", wl.addr, Cfg.WHITELIST_VOTING_STRATEGY);
            WhitelistMember[] memory members = abi.decode(wl.params, (WhitelistMember[]));
            check("whitelist size", members.length, expected.length);
            for (uint256 i; i < expected.length; i++) {
                check(string.concat("  member[", vm.toString(i), "]"), members[i].addr, expected[i]);
                check(string.concat("  member[", vm.toString(i), "] vp"), members[i].vp, Cfg.WHITELIST_VP);
            }
        } else {
            // Neither known whitelist strategy — fail loudly with the address seen.
            check("allowed[1] is a known whitelist strategy", wl.addr, Cfg.MERKLE_WHITELIST_VOTING_STRATEGY);
        }
    }

    // =====================================================================
    // Pre-flight: exactly what Step 3 (Decent "Vote 1") will execute
    // =====================================================================

    function _preflightStep3() internal {
        _banner("STEP 2b  |  Pre-flight of the module-enable vote (Decent Vote 1)");

        bytes memory deployCd = _deployStrategyCalldata(space);
        bytes memory enableCd = _enableModuleCalldata(strategy);

        // Already executed as part of the space create. Decoded here so the strategy's
        // setUp parameters can be checked against the doc before the module vote.
        _section("ProxyFactory.deployProxy - already done during space creation");
        _ok("to:", Cfg.PROXY_FACTORY);
        _ok("value:", uint256(0));
        _ok("operation:", "0 (CALL)");
        console.log("   selector:", vm.toString(abi.encodePacked(IProxyFactory.deployProxy.selector)));
        console.log("   data:", vm.toString(deployCd));

        // Decode it back out to prove the bytes say what we think they say.
        (address implDecoded, bytes memory initializerDecoded, uint256 nonceDecoded) =
            abi.decode(_stripSelector(deployCd), (address, bytes, uint256));
        check("  decoded implementation", implDecoded, Cfg.AVATAR_EXECUTION_STRATEGY_IMPL);
        check("  decoded saltNonce", nonceDecoded, P.strategySaltNonce);

        bytes memory initParams = abi.decode(_stripSelector(initializerDecoded), (bytes));
        (address owner_, address target_, address[] memory spaces_, uint256 quorum_) =
            abi.decode(initParams, (address, address, address[], uint256));
        check("  setUp.owner  (Safe)", owner_, Cfg.SAFE);
        check("  setUp.target (Safe)", target_, Cfg.SAFE);
        check("  setUp.spaces length", spaces_.length, 1);
        check("  setUp.spaces[0] == space", spaces_[0], space);
        check("  setUp.quorum", quorum_, P.quorum);

        _section("the only action of Decent Vote 1: Safe.enableModule");
        _ok("to:", Cfg.SAFE);
        _ok("value:", uint256(0));
        _ok("operation:", "0 (CALL)");
        console.log("   selector:", vm.toString(abi.encodePacked(ISafe.enableModule.selector)));
        console.log("   data:", vm.toString(enableCd));
        check("  enableModule selector", uint256(uint32(ISafe.enableModule.selector)), uint256(0x610b5925));
        address moduleDecoded = abi.decode(_stripSelector(enableCd), (address));
        check("  decoded module == the strategy", moduleDecoded, strategy);

        _section("determinism");
        if (attached) {
            _ok("attached deployment - salt inputs not reproducible here", strategy);
        } else {
            check(
                "strategy address reproducible",
                strategy,
                _predict(Cfg.AVATAR_EXECUTION_STRATEGY_IMPL, P.spaceDeployer, P.strategySaltNonce)
            );
            checkTrue(
                "a different deployer yields a different address",
                _predict(Cfg.AVATAR_EXECUTION_STRATEGY_IMPL, Cfg.SAFE, P.strategySaltNonce)
                    != _predict(Cfg.AVATAR_EXECUTION_STRATEGY_IMPL, P.spaceDeployer, P.strategySaltNonce)
            );
            checkTrue(
                "a different saltNonce yields a different address",
                strategy != _predict(Cfg.AVATAR_EXECUTION_STRATEGY_IMPL, Cfg.SAFE, P.strategySaltNonce + 1)
            );
        }
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory out) {
        require(data.length >= 4, "calldata too short");
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }
}

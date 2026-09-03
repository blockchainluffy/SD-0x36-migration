// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { SimBase } from "./SimBase.s.sol";
import { Cfg } from "src/Config.sol";
import { IAzorius, IAzoriusStrategy, IHats } from "src/interfaces/ISafe.sol";
import { IAvatarExecutionStrategy, ISpace, InitializeCalldata } from "src/interfaces/ISnapshotX.sol";

/// @title Step 1 — create the Snapshot X space
/// @notice Forks Ethereum mainnet, records the live Shutter DAO 0x36 governance
///         baseline — including how Decent gates proposal creation today
///         (MIGRATION.md sec 1.5) — then deploys the Snapshot X `Space` proxy AND
///         its `AvatarExecutionStrategy` proxy through the sx-evm ProxyFactory.
///
///         That pair is the on-chain half of one snapshot.box "Create": the doc's
///         *Sign Transactions* section has the creating wallet sign both. The
///         strategy is never deployed later (MIGRATION.md sec 3.5).
///
/// Run:  forge script script/Step1_CreateSpace.s.sol -vv
contract Step1_CreateSpace is SimBase {
    function run() public virtual {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _report("Step 1");
        _writeState("1");
    }

    // =====================================================================
    // Fork baseline — assert the DAO looks like MIGRATION.md sec 1 says it does
    // =====================================================================

    function _baseline() internal {
        _banner("BASELINE  |  Shutter DAO 0x36 governance, as forked");
        _ok("fork block:", block.number);
        _ok("chain id:", block.chainid);

        _section("DAO Safe");
        _ok("safe:", Cfg.SAFE);
        check("safe version", safe.VERSION(), "1.3.0");
        check("safe threshold", safe.getThreshold(), 1);

        _logOwners("owners");
        address[] memory owners = safe.getOwners();
        check("owner count", owners.length, 1);
        check("sole owner is Azorius", owners[0], Cfg.AZORIUS);

        _logModules("modules");
        address[] memory mods = _modules();
        if (attached) {
            // A real deployment may already be part-way through the migration.
            check("Azorius still enabled", safe.isModuleEnabled(Cfg.AZORIUS), true);
        } else {
            check("module count", mods.length, 1);
            check("sole module is Azorius", mods[0], Cfg.AZORIUS);
        }

        // No transaction guard on the Safe (storage slot is zero).
        address guard = address(uint160(uint256(vm.load(Cfg.SAFE, Cfg.GUARD_SLOT))));
        check("safe tx guard", guard, address(0));

        _section("Decent / Azorius module (to be removed in Step 5)");
        IAzorius azorius = IAzorius(Cfg.AZORIUS);
        _ok("azorius:", Cfg.AZORIUS);
        check("azorius avatar", azorius.avatar(), Cfg.SAFE);
        check("azorius target", azorius.target(), Cfg.SAFE);
        _ok("timelock period (blocks):", azorius.timelockPeriod());
        _ok("execution period (blocks):", azorius.executionPeriod());
        _ok("proposals so far:", azorius.totalProposalCount());
        _ok("freeze guard:", azorius.getGuard());

        _decentProposerGating();

        _section("SHU (voting token)");
        check("symbol", shu.symbol(), "SHU");
        check("decimals", shu.decimals(), 18);
        check("clock mode", shu.CLOCK_MODE(), "mode=blocknumber&from=default");
        _ok("treasury SHU balance:", shu.balanceOf(Cfg.SAFE));

        _section("Snapshot X deployment (snapshot-labs/sx-evm, ethereum.json)");
        checkTrue("ProxyFactory has code", Cfg.PROXY_FACTORY.code.length > 0);
        checkTrue("Space implementation has code", Cfg.SPACE_IMPL.code.length > 0);
        checkTrue("AvatarExecutionStrategy impl has code", Cfg.AVATAR_EXECUTION_STRATEGY_IMPL.code.length > 0);
        checkTrue("OZVotesVotingStrategy has code", Cfg.OZ_VOTES_VOTING_STRATEGY.code.length > 0);
        checkTrue("EthTxAuthenticator has code", Cfg.ETH_TX_AUTHENTICATOR.code.length > 0);
        checkTrue("PropositionPower validation has code", Cfg.PROPOSITION_POWER_VALIDATION.code.length > 0);
    }

    /// @dev How Decent gates proposal creation today — and why it is NOT a Safe module.
    ///      Azorius keeps a list of *voting strategies*; each one decides for itself who
    ///      may open a proposal. One is hats-gated, one is token-gated. Neither appears
    ///      in the Safe's module list, and both stop working the moment Azorius does.
    function _decentProposerGating() internal {
        _section("Decent proposer gating (voting strategies, not Safe modules)");

        (address[] memory strategies,) = IAzorius(Cfg.AZORIUS).getStrategies(Cfg.SENTINEL, 10);
        check("Azorius strategy count", strategies.length, 2);
        check("strategy[0] (hats-gated)", strategies[0], Cfg.AZORIUS_STRATEGY_HATS);
        check("strategy[1] (token-gated)", strategies[1], Cfg.AZORIUS_STRATEGY_TOKEN);

        IAzoriusStrategy hatsStrategy = IAzoriusStrategy(Cfg.AZORIUS_STRATEGY_HATS);
        IAzoriusStrategy tokenStrategy = IAzoriusStrategy(Cfg.AZORIUS_STRATEGY_TOKEN);

        check("hats strategy: requiredProposerWeight", hatsStrategy.requiredProposerWeight(), 0);
        check("hats strategy: hatsContract", hatsStrategy.hatsContract(), Cfg.HATS_PROTOCOL);
        uint256[] memory hatIds = hatsStrategy.getWhitelistedHatIds();
        check("hats strategy: whitelisted hat count", hatIds.length, 1);
        check("hats strategy: proposer hat id", hatIds[0], Cfg.PROPOSER_HAT_ID);

        check(
            "token strategy: requiredProposerWeight (1M SHU)",
            tokenStrategy.requiredProposerWeight(),
            Cfg.DECENT_PROPOSER_THRESHOLD
        );
        checkTrue("token strategy is not hats-gated", !_hasHatsGate(Cfg.AZORIUS_STRATEGY_TOKEN));

        // The Safe wears the top hat of the tree, so the DAO admins the whole tree.
        IHats hats = IHats(Cfg.HATS_PROTOCOL);
        checkTrue("the DAO Safe wears the top hat", hats.isWearerOfHat(Cfg.SAFE, Cfg.TOP_HAT_ID));

        (,, uint32 supply,,,,,,) = hats.viewHat(Cfg.PROPOSER_HAT_ID);
        _ok("proposer hat wearers:", supply);
        check("hat supply == doc whitelist size", supply, Cfg.whitelistedProposers().length);

        // The doc's Snapshot X whitelist should reproduce today's hat wearers exactly.
        _section("doc whitelist vs current proposer-hat wearers");
        address[9] memory members = Cfg.whitelistedProposers();
        for (uint256 i; i < members.length; i++) {
            checkTrue(
                string.concat("  wears the proposer hat: ", vm.toString(members[i])),
                hats.isWearerOfHat(members[i], Cfg.PROPOSER_HAT_ID)
            );
        }
    }

    function _hasHatsGate(address strategyAddr) internal view returns (bool) {
        try IAzoriusStrategy(strategyAddr).getWhitelistedHatIds() returns (uint256[] memory ids) {
            return ids.length > 0;
        } catch {
            return false;
        }
    }

    // =====================================================================
    // Step 1
    // =====================================================================

    /// @dev Brings `space` / `strategy` into existence: adopts the attached deployment if
    ///      SNAPSHOT_X_SPACE + SNAPSHOT_X_STRATEGY were given, otherwise creates them.
    ///      Every step calls this instead of `_step1()` so that any step can be run on
    ///      its own against a real space.
    function _ensureSpace() internal {
        if (attached) {
            _adoptAttachedDeployment();
        } else {
            _step1();
        }
    }

    function _step1() internal {
        _banner("STEP 1  |  Create the Snapshot X space");

        InitializeCalldata memory init = _spaceInit();
        bytes memory initializer = abi.encodeCall(ISpace.initialize, (init));

        address predicted = _predict(Cfg.SPACE_IMPL, P.spaceDeployer, P.spaceSaltNonce);

        _section("space deployment inputs");
        _ok("factory:", Cfg.PROXY_FACTORY);
        _ok("implementation:", Cfg.SPACE_IMPL);
        _ok("deployer (signs Create):", P.spaceDeployer);
        _ok("saltNonce:", P.spaceSaltNonce);
        console.log("   salt:", vm.toString(_salt(P.spaceDeployer, P.spaceSaltNonce)));
        _ok("predicted space:", predicted);

        _section("space configuration (doc: Snapshot X Parameters)");
        _ok("controller at creation:", init.owner);
        _ok("controller after handover:", P.spaceController);
        _ok("voting delay (blocks):", init.votingDelay);
        _ok("min voting duration (blocks):", init.minVotingDuration);
        _ok("max voting duration (blocks):", init.maxVotingDuration);
        _ok("voting strategy:", init.votingStrategies[0].addr);
        _ok("  token param:", Cfg.SHU);
        _ok("validation strategy:", init.proposalValidationStrategy.addr);
        _ok("  proposal threshold:", P.proposalThreshold);
        _ok("  allowed[0] SHU voting power:", Cfg.OZ_VOTES_VOTING_STRATEGY);
        _ok("  allowed[1] whitelist (merkle):", Cfg.MERKLE_WHITELIST_VOTING_STRATEGY);
        _ok("  whitelisted proposers:", _whitelistMembers().length);
        _ok("authenticator (tx):", init.authenticators[0]);
        _ok("authenticator (sig):", init.authenticators[1]);
        _ok("metadataURI:", init.metadataURI);

        checkTrue("space not already deployed at predicted address", predicted.code.length == 0);

        // --- deploy ------------------------------------------------------
        vm.prank(P.spaceDeployer);
        factory.deployProxy(Cfg.SPACE_IMPL, initializer, P.spaceSaltNonce);

        space = predicted;
        checkTrue("space proxy deployed at predicted address", space.code.length > 0);

        _deployStrategyWithSpace();

        _section("result");
        _ok("SNAPSHOT_X_SPACE:", space);
        _ok("SNAPSHOT_X_STRATEGY:", strategy);
    }

    // =====================================================================
    // Execution strategy
    // =====================================================================

    /// @dev The execution strategy is deployed here, with the space, in the same
    ///      snapshot.box "Create" flow and signed by the same wallet — the doc's
    ///      *Sign Transactions* section: "Space contract; Execution strategy contracts —
    ///      each space has its execution strategy deployed as an individual contract."
    ///
    ///      It is never deployed later. `setUp` sets owner = target = the Safe, so the
    ///      Safe controls the strategy from the moment it exists, whoever paid the gas;
    ///      the only thing outstanding after this is `enableModule`, which is a separate
    ///      vote (Step 3) and simply uses the address recorded here.
    function _deployStrategyWithSpace() internal {
        strategy = _predict(Cfg.AVATAR_EXECUTION_STRATEGY_IMPL, P.spaceDeployer, P.strategySaltNonce);

        _section("execution strategy, deployed with the space");
        _ok("implementation:", Cfg.AVATAR_EXECUTION_STRATEGY_IMPL);
        _ok("deployer (same wallet as the space):", P.spaceDeployer);
        _ok("saltNonce:", P.strategySaltNonce);
        _ok("strategy address:", strategy);

        checkTrue("nothing deployed at that address yet", strategy.code.length == 0);

        vm.prank(P.spaceDeployer);
        factory.deployProxy(Cfg.AVATAR_EXECUTION_STRATEGY_IMPL, _strategyInitializer(space), P.strategySaltNonce);
        strategyDeployed = true;

        checkTrue("strategy proxy deployed at the predicted address", strategy.code.length > 0);
        check("owned by the Safe from the start", IAvatarExecutionStrategy(strategy).owner(), Cfg.SAFE);
        check("targets the Safe from the start", IAvatarExecutionStrategy(strategy).target(), Cfg.SAFE);
    }
}

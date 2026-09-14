// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";

import { Cfg } from "src/Config.sol";
import { Merkle } from "src/Merkle.sol";
import { ISafe, IShu } from "src/interfaces/ISafe.sol";
import {
    Choice,
    IAuthenticator,
    IAvatarExecutionStrategy,
    IProxyFactory,
    ISpace,
    IndexedStrategy,
    InitializeCalldata,
    MetaTransaction,
    Operation,
    ProposalStatus,
    Strategy,
    WhitelistMember
} from "src/interfaces/ISnapshotX.sol";

/// @title SimBase
/// @notice Shared machinery for the five migration steps: fork setup, parameter
///         loading, calldata construction, the two execution paths (Decent and
///         Snapshot X), and a pass/fail assertion tally.
/// @dev    The simulation runs entirely inside forge's in-memory mainnet fork.
///         Nothing is ever broadcast; every "transaction" is an impersonated call
///         on the fork. Each step script replays the steps before it, so any step
///         can be run on its own and still start from a coherent state.
abstract contract SimBase is Script {
    // ---------------------------------------------------------------------
    // Parameters (env-overridable — see .env.example)
    // ---------------------------------------------------------------------

    struct Params {
        string rpcUrl;
        uint256 forkBlock;
        address spaceControllerInitial; // doc: "Punit's dev address"
        address spaceController; // doc: "then replace with" the SC multisig
        address spaceDeployer;
        uint256 spaceSaltNonce;
        uint256 strategySaltNonce;
        uint32 votingDelay;
        uint32 minVotingDuration;
        uint32 maxVotingDuration;
        uint256 quorum;
        uint256 proposalThreshold;
        string metadataURI;
        string daoURI;
    }

    Params internal P;

    // ---------------------------------------------------------------------
    // Simulation state, carried across steps within one run
    // ---------------------------------------------------------------------

    /// @notice True when the operator supplied an already-deployed space + strategy
    ///         (SNAPSHOT_X_SPACE / SNAPSHOT_X_STRATEGY) instead of having Step 1 create
    ///         them. Lets any step run on its own against a real deployment.
    bool internal attached;

    address internal space; // Snapshot X Space proxy
    address internal strategy; // AvatarExecutionStrategy proxy (the new Safe module)
    bool internal strategyDeployed;
    bool internal votersProvisioned;
    uint256 internal lastProposalId;

    // ---------------------------------------------------------------------
    // Assertion tally
    // ---------------------------------------------------------------------

    uint256 internal passCount;
    uint256 internal failCount;

    ISafe internal constant safe = ISafe(Cfg.SAFE);
    IShu internal constant shu = IShu(Cfg.SHU);
    IProxyFactory internal constant factory = IProxyFactory(Cfg.PROXY_FACTORY);

    // =====================================================================
    // Setup
    // =====================================================================

    function _loadParams() internal {
        P.rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        P.forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        P.spaceDeployer = vm.envOr("SPACE_DEPLOYER", Cfg.SIM_DEV_WALLET);
        P.spaceControllerInitial = vm.envOr("SPACE_CONTROLLER_INITIAL", P.spaceDeployer);
        P.spaceController = vm.envOr("SPACE_CONTROLLER", Cfg.SECURITY_COUNCIL);
        P.spaceSaltNonce = vm.envOr("SPACE_SALT_NONCE", uint256(1));
        P.strategySaltNonce = vm.envOr("STRATEGY_SALT_NONCE", uint256(1));
        // Doc: voting delay 2D 0H 0M; min and max voting duration 3D 0H 0M.
        // Snapshot X on mainnet counts in blocks, so these are days at 12s/block.
        P.votingDelay = uint32(vm.envOr("VOTING_DELAY", uint256(14_400)));
        P.minVotingDuration = uint32(vm.envOr("MIN_VOTING_DURATION", uint256(21_600)));
        P.maxVotingDuration = uint32(vm.envOr("MAX_VOTING_DURATION", uint256(21_600)));
        // Doc: Quorum = 30000000000000000000000000 = 30,000,000 SHU.
        // (snapshot.box stores it as float64(30M * 1e18); see checkQuorum.)
        P.quorum = vm.envOr("QUORUM", uint256(30_000_000e18));
        P.proposalThreshold = vm.envOr("PROPOSAL_THRESHOLD", uint256(10_000_000e18));
        // The doc specifies no metadataURI/daoURI, and the snapshot.box UI leaves daoURI
        // empty unless you fill the ERC-4824 field. Default to empty so a real space
        // verifies with no override; set the envs if your deployment sets them.
        // (metadataURI is emitted in an event, not stored on chain, so it is not verified.)
        P.metadataURI = vm.envOr("SPACE_METADATA_URI", string(""));
        P.daoURI = vm.envOr("SPACE_DAO_URI", string(""));
    }

    /// @dev Forks mainnet unless we are already on a fork (e.g. `forge test` set one up).
    function _setUpFork() internal {
        _setUpForkNoAttach();
        _readAttachConfig();
    }

    /// @dev Fork setup without the attach-mode (space+strategy) requirement. Used by the
    ///      standalone tx builders, which need only a space or only a strategy.
    function _setUpForkNoAttach() internal {
        _loadParams();
        if (P.forkBlock == 0) {
            vm.createSelectFork(P.rpcUrl);
        } else {
            vm.createSelectFork(P.rpcUrl, P.forkBlock);
        }
        require(block.chainid == 1, "fork is not Ethereum mainnet");
    }

    // =====================================================================
    // Attach mode
    // =====================================================================

    /// @dev Set SNAPSHOT_X_SPACE and SNAPSHOT_X_STRATEGY to point every step at a space
    ///      that already exists on chain instead of one Step 1 creates. Nothing else
    ///      changes: the same checks run, against the real addresses.
    function _readAttachConfig() internal {
        address configuredSpace = vm.envOr("SNAPSHOT_X_SPACE", address(0));
        if (configuredSpace == address(0)) return;

        address configuredStrategy = vm.envOr("SNAPSHOT_X_STRATEGY", address(0));
        require(
            configuredStrategy != address(0),
            "attach: SNAPSHOT_X_SPACE is set but SNAPSHOT_X_STRATEGY is not."
            " Find it with: ./snapx-strategy.sh from-tx <SPACE_CREATE_TX>"
        );

        attached = true;
        space = configuredSpace;
        strategy = configuredStrategy;
        strategyDeployed = true;
    }

    /// @dev Adopts the attached deployment in place of Step 1's creation, and proves the
    ///      two addresses really are a Snapshot X space and its Avatar execution strategy.
    function _adoptAttachedDeployment() internal {
        _banner("ATTACH  |  using an already-deployed Snapshot X space");
        _ok("space:", space);
        _ok("strategy:", strategy);
        _ok("fork block:", block.number);

        _section("both addresses exist and are what they claim to be");
        checkTrue("space has code", space.code.length > 0);
        checkTrue("strategy has code", strategy.code.length > 0);
        check("strategy type", IAvatarExecutionStrategy(strategy).getStrategyType(), Cfg.AVATAR_STRATEGY_TYPE);
        check("strategy whitelists this space", IAvatarExecutionStrategy(strategy).isSpaceEnabled(space), 1);
        _ok("space controller now:", ISpace(space).owner());
        _ok("strategy is a Safe module:", safe.isModuleEnabled(strategy) ? "yes" : "not yet");

        console.log("");
        console.log("   Step 1's creation is skipped; every later step runs against these addresses.");
    }

    // =====================================================================
    // Output helpers
    // =====================================================================

    function _banner(string memory title) internal pure {
        console.log("");
        console.log("===========================================================");
        console.log(title);
        console.log("===========================================================");
    }

    function _section(string memory title) internal pure {
        console.log("");
        console.log(string.concat("-- ", title));
    }

    function _ok(string memory label, address value) internal pure {
        console.log(string.concat("   ", label), value);
    }

    function _ok(string memory label, uint256 value) internal pure {
        console.log(string.concat("   ", label), value);
    }

    function _ok(string memory label, string memory value) internal pure {
        console.log(string.concat("   ", label), value);
    }

    // =====================================================================
    // Assertions (tallied, reported at the end of every step)
    // =====================================================================

    function _pass(string memory label, string memory shown) private {
        passCount++;
        console.log(string.concat("   [PASS] ", label, " = ", shown));
    }

    function _failed(string memory label, string memory got, string memory want) private {
        failCount++;
        console.log(string.concat("   [FAIL] ", label, " = ", got, "   expected: ", want));
    }

    function check(string memory label, address got, address want) internal {
        if (got == want) _pass(label, vm.toString(got));
        else _failed(label, vm.toString(got), vm.toString(want));
    }

    function check(string memory label, uint256 got, uint256 want) internal {
        if (got == want) _pass(label, vm.toString(got));
        else _failed(label, vm.toString(got), vm.toString(want));
    }

    function check(string memory label, bool got, bool want) internal {
        if (got == want) _pass(label, got ? "true" : "false");
        else _failed(label, got ? "true" : "false", want ? "true" : "false");
    }

    function check(string memory label, string memory got, string memory want) internal {
        if (keccak256(bytes(got)) == keccak256(bytes(want))) _pass(label, got);
        else _failed(label, got, want);
    }

    function check(string memory label, bytes32 got, bytes32 want) internal {
        if (got == want) _pass(label, vm.toString(got));
        else _failed(label, vm.toString(got), vm.toString(want));
    }

    /// @notice Quorum equality that tolerates snapshot.box's float64 storage rounding.
    /// @dev    The UI computes quorum as `Number(human) * 1e18` in JavaScript, so the value
    ///         stored on chain is the float64 rounding of the intended integer — off by at
    ///         most one float64 ULP at that magnitude (e.g. 30,000,000 SHU is stored as
    ///         ...570425344, ~5.7e-10 SHU high). This accepts that dust and NOTHING more:
    ///         one ULP here is ~4.3e9 wei, while the smallest real quorum change is 1 SHU
    ///         (1e18 wei), so any genuine difference still fails.
    function checkQuorum(string memory label, uint256 got, uint256 want) internal {
        uint256 diff = got > want ? got - want : want - got;
        uint256 ulp = _float64Ulp(want);
        if (got == want || diff <= ulp) {
            _pass(label, string.concat(vm.toString(got), got == want ? "" : " (snapshot.box float rounding)"));
        } else {
            _failed(label, vm.toString(got), vm.toString(want));
        }
    }

    /// @dev Spacing of float64 values at magnitude `v`: 2^(floor(log2 v) - 52), min 1.
    function _float64Ulp(uint256 v) private pure returns (uint256) {
        if (v == 0) return 1;
        uint256 msb;
        uint256 x = v;
        while (x > 1) {
            x >>= 1;
            msb++;
        }
        return msb > 52 ? (uint256(1) << (msb - 52)) : 1;
    }

    function checkBytes(string memory label, bytes memory got, bytes memory want) internal {
        if (keccak256(got) == keccak256(want)) _pass(label, vm.toString(got));
        else _failed(label, vm.toString(got), vm.toString(want));
    }

    function checkTrue(string memory label, bool condition) internal {
        if (condition) _pass(label, "true");
        else _failed(label, "false", "true");
    }

    /// @dev Prints the tally and reverts the whole run if anything failed.
    function _report(string memory stepName) internal view {
        console.log("");
        console.log(string.concat("   ", stepName, " checks: passed / failed"), passCount, failCount);
        require(failCount == 0, string.concat(stepName, ": one or more checks FAILED"));
    }

    // =====================================================================
    // Address prediction
    // =====================================================================

    function _salt(address deployer, uint256 saltNonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, saltNonce));
    }

    function _predict(address implementation, address deployer, uint256 saltNonce) internal view returns (address) {
        return factory.predictProxyAddress(implementation, _salt(deployer, saltNonce));
    }

    // =====================================================================
    // Calldata builders — these are the exact bytes that go on-chain
    // =====================================================================

    /// @notice The single voting strategy: SHU balances via OZ Votes delegation.
    function _votingStrategies() internal pure returns (Strategy[] memory out) {
        out = new Strategy[](1);
        // OZVotesVotingStrategy reads `address(bytes20(params))`, so params is the
        // raw 20-byte token address, not an abi.encode'd word.
        out[0] = Strategy({ addr: Cfg.OZ_VOTES_VOTING_STRATEGY, params: abi.encodePacked(Cfg.SHU) });
    }

    /// @notice The nine whitelisted proposers, encoded as WhitelistVotingStrategy `params`.
    /// @dev    Order is significant: a whitelisted author proves membership by passing their
    ///         index into this array as the strategy's `userParams`.
    function _whitelistMembers() internal pure returns (WhitelistMember[] memory out) {
        address[9] memory addrs = Cfg.whitelistedProposers();
        out = new WhitelistMember[](addrs.length);
        for (uint256 i; i < addrs.length; i++) {
            out[i] = WhitelistMember({ addr: addrs[i], vp: Cfg.WHITELIST_VP });
        }
    }

    /// @notice The nine members as leaves of an OZ StandardMerkleTree.
    function _whitelistLeaves() internal pure returns (bytes32[] memory leaves) {
        address[9] memory a = Cfg.whitelistedProposers();
        leaves = new bytes32[](a.length);
        for (uint256 i; i < a.length; i++) {
            leaves[i] = Merkle.whitelistLeaf(a[i], Cfg.WHITELIST_VP);
        }
    }

    /// @notice The merkle root the snapshot.box UI stores for this whitelist.
    function _docWhitelistRoot() internal pure returns (bytes32) {
        return Merkle.root(_whitelistLeaves());
    }

    /// @notice The two strategies an author may prove proposition power over.
    /// @dev    Index 0 = delegated SHU, index 1 = the whitelist. Fresh mode deploys the
    ///         MERKLE whitelist (params = the root), matching what the snapshot.box UI
    ///         produces. The whitelist is used for proposal validation ONLY.
    function _allowedProposalStrategies() internal pure returns (Strategy[] memory out) {
        out = new Strategy[](2);
        out[0] = Strategy({ addr: Cfg.OZ_VOTES_VOTING_STRATEGY, params: abi.encodePacked(Cfg.SHU) });
        out[1] = Strategy({ addr: Cfg.MERKLE_WHITELIST_VOTING_STRATEGY, params: abi.encode(_docWhitelistRoot()) });
    }

    /// @notice PropositionPower validation: the author must clear the threshold over
    ///         `_allowedProposalStrategies()`.
    function _proposalValidationStrategy() internal view returns (Strategy memory) {
        return Strategy({
            addr: Cfg.PROPOSITION_POWER_VALIDATION,
            params: abi.encode(P.proposalThreshold, _allowedProposalStrategies())
        });
    }

    function _authenticators() internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = Cfg.ETH_TX_AUTHENTICATOR;
        out[1] = Cfg.ETH_SIG_AUTHENTICATOR;
    }

    function _spaceInit() internal view returns (InitializeCalldata memory init) {
        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = "SHU (ERC20Votes, delegated)";

        init = InitializeCalldata({
            owner: P.spaceControllerInitial,
            votingDelay: P.votingDelay,
            minVotingDuration: P.minVotingDuration,
            maxVotingDuration: P.maxVotingDuration,
            proposalValidationStrategy: _proposalValidationStrategy(),
            proposalValidationStrategyMetadataURI: "PropositionPower over SHU",
            daoURI: P.daoURI,
            metadataURI: P.metadataURI,
            votingStrategies: _votingStrategies(),
            votingStrategyMetadataURIs: votingStrategyMetadataURIs,
            authenticators: _authenticators()
        });
    }

    /// @notice `setUp(bytes)` calldata for the AvatarExecutionStrategy proxy.
    /// @dev    Nested encoding: setUp selector + abi.encode(bytes initParams), where
    ///         initParams = abi.encode(owner, target, spaces[], quorum).
    function _strategyInitializer(address theSpace) internal view returns (bytes memory) {
        address[] memory spaces = new address[](1);
        spaces[0] = theSpace;
        bytes memory initParams = abi.encode(Cfg.SAFE, Cfg.SAFE, spaces, P.quorum);
        return abi.encodeCall(IAvatarExecutionStrategy.setUp, (initParams));
    }

    /// @notice The `deployProxy` call snapshot.box makes for the execution strategy
    ///         during space creation. Kept so Step 2 can decode `setUp` and check it.
    function _deployStrategyCalldata(address theSpace) internal view returns (bytes memory) {
        return abi.encodeCall(
            IProxyFactory.deployProxy,
            (Cfg.AVATAR_EXECUTION_STRATEGY_IMPL, _strategyInitializer(theSpace), P.strategySaltNonce)
        );
    }

    /// @notice Vote 1, tx[1]: `enableModule(strategy)` on the Safe.
    function _enableModuleCalldata(address module) internal pure returns (bytes memory) {
        return abi.encodeCall(ISafe.enableModule, (module));
    }

    /// @notice Vote 2, tx[0]: `swapOwner(sentinel, Azorius, strategy)`.
    function _swapOwnerCalldata(address newOwner) internal pure returns (bytes memory) {
        return abi.encodeCall(ISafe.swapOwner, (Cfg.SENTINEL, Cfg.AZORIUS, newOwner));
    }

    /// @notice Vote 2, tx[1]: `disableModule(prevModule, Azorius)`.
    function _disableModuleCalldata(address prevModule) internal pure returns (bytes memory) {
        return abi.encodeCall(ISafe.disableModule, (prevModule, Cfg.AZORIUS));
    }

    // =====================================================================
    // Safe linked-list reads
    // =====================================================================

    function _modules() internal view returns (address[] memory list) {
        (list,) = safe.getModulesPaginated(Cfg.SENTINEL, 10);
    }

    /// @notice The entry that points at `module` in the Safe's module linked list.
    /// @dev    MIGRATION.md sec 3: getting this wrong makes `disableModule` a silent no-op
    ///         when executed via `execTransactionFromModule`. Always recompute it live.
    function _prevModule(address module) internal view returns (address) {
        address[] memory list = _modules();
        for (uint256 i; i < list.length; i++) {
            if (list[i] == module) return i == 0 ? Cfg.SENTINEL : list[i - 1];
        }
        revert("module not in list");
    }

    function _logModules(string memory label) internal view {
        address[] memory list = _modules();
        console.log(string.concat("   ", label, " (count):"), list.length);
        for (uint256 i; i < list.length; i++) {
            console.log("     -", list[i]);
        }
    }

    function _logOwners(string memory label) internal view {
        address[] memory list = safe.getOwners();
        console.log(string.concat("   ", label, " (count):"), list.length);
        for (uint256 i; i < list.length; i++) {
            console.log("     -", list[i]);
        }
    }

    // =====================================================================
    // Execution path A — Decent / Azorius
    // =====================================================================

    /// @notice Executes one action the way a *passed* Decent proposal would.
    /// @dev    Impersonates the Azorius module and calls `execTransactionFromModule`,
    ///         which is exactly what `Azorius.executeProposal` does once a proposal has
    ///         passed and its timelock has elapsed. The vote itself and the Security
    ///         Council freeze guard are NOT modelled — see README "What is not simulated".
    function _execViaDecent(address to, bytes memory data, string memory label) internal returns (bool success) {
        vm.prank(Cfg.AZORIUS);
        success = safe.execTransactionFromModule(to, 0, data, Operation.Call);
        // execTransactionFromModule swallows inner reverts and returns false, so the
        // return value must be checked explicitly — and so must the resulting state.
        checkTrue(string.concat("Decent exec succeeded: ", label), success);
    }

    // =====================================================================
    // Execution path B — Snapshot X
    // =====================================================================

    /// @notice Full propose -> vote -> execute cycle through the new Snapshot X space.
    /// @param  txs     the MetaTransactions the Safe should run
    /// @param  label   human label for the log
    /// @return proposalId the id the space assigned
    function _runSnapshotXProposal(MetaTransaction[] memory txs, string memory label)
        internal
        returns (uint256 proposalId)
    {
        require(space != address(0) && strategy != address(0), "space/strategy not set");
        _provisionSimVoters();

        bytes memory payload = abi.encode(txs);
        Strategy memory execStrategy = Strategy({ addr: strategy, params: payload });

        IAuthenticator auth = IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR);
        proposalId = ISpace(space).nextProposalId();

        // --- propose -----------------------------------------------------
        IndexedStrategy[] memory userStrategies = new IndexedStrategy[](1);
        userStrategies[0] = IndexedStrategy({ index: 0, params: "" });

        vm.prank(Cfg.SIM_PROPOSER);
        auth.authenticate(
            space,
            ISpace.propose.selector,
            abi.encode(Cfg.SIM_PROPOSER, label, execStrategy, abi.encode(userStrategies))
        );
        console.log(string.concat("   proposed: ", label, "  id ="), proposalId);

        // --- vote --------------------------------------------------------
        if (P.votingDelay > 0) vm.roll(block.number + P.votingDelay);

        vm.prank(Cfg.SIM_PROPOSER);
        auth.authenticate(
            space, ISpace.vote.selector, abi.encode(Cfg.SIM_PROPOSER, proposalId, Choice.For, userStrategies, "")
        );
        vm.prank(Cfg.SIM_VOTER);
        auth.authenticate(
            space, ISpace.vote.selector, abi.encode(Cfg.SIM_VOTER, proposalId, Choice.For, userStrategies, "")
        );

        // --- finalize ----------------------------------------------------
        if (P.minVotingDuration > 0) vm.roll(block.number + P.minVotingDuration);

        ISpace(space).execute(proposalId, payload);
        lastProposalId = proposalId;
    }

    /// @notice Funds and delegates two simulation-only voters out of the treasury.
    /// @dev    SIM-ONLY. In production, proposition power comes from real SHU holders.
    ///         The transfer is impersonated from the Safe purely to give the fork a
    ///         voter with enough delegated power to clear the 10M SHU threshold.
    function _provisionSimVoters() internal {
        if (votersProvisioned) return;
        votersProvisioned = true;

        // The proposer must clear the proposition-power threshold to open a proposal.
        uint256 proposerStake = P.proposalThreshold + 1e18;
        // The voter must, on its own, be able to carry the quorum so the smoke-test
        // proposals reach Accepted — whatever the space's quorum happens to be
        // (the doc says 30,000,000 SHU).
        uint256 voterStake = P.quorum + 1_000e18;
        // Cap total sim funding to what the treasury can actually spare.
        uint256 treasury = shu.balanceOf(Cfg.SAFE);
        require(proposerStake + voterStake < treasury, "sim stake exceeds treasury; lower QUORUM/THRESHOLD");

        vm.prank(Cfg.SAFE);
        require(shu.transfer(Cfg.SIM_PROPOSER, proposerStake), "proposer funding failed");
        vm.prank(Cfg.SAFE);
        require(shu.transfer(Cfg.SIM_VOTER, voterStake), "voter funding failed");

        vm.prank(Cfg.SIM_PROPOSER);
        shu.delegate(Cfg.SIM_PROPOSER);
        vm.prank(Cfg.SIM_VOTER);
        shu.delegate(Cfg.SIM_VOTER);

        // ERC20Votes checkpoints are only readable via getPastVotes once the block
        // they were written in is in the past.
        vm.roll(block.number + 1);

        _section("[sim-only] provisioned test voters out of the treasury");
        _ok("proposer:", Cfg.SIM_PROPOSER);
        _ok("proposer delegated votes:", shu.getVotes(Cfg.SIM_PROPOSER));
        _ok("voter:", Cfg.SIM_VOTER);
        _ok("voter delegated votes:", shu.getVotes(Cfg.SIM_VOTER));
    }

    // =====================================================================
    // The doc's internal / DAO testing checklist
    //   - proposal validation (10M SHU and whitelist)
    //   - pre-vote delay
    //   - security council veto
    // (SHU voting incl. delegation and quorum are exercised by _runSnapshotXProposal)
    // =====================================================================

    function _docTestMatrix() internal {
        _banner("STEP 5c  |  Doc test matrix: whitelist, pre-vote delay, SC veto");
        uint256 id = _checkWhitelistValidation();
        _checkPreVoteDelay(id);
        _checkSecurityCouncilVeto(id);
    }

    /// @dev Proposal validation strategy 2 — the nine-address whitelist.
    function _checkWhitelistValidation() internal returns (uint256 id) {
        ISpace s = ISpace(space);

        // Whitelist member 7 holds no SHU and has no delegated votes, so the only
        // way it can open a proposal is through the whitelist.
        uint256 wIndex = 7;
        address member = Cfg.whitelistedProposers()[wIndex];

        _section("proposal validation via the whitelist (member holds no SHU)");
        _ok("whitelisted proposer:", member);
        _ok("its delegated SHU votes:", shu.getVotes(member));
        checkTrue("member is below the 10M SHU threshold", shu.getVotes(member) < P.proposalThreshold);

        checkTrue("proposing on SHU power alone is rejected", !_tryPropose(member, _viaShu(), "via SHU"));

        id = s.nextProposalId();
        checkTrue("proposing via the whitelist succeeds", _tryPropose(member, _viaWhitelist(wIndex), "via whitelist"));
        check("proposal id assigned", s.nextProposalId(), id + 1);

        checkTrue(
            "a non-member cannot use a whitelist index", !_tryPropose(Cfg.SIM_PAYEE, _viaWhitelist(wIndex), "impostor")
        );
    }

    /// @dev Pre-vote delay — doc: 2 days.
    function _checkPreVoteDelay(uint256 id) internal {
        ISpace s = ISpace(space);
        (, uint32 startBlock,,,,,,) = s.proposals(id);

        _section("pre-vote delay (doc: 2 days)");
        _ok("votingDelay (blocks):", P.votingDelay);
        _ok("current block:", block.number);
        _ok("voting opens at block:", startBlock);
        check("startBlock == proposal block + votingDelay", uint256(startBlock), block.number + P.votingDelay);
        check("status during the delay", uint256(s.getProposalStatus(id)), uint256(ProposalStatus.VotingDelay));
        checkTrue("voting during the delay is rejected", !_tryVote(Cfg.SIM_PROPOSER, id));

        vm.roll(block.number + P.votingDelay);
        checkTrue("voting works once the delay has passed", _tryVote(Cfg.SIM_PROPOSER, id));
        checkTrue("vote recorded", s.votePower(id, Choice.For) > 0);
    }

    /// @dev Security Council veto — the controller cancels a pending proposal.
    function _checkSecurityCouncilVeto(uint256 id) internal {
        ISpace s = ISpace(space);
        _section("Security Council veto (controller calls cancel)");

        bool reverted;
        vm.prank(Cfg.SIM_PROPOSER);
        try s.cancel(id) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("a non-controller cannot veto", reverted);

        vm.prank(s.owner());
        s.cancel(id);
        check("status after the veto", uint256(s.getProposalStatus(id)), uint256(ProposalStatus.Cancelled));

        vm.roll(block.number + P.minVotingDuration);
        uint256 payeeBefore = shu.balanceOf(Cfg.SIM_PAYEE);
        try s.execute(id, _vetoPayload()) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("a vetoed proposal cannot be executed", reverted);
        check("nothing moved", shu.balanceOf(Cfg.SIM_PAYEE), payeeBefore);
    }

    // --- small helpers, kept separate to stay off the stack ---------------

    function _vetoPayload() internal pure returns (bytes memory) {
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, uint256(1)),
            operation: Operation.Call,
            salt: 900
        });
        return abi.encode(txs);
    }

    function _viaShu() internal pure returns (IndexedStrategy[] memory out) {
        out = new IndexedStrategy[](1);
        out[0] = IndexedStrategy({ index: 0, params: "" });
    }

    /// @notice Builds the `userParams` a whitelisted author submits to prove membership,
    ///         in the encoding the space's ACTUAL whitelist strategy expects.
    /// @dev    Merkle strategy (UI default): abi.encode(bytes32[] proof, Member member).
    ///         Plain strategy: abi.encode(uint256 memberIndex).
    ///         The member is always `whitelistedProposers()[memberIndex]` at 10M SHU.
    function _viaWhitelist(uint256 memberIndex) internal view returns (IndexedStrategy[] memory out) {
        out = new IndexedStrategy[](1);
        out[0] = IndexedStrategy({ index: 1, params: _whitelistUserParams(memberIndex) });
    }

    function _whitelistUserParams(uint256 memberIndex) internal view returns (bytes memory) {
        // Which whitelist strategy does this space actually use?
        (, bytes memory pvParams) = ISpace(space).proposalValidationStrategy();
        (, Strategy[] memory allowed) = abi.decode(pvParams, (uint256, Strategy[]));
        address wl = allowed[1].addr;

        if (wl == Cfg.MERKLE_WHITELIST_VOTING_STRATEGY) {
            bytes32[] memory leaves = _whitelistLeaves();
            WhitelistMember memory member =
                WhitelistMember({ addr: Cfg.whitelistedProposers()[memberIndex], vp: Cfg.WHITELIST_VP });
            bytes32[] memory proof = Merkle.proof(leaves, leaves[memberIndex]);
            return abi.encode(proof, member);
        }
        // Plain WhitelistVotingStrategy: the userParams is just the index.
        return abi.encode(memberIndex);
    }

    function _tryPropose(address author, IndexedStrategy[] memory userStrategies, string memory label)
        internal
        returns (bool ok)
    {
        Strategy memory exec = Strategy({ addr: strategy, params: _vetoPayload() });
        bytes memory data = abi.encode(author, label, exec, abi.encode(userStrategies));
        vm.prank(author);
        try IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR).authenticate(space, ISpace.propose.selector, data) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _tryVote(address voter, uint256 id) internal returns (bool ok) {
        bytes memory data = abi.encode(voter, id, Choice.For, _viaShu(), "");
        vm.prank(voter);
        try IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR).authenticate(space, ISpace.vote.selector, data) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    // =====================================================================
    // Controller handover (doc: "change controller address to Security Council
    // Multisig", between internal testing and enabling the module)
    // =====================================================================

    /// @dev The handover touches only the Space contract. `Space.transferOwnership` is
    ///      OpenZeppelin `onlyOwner` and single-step: the current controller signs one
    ///      wallet transaction and it takes effect immediately. The Safe, Azorius and the
    ///      module list are not involved, which is why this works — and is asserted to
    ///      work — while the strategy is still not a module.
    function _handOverController() internal {
        _banner("STEP 3  |  Update the space controller to the Security Council");

        ISpace s = ISpace(space);
        address previousController = s.owner();

        if (previousController == P.spaceController) {
            // Already done on chain (attach mode, re-run). Verify rather than repeat.
            _section("already handed over");
            check("owner (space controller)", s.owner(), P.spaceController);
            checkTrue("controller is a contract (the SC multisig)", P.spaceController.code.length > 0);
            return;
        }

        _section("preconditions: no module is enabled yet");
        check("strategy is NOT a Safe module", safe.isModuleEnabled(strategy), false);
        if (!attached) check("Azorius is still the only module", _modules().length, 1);
        uint256 safeNonceBefore = safe.nonce();

        _section("handover");
        _ok("from:", previousController);
        _ok("to:", P.spaceController);
        if (!attached) {
            check("current controller is the deploying wallet", previousController, P.spaceControllerInitial);
        }

        // A wallet transaction by the current controller. Not a DAO vote, and nothing
        // to do with the Safe.
        vm.prank(previousController);
        s.transferOwnership(P.spaceController);
        check("owner (space controller)", s.owner(), P.spaceController);

        bool reverted;
        vm.prank(previousController);
        try s.transferOwnership(previousController) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("old controller can no longer act", reverted);

        // Nobody else can take it either.
        vm.prank(Cfg.SIM_PAYEE);
        try s.transferOwnership(Cfg.SIM_PAYEE) {
            reverted = false;
        } catch {
            reverted = true;
        }
        checkTrue("a third party cannot take the controller", reverted);

        _section("the Safe was not involved");
        check("Safe nonce unchanged", safe.nonce(), safeNonceBefore);
        check("strategy still NOT a Safe module", safe.isModuleEnabled(strategy), false);
        check("Azorius still enabled", safe.isModuleEnabled(Cfg.AZORIUS), true);
        if (!attached) {
            check("module list unchanged", _modules().length, 1);
            check("Safe owners unchanged", safe.getOwners()[0], Cfg.AZORIUS);
        }

        _section("the new controller can already exercise controller powers");
        // The execution strategy's own "Controller address" is a different thing: it is
        // the Safe, set in setUp at creation, and it never changes.
        check(
            "strategy owner is the Safe, not the space controller", IAvatarExecutionStrategy(strategy).owner(), Cfg.SAFE
        );
        checkTrue("space controller != strategy controller", s.owner() != IAvatarExecutionStrategy(strategy).owner());
    }

    // =====================================================================
    // Result file
    // =====================================================================

    function _writeState(string memory step) internal {
        string memory obj = "state";
        vm.serializeString(obj, "lastStep", step);
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeUint(obj, "forkBlock", block.number);
        vm.serializeAddress(obj, "safe", Cfg.SAFE);
        vm.serializeAddress(obj, "azorius", Cfg.AZORIUS);
        vm.serializeAddress(obj, "spaceControllerInitial", P.spaceControllerInitial);
        vm.serializeAddress(obj, "spaceController", P.spaceController);
        vm.serializeAddress(obj, "spaceDeployer", P.spaceDeployer);
        vm.serializeUint(obj, "spaceSaltNonce", P.spaceSaltNonce);
        vm.serializeUint(obj, "strategySaltNonce", P.strategySaltNonce);
        vm.serializeAddress(obj, "strategyDeployer", P.spaceDeployer);
        vm.serializeBool(obj, "attached", attached);
        vm.serializeAddress(obj, "space", space);
        vm.serializeAddress(obj, "strategy", strategy);
        vm.serializeBool(obj, "strategyDeployed", strategyDeployed);
        vm.serializeUint(obj, "quorum", P.quorum);
        vm.serializeUint(obj, "proposalThreshold", P.proposalThreshold);
        vm.serializeBytes(
            obj,
            "spaceCreate_deploySpaceCalldata",
            abi.encodeCall(
                IProxyFactory.deployProxy,
                (Cfg.SPACE_IMPL, abi.encodeCall(ISpace.initialize, (_spaceInit())), P.spaceSaltNonce)
            )
        );
        vm.serializeBytes(obj, "spaceCreate_deployStrategyCalldata", _deployStrategyCalldata(space));
        vm.serializeBytes(obj, "vote1_enableModuleCalldata", _enableModuleCalldata(strategy));
        vm.serializeBytes(obj, "vote2_swapOwnerCalldata", _swapOwnerCalldata(strategy));
        // prevModule is the strategy once it sits at the head of the module list.
        vm.serializeBytes(obj, "vote2_disableModuleCalldata", _disableModuleCalldata(strategy));
        string memory out = vm.serializeUint(obj, "lastProposalId", lastProposalId);
        vm.writeJson(out, "./sim/state.json");
        console.log("");
        console.log("   wrote ./sim/state.json");
    }
}

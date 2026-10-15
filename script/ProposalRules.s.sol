// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { ProposalRulesBase } from "./ProposalRulesBase.s.sol";
import { Cfg } from "src/Config.sol";
import {
    IAvatarExecutionStrategy,
    ISpace,
    IndexedStrategy,
    MetaTransaction,
    Operation,
    Strategy
} from "src/interfaces/ISnapshotX.sol";

/// @title ProposalRules: simulate the new proposal rules on the live space.
///
/// @notice Forks mainnet, applies the change to the REAL space as its controller (the
///         Security Council), and proves each rule:
///
///           A. baseline     the live space is at 10M SHU, whitelist at 10M, no limit
///           B. apply        one updateSettings call; nothing else in the space changes
///           C. threshold    10M and 50M-minus-1-wei are rejected, exactly 50M is accepted
///           D. whitelist    all nine members can still propose with 50M deemed power;
///                           the old 10M proof and an impostor are rejected
///           E. rate limit   one proposal per address per 24h, measured from the last
///                           proposal; rejected tries do not reset the clock; a vetoed
///                           proposal still counts
///           F. end to end   a proposal under the new rules passes and executes
///
///         RATE_LIMIT=0 runs the threshold-only variant; E then shows there is no limit.
///
/// Run:  ./sim.sh proposal-rules                 (defaults to the live space)
///       RATE_LIMIT=0 ./sim.sh proposal-rules    (threshold-only variant)
contract ProposalRules is ProposalRulesBase {
    /// @dev EIP-1967 implementation slot: empty on a contract that is not a proxy.
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal controller;

    function run() public virtual {
        _setUpFork();
        _useLiveSpaceByDefault();
        _loadRules();
        _syncParamsWithLiveSpace();

        _baseline();
        _apply();
        _threshold();
        _whitelist();
        _rateLimit();
        _endToEnd();

        _report("ProposalRules");
    }

    /// @dev Use the live space's own timings and quorum, and fund sim voters for the
    ///      NEW threshold (SimBase._provisionSimVoters reads P.proposalThreshold).
    function _syncParamsWithLiveSpace() internal {
        ISpace s = ISpace(space);
        P.votingDelay = s.votingDelay();
        P.minVotingDuration = s.minVotingDuration();
        P.maxVotingDuration = s.maxVotingDuration();
        P.quorum = IAvatarExecutionStrategy(strategy).quorum();
        P.proposalThreshold = R.threshold;
        controller = s.owner();
    }

    // =====================================================================
    // A. Baseline
    // =====================================================================

    function _baseline() internal {
        _banner("A  |  BASELINE  |  the live space's proposal rules today");
        _ok("space:", space);
        _ok("fork block:", block.number);
        _ok("space controller:", controller);
        check("controller is the Security Council", controller, Cfg.SECURITY_COUNCIL);

        (address addr,,, uint256 threshold, Strategy[] memory allowed) = _liveRules();
        _section("current proposal validation");
        check("strategy is PropositionPower (no rate limit)", addr, Cfg.PROPOSITION_POWER_VALIDATION);
        check("threshold is 10M SHU", threshold, OLD_THRESHOLD);
        check("allowed strategy count", allowed.length, 2);
        check("allowed[0] is OZ Votes", allowed[0].addr, Cfg.OZ_VOTES_VOTING_STRATEGY);
        checkBytes("allowed[0] reads SHU", allowed[0].params, abi.encodePacked(Cfg.SHU));
        check("allowed[1] is the Merkle whitelist", allowed[1].addr, Cfg.MERKLE_WHITELIST_VOTING_STRATEGY);
        check(
            "whitelist root = nine members at 10M", abi.decode(allowed[1].params, (bytes32)), _rootAt(Cfg.WHITELIST_VP)
        );

        _section("the rate-limited validation contract (sx-evm deployment)");
        address limiter = Cfg.PROPOSITION_POWER_AND_LIMITER_VALIDATION;
        _ok("address:", limiter);
        checkTrue("has code", limiter.code.length > 0);
        check("is not an upgradeable proxy", vm.load(limiter, EIP1967_IMPL_SLOT), bytes32(0));

        _section("control: under today's rules a 10M holder and a whitelisted member can propose");
        address holder10 = _holderWith("10M", OLD_THRESHOLD);
        checkTrue("10M SHU holder can propose", _tryPropose(holder10, _viaShu(), "old rules: 10M holder"));
        checkTrue("member 7 with the 10M proof can propose", _tryPropose(_member(7), _viaOldWhitelist(7), "old"));
        checkTrue(
            "member 7 can propose again at once (no limit today)", _tryPropose(_member(7), _viaOldWhitelist(7), "x")
        );
    }

    // =====================================================================
    // B. Apply the change
    // =====================================================================

    /// @dev Everything the change must NOT touch, captured before it is applied.
    struct Untouched {
        uint32 votingDelay;
        uint32 minVotingDuration;
        uint32 maxVotingDuration;
        uint8 nextVotingStrategyIndex;
        uint256 activeVotingStrategies;
        address votingStrategy0;
        bytes votingStrategy0Params;
        string daoURI;
        uint256 nextProposalId;
        uint256 safeNonce;
    }

    function _apply() internal {
        _banner("B  |  APPLY  |  Security Council calls updateSettings");
        _ok("new validation strategy:", _newValidationStrategy().addr);
        _ok("rate limit:", R.rateLimit ? "on" : "OFF (threshold-only variant)");
        _ok("threshold (wei):", R.threshold);
        _ok("whitelist deemed power (wei):", uint256(R.whitelistVp));
        if (R.rateLimit) {
            _ok("cooldown (seconds):", R.cooldown);
            _ok("proposals per cooldown:", R.maxProposals);
        }

        Untouched memory before = _snapshotUntouched();

        _section("only the controller can make the change");
        vm.prank(Cfg.SIM_PAYEE);
        (bool ok,) = space.call(_updateSettingsCalldata());
        checkTrue("updateSettings from a non-controller reverts", !ok);

        vm.prank(controller);
        (ok,) = space.call(_updateSettingsCalldata());
        checkTrue("updateSettings from the controller succeeds", ok);

        _checkStored();
        _checkUntouched(before);
    }

    function _snapshotUntouched() internal view returns (Untouched memory u) {
        ISpace s = ISpace(space);
        u.votingDelay = s.votingDelay();
        u.minVotingDuration = s.minVotingDuration();
        u.maxVotingDuration = s.maxVotingDuration();
        u.nextVotingStrategyIndex = s.nextVotingStrategyIndex();
        u.activeVotingStrategies = s.activeVotingStrategies();
        (u.votingStrategy0, u.votingStrategy0Params) = s.votingStrategies(0);
        u.daoURI = s.daoURI();
        u.nextProposalId = s.nextProposalId();
        u.safeNonce = safe.nonce();
    }

    function _checkStored() internal {
        _section("the new rules are stored");
        Strategy memory want = _newValidationStrategy();
        (address addr, bytes memory params) = ISpace(space).proposalValidationStrategy();
        check("validation strategy address", addr, want.addr);
        checkBytes("validation strategy params", params, want.params);

        (, uint256 cooldown, uint256 maxProposals, uint256 threshold, Strategy[] memory allowed) = _liveRules();
        check("decoded threshold", threshold, R.threshold);
        if (R.rateLimit) {
            check("decoded cooldown", cooldown, R.cooldown);
            check("decoded proposals per cooldown", maxProposals, R.maxProposals);
        }
        check("allowed[0] still OZ Votes", allowed[0].addr, Cfg.OZ_VOTES_VOTING_STRATEGY);
        check("allowed[1] still the Merkle whitelist", allowed[1].addr, Cfg.MERKLE_WHITELIST_VOTING_STRATEGY);
        check(
            "whitelist root = nine members at the new power",
            abi.decode(allowed[1].params, (bytes32)),
            _rootAt(R.whitelistVp)
        );
    }

    function _checkUntouched(Untouched memory before) internal {
        _section("nothing else changed");
        Untouched memory now_ = _snapshotUntouched();
        check("votingDelay", now_.votingDelay, before.votingDelay);
        check("minVotingDuration", now_.minVotingDuration, before.minVotingDuration);
        check("maxVotingDuration", now_.maxVotingDuration, before.maxVotingDuration);
        check("nextVotingStrategyIndex", now_.nextVotingStrategyIndex, before.nextVotingStrategyIndex);
        check("activeVotingStrategies", now_.activeVotingStrategies, before.activeVotingStrategies);
        check("voting strategy 0 address", now_.votingStrategy0, before.votingStrategy0);
        checkBytes("voting strategy 0 params", now_.votingStrategy0Params, before.votingStrategy0Params);
        check("daoURI", now_.daoURI, before.daoURI);
        check("no proposal was created", now_.nextProposalId, before.nextProposalId);
        check("the DAO Safe was not involved (nonce)", now_.safeNonce, before.safeNonce);
        check("controller", ISpace(space).owner(), controller);
        check("EthTx authenticator still enabled", ISpace(space).authenticators(Cfg.ETH_TX_AUTHENTICATOR), 1);
        check("EthSig authenticator still enabled", ISpace(space).authenticators(Cfg.ETH_SIG_AUTHENTICATOR), 1);
    }

    // =====================================================================
    // C. 50M SHU threshold
    // =====================================================================

    function _threshold() internal {
        _banner("C  |  THRESHOLD  |  50M SHU of delegated power to propose");

        address holder10 = _holderWith("10M-after", OLD_THRESHOLD);
        checkRejected("10M SHU holder is now rejected", holder10, _viaShu(), FAILED_VALIDATION);

        address edge = _holderWith("edge", R.threshold - 1);
        _ok("edge holder votes:", shu.getVotes(edge));
        checkRejected("threshold minus 1 wei is rejected", edge, _viaShu(), FAILED_VALIDATION);

        _topUp(edge, R.threshold);
        vm.roll(block.number + 1);
        _ok("edge holder votes:", shu.getVotes(edge));
        uint256 id = ISpace(space).nextProposalId();
        checkTrue("exactly the threshold is accepted", _tryPropose(edge, _viaShu(), "50M"));
        check("proposal id assigned", ISpace(space).nextProposalId(), id + 1);

        checkRejected("a holder with 0 SHU is rejected", Cfg.SIM_PAYEE, _viaShu(), FAILED_VALIDATION);
    }

    // =====================================================================
    // D. Whitelist at 50M deemed power
    // =====================================================================

    function _whitelist() internal {
        _banner("D  |  WHITELIST  |  nine members keep their proposer role at 50M");

        _section("the old 10M proof no longer works (its leaf is not in the new tree)");
        checkRejected("member 0 with the 10M proof is rejected", _member(0), _viaOldWhitelist(0), INVALID_PROOF);

        _section("every member can propose with the 50M proof");
        for (uint256 i; i < 9; i++) {
            address m = _member(i);
            checkTrue(
                string.concat("member ", vm.toString(i), " ", vm.toString(m)), _tryPropose(m, _viaNewWhitelist(i), "wl")
            );
        }

        _section("membership cannot be borrowed");
        IndexedStrategy[] memory impostor = _viaWhitelistAt(3, R.whitelistVp, Cfg.SIM_PAYEE);
        checkRejected("impostor claiming member 3's slot is rejected", Cfg.SIM_PAYEE, impostor, INVALID_PROOF);
        checkRejected(
            "impostor sending member 3's real proof is rejected", Cfg.SIM_PAYEE, _viaNewWhitelist(3), INVALID_MEMBER
        );
    }

    // =====================================================================
    // E. One proposal per address per 24h
    // =====================================================================

    function _rateLimit() internal {
        if (!R.rateLimit) {
            _banner("E  |  RATE LIMIT  |  OFF in this variant");
            checkTrue("member 0 can propose again at once", _tryPropose(_member(0), _viaNewWhitelist(0), "again"));
            return;
        }
        _banner("E  |  RATE LIMIT  |  one proposal per address per 24 hours");

        // Member 0 proposed in section D, at this timestamp.
        uint256 t0 = block.timestamp;
        _ok("member 0 last proposed at (unix):", t0);

        _section("the same address, inside the window");
        checkRejected("immediately: rejected", _member(0), _viaNewWhitelist(0), FAILED_VALIDATION);
        vm.warp(t0 + 12 hours);
        checkRejected("after 12h: rejected", _member(0), _viaNewWhitelist(0), FAILED_VALIDATION);
        vm.warp(t0 + R.cooldown - 1);
        checkRejected("after 24h minus 1s: rejected", _member(0), _viaNewWhitelist(0), FAILED_VALIDATION);

        _section("rejected tries did not restart the clock");
        vm.warp(t0 + R.cooldown);
        checkTrue("after exactly 24h: accepted", _tryPropose(_member(0), _viaNewWhitelist(0), "24h"));
        checkRejected("and then rejected again", _member(0), _viaNewWhitelist(0), FAILED_VALIDATION);

        _section("the window is per address");
        checkTrue("member 1 is not blocked by member 0", _tryPropose(_member(1), _viaNewWhitelist(1), "m1"));

        _section("SHU holders are limited too, and a vetoed proposal still counts");
        address holder = _holderWith("rate", R.threshold);
        uint256 id = ISpace(space).nextProposalId();
        checkTrue("50M holder proposes", _tryPropose(holder, _viaShu(), "h1"));
        checkRejected("50M holder: second proposal rejected", holder, _viaShu(), FAILED_VALIDATION);
        vm.prank(controller);
        ISpace(space).cancel(id);
        checkRejected("after the Security Council vetoes it: still rejected", holder, _viaShu(), FAILED_VALIDATION);
        vm.warp(block.timestamp + R.cooldown);
        checkTrue("24h later: accepted", _tryPropose(holder, _viaShu(), "h4"));
    }

    // =====================================================================
    // F. End to end
    // =====================================================================

    function _endToEnd() internal {
        _banner("F  |  END TO END  |  propose, vote and execute under the new rules");
        if (!safe.isModuleEnabled(strategy)) {
            console.log("   strategy is not a Safe module on this fork - skipping execution.");
            return;
        }
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, uint256(1e18)),
            operation: Operation.Call,
            salt: 4242
        });
        uint256 payeeBefore = shu.balanceOf(Cfg.SIM_PAYEE);
        _runSnapshotXProposal(txs, "new rules: end to end");
        check("payee received 1 SHU", shu.balanceOf(Cfg.SIM_PAYEE) - payeeBefore, 1e18);
    }

    function _member(uint256 i) internal pure returns (address) {
        return Cfg.whitelistedProposers()[i];
    }
}

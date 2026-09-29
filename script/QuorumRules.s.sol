// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console2 as console } from "forge-std/console2.sol";

import { Step1_CreateSpace } from "./Step1_CreateSpace.s.sol";
import { Cfg } from "src/Config.sol";
import {
    Choice,
    IAuthenticator,
    IAvatarExecutionStrategy,
    ISpace,
    IndexedStrategy,
    MetaTransaction,
    Operation,
    ProposalStatus,
    Strategy
} from "src/interfaces/ISnapshotX.sol";

/// @title QuorumRules — does an Abstain vote count towards quorum?
/// @notice Runs four proposals against the live space, each with a different mix of
///         votes, and reads the resulting status. The sim proposer holds just over
///         10M SHU of voting power (below the 30M quorum on its own) and the sim
///         voter holds just over 30M, so the two can be combined to isolate the
///         effect of each choice.
///
///           A. For only, below quorum                 -> control
///           B. For below quorum + Abstain above it    -> the actual question
///           C. For below quorum + Against above it    -> does Against count too?
///           D. For above quorum on its own            -> control
///
/// Run:  SNAPSHOT_X_SPACE=0x… SNAPSHOT_X_STRATEGY=0x… forge script script/QuorumRules.s.sol -vv
contract QuorumRules is Step1_CreateSpace {
    function run() public virtual override {
        _setUpFork();
        _baseline();
        _ensureSpace();
        _quorumRules();
        _report("QuorumRules");
    }

    function _quorumRules() internal {
        _banner("QUORUM RULES  |  which choices count towards quorum?");
        uint256 q = IAvatarExecutionStrategy(strategy).quorum();
        _ok("quorum:", q);
        _provisionSimVoters();
        _ok("proposer voting power:", shu.getVotes(Cfg.SIM_PROPOSER));
        _ok("voter voting power:", shu.getVotes(Cfg.SIM_VOTER));
        checkTrue("proposer alone is BELOW quorum", shu.getVotes(Cfg.SIM_PROPOSER) < q);
        checkTrue("voter alone is ABOVE quorum", shu.getVotes(Cfg.SIM_VOTER) >= q);

        _section("A. control: For only, below quorum");
        uint256 idA = _run(Choice.For, Choice.For, false);
        _tally(idA);
        check(
            "rejected, quorum not reached",
            uint256(ISpace(space).getProposalStatus(idA)),
            uint256(ProposalStatus.Rejected)
        );

        _section("B. the question: small For + large ABSTAIN");
        uint256 idB = _run(Choice.For, Choice.Abstain, true);
        _tally(idB);
        uint256 statusB = uint256(ISpace(space).getProposalStatus(idB));
        console.log("   status:", statusB, statusB == uint256(ProposalStatus.Accepted) ? "ACCEPTED" : "not accepted");
        checkTrue("abstain COUNTS towards quorum", statusB == uint256(ProposalStatus.Accepted));

        _section("C. small For + large AGAINST (not a discriminator, see E)");
        uint256 idC = _run(Choice.For, Choice.Against, true);
        _tally(idC);
        check(
            "rejected: quorum met but For <= Against",
            uint256(ISpace(space).getProposalStatus(idC)),
            uint256(ProposalStatus.Rejected)
        );

        _section("D. control: For above quorum on its own");
        uint256 idD = _run(Choice.Abstain, Choice.For, true);
        _tally(idD);
        check("accepted", uint256(ISpace(space).getProposalStatus(idD)), uint256(ProposalStatus.Accepted));

        // ---- the decisive pair: does AGAINST count towards quorum? ----------
        // Cases A-D cannot tell: in every one of them the For+Abstain total already
        // decides the outcome. These two isolate Against by giving the For side more
        // power than the Against side, but less than quorum on its own.
        _section("E. For 25M (below quorum) + AGAINST 10M");
        _fund(FOR_VOTER, 25_000_000e18);
        _fund(AGAINST_VOTER, 10_000_000e18);
        _fund(ABSTAIN_VOTER, 10_000_000e18);
        uint256 idE = _proposeOnly();
        vm.roll(block.number + P.votingDelay);
        _voteAs(FOR_VOTER, idE, Choice.For);
        _voteAs(AGAINST_VOTER, idE, Choice.Against);
        vm.roll(block.number + P.minVotingDuration);
        _tally(idE);
        console.log("   For+Against = 35M, which is above the 30M quorum");
        console.log("   For alone   = 25M, which is below it");
        check(
            "REJECTED: against does NOT count towards quorum",
            uint256(ISpace(space).getProposalStatus(idE)),
            uint256(ProposalStatus.Rejected)
        );

        _section("F. mirror image: For 25M + ABSTAIN 10M");
        uint256 idF = _proposeOnly();
        vm.roll(block.number + P.votingDelay);
        _voteAs(FOR_VOTER, idF, Choice.For);
        _voteAs(ABSTAIN_VOTER, idF, Choice.Abstain);
        vm.roll(block.number + P.minVotingDuration);
        _tally(idF);
        check(
            "ACCEPTED: abstain DOES count towards quorum",
            uint256(ISpace(space).getProposalStatus(idF)),
            uint256(ProposalStatus.Accepted)
        );

        _banner("RESULT");
        console.log("   quorum counts For + Abstain ONLY. Against is excluded.");
        console.log("   acceptance then needs For > Against on top of that.");
    }

    address internal constant FOR_VOTER = address(uint160(uint256(keccak256("shutter.quorum.for"))));
    address internal constant AGAINST_VOTER = address(uint160(uint256(keccak256("shutter.quorum.against"))));
    address internal constant ABSTAIN_VOTER = address(uint160(uint256(keccak256("shutter.quorum.abstain"))));

    /// @dev SIM ONLY: give an address `amount` of self-delegated SHU out of the treasury.
    function _fund(address who, uint256 amount) internal {
        if (shu.getVotes(who) >= amount) return;
        vm.prank(Cfg.SAFE);
        require(shu.transfer(who, amount), "funding failed");
        vm.prank(who);
        shu.delegate(who);
        vm.roll(block.number + 1);
    }

    /// @dev Propose, have the proposer vote `pChoice`, optionally have the big voter
    ///      vote `vChoice`, then roll past the end of the voting period.
    function _run(Choice pChoice, Choice vChoice, bool bigVoterVotes) internal returns (uint256 id) {
        id = _proposeOnly();
        vm.roll(block.number + P.votingDelay);
        _voteAs(Cfg.SIM_PROPOSER, id, pChoice);
        if (bigVoterVotes) _voteAs(Cfg.SIM_VOTER, id, vChoice);
        vm.roll(block.number + P.minVotingDuration);
    }

    function _tally(uint256 id) internal view {
        ISpace s = ISpace(space);
        console.log("   For    :", s.votePower(id, Choice.For));
        console.log("   Against:", s.votePower(id, Choice.Against));
        console.log("   Abstain:", s.votePower(id, Choice.Abstain));
    }

    function _proposeOnly() internal returns (uint256 id) {
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({
            to: Cfg.SHU,
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", Cfg.SIM_PAYEE, uint256(1)),
            operation: Operation.Call,
            salt: block.number
        });
        IndexedStrategy[] memory userStrategies = new IndexedStrategy[](1);
        userStrategies[0] = IndexedStrategy({ index: 0, params: "" });

        id = ISpace(space).nextProposalId();
        vm.prank(Cfg.SIM_PROPOSER);
        IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR)
            .authenticate(
                space,
                ISpace.propose.selector,
                abi.encode(
                    Cfg.SIM_PROPOSER,
                    "quorum rules",
                    Strategy({ addr: strategy, params: abi.encode(txs) }),
                    abi.encode(userStrategies)
                )
            );
    }

    function _voteAs(address voter, uint256 id, Choice choice) internal {
        IndexedStrategy[] memory userStrategies = new IndexedStrategy[](1);
        userStrategies[0] = IndexedStrategy({ index: 0, params: "" });
        vm.prank(voter);
        IAuthenticator(Cfg.ETH_TX_AUTHENTICATOR)
            .authenticate(space, ISpace.vote.selector, abi.encode(voter, id, choice, userStrategies, ""));
    }
}

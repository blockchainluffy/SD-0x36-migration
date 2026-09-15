# Shutter DAO 0x36 — Decent → Snapshot X migration simulation

A Foundry harness that **forks Ethereum mainnet**, stands up a real Snapshot X space
for Shutter DAO 0x36, hands the DAO Safe over to it, proves the new governance can
move the treasury, and then removes the Decent (Azorius) module — in six separately
runnable, individually verified steps.

Nothing is ever signed or broadcast. Every "transaction" is an impersonated call on
the in-memory fork. Parameters come from **`SD 0x36_Snapshot X`**; the on-chain
findings and production transaction plan live in [`MIGRATION.md`](./MIGRATION.md).

---

## Quick start

```bash
cp .env.example .env          # optional; sensible defaults are built in
./sim.sh                      # all six steps, narrated
./sim.sh 4                    # just step 4 (steps 1-3 replay first)
./sim.sh probe                # what works before the module is enabled
./sim.sh azorius              # prove Azorius can do nothing after removal
./sim.sh exec-matrix          # everything the module can execute + gov admin (see below)
./sim.sh test                 # the same thing as a forge test suite
```

> **Since the module is live on mainnet, run against the real deployment (attach
> mode).** A plain fresh-from-scratch run at the latest block no longer sees a pristine
> Safe, so pass the real addresses — see [Attach mode](#attach-mode-running-a-step-against-the-real-space).

Once the real space exists on mainnet, point any step at it and run that step on
its own:

```bash
./sim.sh 2 --space 0xSPACE --strategy 0xSTRATEGY     # verify the real space
./sim.sh 4 --space 0xSPACE --strategy 0xSTRATEGY     # rehearse a real vote
```

See [Attach mode](#attach-mode-running-a-step-against-the-real-space) below.

Requires Foundry. The things you may want to change: `MAINNET_RPC_URL` (defaults to
a public node), `FORK_BLOCK` (pin it for cached, byte-identical reruns), and
`SPACE_DEPLOYER` — the dev wallet that will sign "Create" in the UI:

```bash
./sim.sh 1 --deployer 0xYOURDEVWALLET      # or: SPACE_DEPLOYER=0x… ./sim.sh
```

Because the CREATE2 salt is `keccak256(deployer, saltNonce)`, this wallet decides
the space **and** strategy addresses, and is the space's controller until Step 3.
Set it to your real deploying wallet and the fork tests use exactly the addresses
you'll get on mainnet.

Results land in `sim/state.json`: the space address, the strategy address, and the
exact calldata for both production votes.

---

## The six steps

| # | Script | What it does |
|---|---|---|
| 1 | `script/Step1_CreateSpace.s.sol` | Asserts the live DAO baseline — including how Decent gates proposal creation today — then deploys the Snapshot X `Space` proxy **and its execution strategy** through the sx-evm `ProxyFactory`, which is the on-chain half of one snapshot.box "Create" |
| 2 | `script/Step2_VerifySpace.s.sol` | Reads every space and strategy parameter back and checks it against the doc; decodes and pre-flights the module-enable calldata. Leaves the controller as the dev wallet |
| 3 | `script/Step3_UpdateController.s.sol` | **Separate step, mirroring mainnet:** after the space is verified and reviewed, move the controller from the dev wallet to the Security Council multisig (`Space.transferOwnership`). No Safe tx, no module, no vote |
| 4 | `script/Step4_EnableModule.s.sol` | Decent **Vote 1**: `enableModule(strategy)`, executed by the Azorius module; then verifies the strategy and the space ↔ module wiring |
| 5 | `script/Step5_VerifyVoting.s.sol` | A real propose → vote → execute cycle that moves treasury SHU, four negative controls, and the doc's test matrix (whitelist validation, pre-vote delay, Security Council veto) |
| 6 | `script/Step6_RemoveAzorius.s.sol` | Snapshot X **Vote 2**: `swapOwner` + `disableModule` to purge Decent as both owner and module, confirms the Hats gating retires with it, then proves Snapshot X still governs |

Each step replays the ones before it, so any step can be run on its own and still
starts from a coherent state. `script/RunAll.s.sol` is Step 6 under a friendlier
name. Every step ends with a pass/fail tally and **reverts the whole run if any
check fails** — a green run means all 195 assertions held (44 / 111 / 124 / 145 / 173 / 195 cumulative).

### What each step asserts

**Step 1 — baseline + space creation (44 checks)**
Safe v1.3.0, threshold 1, sole owner *and* sole module are both the Azorius
contract, no transaction guard; Azorius `avatar`/`target` point at the Safe.
Then Decent's proposer gating (see below): both Azorius voting strategies, the
whitelisted hat id, the Hats Protocol address, the 1M SHU token threshold, the Safe
wearing the top hat, and that **all nine addresses in the doc's Snapshot X whitelist
are exactly the nine current wearers of the proposer hat**. SHU is an ERC20Votes
token on a blocknumber clock; all seven Snapshot X mainnet contracts have code.
Finally the space proxy and the execution-strategy proxy both deploy to their
predicted CREATE2 addresses, with the strategy owned by and targeting the Safe from
the moment it exists.

**Step 2 — parameters + pre-flight (67 more)**
Voting delay, min/max voting duration, `daoURI`; the OZ-Votes voting strategy and its
SHU token param; the PropositionPower validation strategy with its decoded 10M SHU
threshold; **all nine whitelist members and their 10M SHU each**; the delegation
contract (= SHU); both authenticators enabled and two others not. The strategy's
`getStrategyType`, `target`, `owner`, `quorum` and `isSpaceEnabled(space)`. The
controller is confirmed to still be the dev wallet — it is **not** moved here. Then the
module-enable calldata is printed *and decoded back out*, along with the strategy's
`setUp` parameters, the `enableModule` selector (`0x610b5925`) and its argument; plus
determinism — changing the deployer or the saltNonce changes the address.

**Step 3 — update controller (13 more)**
`Space.transferOwnership` from the dev wallet to the Security Council multisig — a
standalone step, because on mainnet the controller is only moved after the space has
been verified and reviewed. The old controller is checked to be powerless afterwards, a
third party cannot take it, and the Safe is confirmed untouched (nonce, module list and
owners all unchanged, strategy still not a module). The space controller and the
strategy's own controller (the Safe) are confirmed distinct. In attach mode, if the
handover already happened on chain the step verifies it instead of repeating it.

**Step 4 — module update (21 more)**
`enableModule` succeeds via the Azorius module; the strategy still reports
`SimpleQuorumAvatar`, `target() == owner() == Safe`, `quorum() == 30,000,000 SHU`,
`isSpaceEnabled(space) == 1` and `isSpaceEnabled(random) == 0`; the module list is
`[strategy, Azorius]` with the new module at the head; owners untouched;
`prevModule(Azorius)` recomputed live for Step 6.

**Step 5 — voting works (28 more)**
A proposal that transfers SHU out of the treasury reaches `Executed`, quorum is met,
and the payee and treasury balances both move by exactly the transfer amount.
Negative controls: a proposal with only Against votes cannot execute; a substituted
payload is rejected while the genuine one still works; a caller that is not a
whitelisted space cannot drive the strategy; the Safe still has exactly one owner and
it is a contract that cannot sign.

Then the doc's test matrix. **Whitelist validation:** member 7
(`0x302a65…3f4E`) holds no SHU and has zero delegated votes, so proposing on SHU
power alone is rejected while proposing through the whitelist succeeds — and a
non-member cannot borrow that whitelist index. **Pre-vote delay:**
`startBlockNumber == proposal block + 14400`, status is `VotingDelay`, voting is
rejected until the delay elapses and works afterwards. **Security Council veto:**
a non-controller cannot `cancel`, the controller can, the status becomes `Cancelled`,
and the vetoed proposal can never be executed.

**Step 6 — remove Azorius (22 more)**
First the `prevModule` trap is reproduced on a throwaway snapshot: with a wrong
`prevModule`, `execTransactionFromModule` returns `false` and the module stays
enabled — the silent no-op `MIGRATION.md` warns about. Then Vote 2 runs through
Snapshot X: sole owner becomes the strategy, threshold stays 1, Azorius is neither
owner nor module, and an impersonated Azorius call to `execTransactionFromModule`
now reverts. Decent's Hats gating is confirmed retired, and the hat tree confirmed
untouched. A final proposal proves Snapshot X still moves the treasury.

---

## How Decent gates proposal creation today — and what happens to it

The migration doc's last step reads *"Remove Azorius module AND the Hats module from
SD 0x36 safe"*. On-chain there is **no Hats Safe module**. At the forked block the
Safe has exactly one module and one owner, both the Azorius contract.

The Hats integration is not a module. It lives inside an Azorius **voting strategy**.
Azorius keeps a list of strategies, and each one decides for itself who may open a
proposal:

| Azorius strategy | Address | Who may propose |
|---|---|---|
| `LinearERC20VotingWithHatsProposalCreation` | `0x7FF645b8…32Edd1` | `requiredProposerWeight() == 0` — anyone **wearing the proposer hat**, no SHU needed |
| `LinearERC20Voting` | `0x4b29d8B2…db720F` | `requiredProposerWeight() == 1,000,000 SHU`, no hat |

The hats-gated one calls Hats Protocol (`0x3bc1A0Ad…dd137`) with
`isWearerOfHat(author, 0x0000004000010002…)` — tree 64, hat 64.1.2, currently worn
by **exactly the nine addresses the doc puts in the Snapshot X whitelist**. Step 1
asserts that correspondence address by address; it is the strongest evidence that
the doc's whitelist is a faithful port of today's proposer roles.

Consequences for the migration:

- **No extra Safe transaction is needed to "remove the Hats module".** Both
  strategies are only reachable through Azorius, so `disableModule(Azorius)` retires
  them. Step 6 asserts none of the three contracts is a Safe module afterwards.
- **The hat tree survives, and that is a separate decision.** Hats are objects in
  Hats Protocol, not in the Safe. The DAO Safe wears the tree's top hat, so a later
  Snapshot X proposal can retire or re-point the tree if the DAO wants — it is not
  part of this migration. Step 6 confirms the tree is untouched.
- **Worth confirming with the Security Council** what "the Hats module" in the doc
  was meant to refer to, so the final proposal is written against something that
  actually exists.

---

## Probe: what works *before* the module is enabled?

```bash
./sim.sh probe    # script/ProbeNotYetEnabled.s.sol — 54 checks
```

Deploys the space and the strategy, deliberately skips `enableModule`, and finds
that everything except the last hop works:

| Works without the module | Needs the module |
|---|---|
| All strategy reads: `getStrategyType`, `target`, `owner`, `quorum`, `isSpaceEnabled` | `execute()` — reverts `Error("GS104")` at `Safe.execTransactionFromModule` |
| `propose()`, both validation strategies: the 10M SHU threshold and the nine-address whitelist | |
| `vote()`: delegated voting power, vote tallies, double-vote and zero-power rejection | |
| The 2-day pre-vote delay | |
| The Security Council veto (`cancel`) | |
| Handing the space controller from the dev wallet to the Security Council | |
| `getProposalStatus()` reaching `VotingPeriodAccepted` / `Accepted` | |
| Authenticators, space ownership and settings | |

This is exactly the doc's *"Internal testing of Snapshot X space with SHU voting
strategy"* list, and all of it runs before the module ever touches the Safe.

### The controller handover needs no module

The doc has the space controller start as the dev wallet and later become the Security
Council multisig. That handover is `Space.transferOwnership` — OpenZeppelin `onlyOwner`,
single-step, effective immediately, and entirely inside the `Space` contract. The Safe,
Azorius and the module list play no part, so it works **before** `enableModule` and the doc's
ordering (handover, then the module proposal) is sound. The probe does the handover with no
module enabled and asserts the Safe's nonce, module list and owners are all untouched, then
exercises the Security Council veto as the new controller.

Note there are two different "controller" fields in the doc and they are not the same object:

| Doc field | Contract | Value | Changes? |
|---|---|---|---|
| *Controller* → Space controller | `Space.owner()` | dev wallet, then SC multisig | yes, by wallet tx |
| *Execution strategies* → Controller address | `AvatarExecutionStrategy.owner()` | the Safe `0x36bD…32c4` | no — set in `setUp` at creation |

Only the first one moves. The strategy's controller is the Safe from the moment it exists.

Two findings that matter for sequencing:

- **A failed `execute()` does not consume the proposal.** `Space.execute` sets
  `finalizationStatus = Executed` *before* calling the strategy, but the revert rolls
  that write back — the proposal is still `Pending` and can be retried.
- **An accepted proposal never expires.** Past `maxEndBlockNumber` the status becomes
  `Accepted`, which the Avatar strategy still executes. Unlike Azorius (21600-block
  execution period), there is no window to miss. The probe passes a proposal, waits
  past `maxEndBlockNumber`, enables the module, and executes the *same* proposal.

---

## Building the enable-module transaction

Once the real strategy exists, generate the executable `enableModule(strategy)`
transaction — the single action of Decent Vote 1 (Step 4) — as standalone files:

```bash
./sim.sh enable-tx --strategy 0xSTRATEGY [--space 0xSPACE]
# or: SNAPSHOT_X_STRATEGY=0x… forge script script/BuildEnableModuleTx.s.sol
```

`script/BuildEnableModuleTx.s.sol` first **verifies the strategy on a fork** — type
`SimpleQuorumAvatar`, `owner == target == Safe`, not already a module, and (with
`--space`) that it whitelists the space. Those are safety properties and **block**
emission if any fails; `quorum()` is reported but not blocking. Then it writes three
files under `./sim`:

| File | Contents |
|---|---|
| `enableModule.calldata.txt` | the raw `0x610b5925…` calldata, one line |
| `enableModule.tx.json` | the full transaction (to / value / operation / data / selector) |
| `enableModule.safe-batch.json` | a Safe Transaction Builder batch, importable into the Safe / Zodiac app |

The transaction is a **self-call on the Safe** (`to == the Safe`) and must be
executed with `msg.sender == the Safe`, i.e. as the action of a passed Decent
proposal (`execTransactionFromModule`). The calldata is verified to match
`cast calldata "enableModule(address)" <strategy>`.

---

## Execution matrix: what the module can do

```bash
./sim.sh exec-matrix --space 0xSPACE --strategy 0xSTRATEGY
```

Once the strategy is enabled as a module, this proves the treasury operations a real
DAO actually performs, beyond the single SHU transfer Step 5 covers. Runs against the
live module (attach) or a fresh one (it inherits through Step 4, which enables it).

**Treasury execution coverage:**
1. **Native ETH transfer** (`value > 0`) — moves ETH out of the Safe.
2. **Multi-action proposal** — several actions executed atomically from one vote.
3. **DelegateCall batch via MultiSendCallOnly** (`operation = 1`) — the delegatecall
   path real Safe tooling uses; nothing else in the harness exercised it.
4. **Atomic failure** — a proposal whose action reverts reverts the whole `execute`
   (`ExecutionFailed`); the good action rolls back too and the proposal stays `Pending`
   (retriable).
5. **Permissionless execution** — any address (not just proposer/voter) can execute a
   passed proposal.

**Governance administering itself** (each change is made *and reversed* by governance):
6. **DAO retunes its own strategy** — a proposal calls `strategy.setQuorum` (owner = the
   Safe); a non-owner's call reverts; a second proposal restores it.
7. **DAO reconfigures the Safe** — proposals add/remove a Safe owner and set/clear a
   transaction guard; and the guard is shown **not** to gate module execution (in Safe
   v1.3.0 a tx guard hooks `execTransaction`, not `execTransactionFromModule`).
8. **Security Council `updateSettings`** — the controller changes a live space setting
   (voting delay); a non-controller's call reverts; then it is restored.

All of it runs on a throwaway fork and leaves governance parameters as it found them.

## Attach mode: running a step against the real space

By default Step 1 creates the space, and each later step replays the ones before it
so that `space` and `strategy` are set. Once the space exists on chain that replay is
neither possible nor wanted — you want to run one step against the **real** addresses.

Set `SNAPSHOT_X_SPACE` and `SNAPSHOT_X_STRATEGY` (or pass `--space` / `--strategy` to
`sim.sh`) and Step 1's creation is replaced by an adoption of those addresses:

```bash
./sim.sh 2 --space 0xSPACE --strategy 0xSTRATEGY
SNAPSHOT_X_SPACE=0x… SNAPSHOT_X_STRATEGY=0x… ./sim.sh 4
```

Find the strategy address from the space-create transaction:

```bash
./snapx-strategy.sh from-tx <SPACE_CREATE_TX> --space <SPACE>
```

Everything still runs on a fresh in-memory mainnet fork, so nothing is broadcast and
the real DAO is never touched. Pin `FORK_BLOCK` to rehearse against a specific block.

### Running the whole test suite

Because the strategy is now enabled as a module on mainnet, run the `forge test` suite
in **attach mode** against the real deployment (no archive node needed):

```bash
./sim.sh test --space 0xSPACE --strategy 0xSTRATEGY
# or: SNAPSHOT_X_SPACE=0x… SNAPSHOT_X_STRATEGY=0x… forge test
```

The fresh, create-from-scratch mode (`forge test` with no addresses) only starts from a
pristine Safe *before* the module was enabled — to use it now, pin `FORK_BLOCK` to a
pre-migration block (the module was enabled at block 25974587) with an archive RPC.

The verification asserts the deployment against the doc's expected parameters, which are
the built-in defaults — so a space created to the doc verifies with **no overrides**:

```bash
./sim.sh 2 --space 0xSPACE --strategy 0xSTRATEGY
```

Only pass an env override if your deployment deliberately differs from the doc (e.g.
`QUORUM=…` for a different quorum). A mismatch is then a finding, not a harness bug: it
means the deployed value differs from the doc, and you should reconcile which is intended.
Two doc facts the defaults already encode: the quorum is 30,000,000 SHU (accepted with
snapshot.box's float-storage rounding), and the doc specifies no `daoURI` (default empty).

**Nothing is weakened.** Every check that describes the *space, strategy or migration
outcome* runs identically in both modes. The only assertions that differ are the ones
that describe the **pristine starting state** — "Azorius is the only module", "the
strategy is not a module yet", "the space is at its predicted CREATE2 address",
"the controller is still the deploying wallet". Those are facts about a run that
begins at block zero of the migration; against a real, possibly part-migrated
deployment they would be wrong, so in attach mode they are replaced by the assertion
that is correct there (for example `Azorius still enabled` instead of
`module count == 1`), and the current state is printed instead. In the default mode
they are unchanged.

The mutating steps are idempotent, so a step can be re-run after the real transaction
has landed:

| Situation | Behaviour |
|---|---|
| Controller already the Security Council | Step 3 verifies it instead of transferring |
| `enableModule` already executed | Step 4 verifies it instead of re-running Vote 1 |
| Module already enabled | The probe stops with a clear message — its premise is gone |

Validated end to end: the space and strategy were deployed onto a persistent anvil
mainnet fork, then Steps 2–5 were each run **individually** against them
(each with zero failures), then the controller handover and `enableModule` were
executed on that chain and the steps re-run against the part-migrated state (again
zero failures, with Step 3 reporting "already handed over" and Step 4 "enableModule
already executed on chain").

---

## Azorius neutralization check

```bash
./sim.sh azorius    # script/AzoriusNeutralized.s.sol
```

Runs the full migration on a fork (Steps 1-6, which remove Azorius as both module and
owner) and then proves the dead Azorius module can do **nothing**. It impersonates Azorius
and, for each attempt, asserts the call reverts:

| Attempt (as the Azorius module) | Result |
|---|---|
| `execTransactionFromModule` move SHU / move ETH | reverts (GS104) |
| `enableModule(attacker)` — re-arm a module | reverts |
| `enableModule(Azorius)` — re-enable itself | reverts |
| `addOwnerWithThreshold(attacker,1)` — grab an owner seat | reverts |
| `swapOwner(…, strategy, Azorius)` — put itself back as owner | reverts |
| `setGuard(attacker)` — install a guard | reverts |
| `DELEGATECALL` into attacker code (the most dangerous op) | reverts |
| `execTransactionFromModuleReturnData(…)` | reverts |
| `Azorius.executeProposal(…)` — its own execution entrypoint | reverts |

Then it confirms the Safe is byte-for-byte untouched (balances, module list, owners,
threshold, guard) and runs a **positive control** — a real Snapshot X proposal that moves
the treasury — so the reverts are because Azorius is deauthorized, not because the Safe is
frozen. Works in attach mode too (`--space … --strategy …`), running the whole migration on
the fork before the battery.

The key fact it demonstrates: even a *passed* Azorius proposal could never execute, because
every path Azorius has to the Safe (`execTransactionFromModule`, and therefore
`executeProposal`) reverts once the module is disabled.

---

## Parameters vs the migration doc

Everything below is taken from **`SD 0x36_Snapshot X`** and asserted by Steps 1-2.

| Doc field | Value | Where it lives |
|---|---|---|
| Network | Ethereum | fork chain id 1 |
| Voting strategy | ERC-20 Votes (EIP-5805), SHU, 18 dp | `OZVotesVotingStrategy`, params = 20-byte SHU address |
| Proposal threshold | 10,000,000 SHU | `PropositionPower` params |
| Validation strategy 1 | Voting power (ERC-20 Votes) | allowed strategy index 0 |
| Validation strategy 2 | Whitelist, 9 addresses @ 10M SHU | allowed index 1, `MerkleWhitelistVotingStrategy` (UI default; root over the 9 members) |
| Delegation contract | `0xe485…83Fd7` (= SHU) | native ERC20Votes; read by the voting strategy |
| Execution strategy | Safe module (Zodiac) | `AvatarExecutionStrategy` |
| Controller address | `0x36bD…32c4` (the Safe) | strategy `owner()` |
| Quorum | 30,000,000 SHU | strategy `quorum()` |
| Safe address | `0x36bD…32c4` | strategy `target()` |
| Authenticators | Ethereum transaction + signature | `EthTxAuthenticator`, `EthSigAuthenticator` |
| Voting delay | 2D 0H 0M | `votingDelay = 14400` blocks |
| Min voting duration | 3D 0H 0M | `minVotingDuration = 21600` blocks |
| Max voting duration | 3D 0H 0M | `maxVotingDuration = 21600` blocks |
| Space controller | dev address, then `0x3ea731…c0C0` | Step 3 hands it over |
| daoURI / metadataURI | not specified by the doc | default empty; daoURI verified, metadataURI not stored on chain |

### Judgement calls and open questions

- **Days → blocks.** The doc states durations in days; Snapshot X on mainnet counts
  in blocks. Converted at 12s/block (2d = 14400, 3d = 21600), consistent with
  Azorius's own 14400-block ≈ 2d timelock and its 21600-block voting period. Confirm
  against what snapshot.box actually writes when the space is created — override with
  `VOTING_DELAY` etc.
- **`min == max` voting duration.** Both are 3 days, so `minEndBlockNumber ==
  maxEndBlockNumber`: a proposal is never executable early, only after the full
  3 days. That matches the doc's "Timelock after pass: 0D 0H 0M".
- **The Hats module.** See the section above: there is nothing to remove from the
  Safe's module list, and the hat tree is a separate decision.
- **Security Council veto** is `Space.cancel(proposalId)`, gated on the space
  controller. That gives the doc's window: any time from proposal creation until
  execution, i.e. the 2-day delay plus the 3-day vote. Exercised in Step 5c.
- **Quorum (30,000,000 SHU) and threshold (10,000,000 SHU)** are both straight from the
  doc. snapshot.box stores the quorum as `float64(30000000 * 1e18)`, so the on-chain value
  is `30000000000000000570425344` — the intended 30M SHU plus ~5.7e-10 SHU of float dust.
  The harness's quorum check accepts that sub-ULP rounding (and nothing larger), so a real
  UI space verifies without pasting the exact number.
- **Delegation.** The doc's *Delegation contract address* `0xe485…83Fd7` is the **SHU token
  itself** — delegation type is *ERC-20 Votes*, so delegation is native to the token and is
  not a separate contract or a `Space.initialize` parameter. On-chain it is already the token
  the voting strategy reads via `getPastVotes`; Step 2 asserts the doc's delegation address
  equals SHU equals the voting-strategy token, and Step 5 exercises it (voters `delegate()`
  and their `getVotes` power carries the vote). The rest of the doc's DELEGATIONS section
  (API name, type, subgraph URL) is off-chain snapshot.box metadata.
- **The whitelist is a merkle tree.** The snapshot.box UI deploys
  `MerkleWhitelistVotingStrategy` (`0x34f0…`), which stores only a merkle **root** on
  chain (not the 9 members). Step 2 reconstructs the OZ `StandardMerkleTree` root from the
  nine doc addresses at 10M SHU and asserts it equals the on-chain root — a cryptographic
  proof the whitelist commits to exactly those members. `src/Merkle.sol` implements the
  tree; `test/Merkle.t.sol` locks it to the real Shutter DAO 0x36 space's on-chain root
  `0x3be9…cf01`. The plain `WhitelistVotingStrategy` (member array) is still accepted if a
  space uses it.
- **Off-chain profile fields** (name, image, description, socials, treasury entry,
  delegation API name / URL / type) are snapshot.box metadata and have no on-chain effect, so
  the harness does not model them beyond `metadataURI` / `daoURI`.

---

## Addresses used

DAO values were read from mainnet (`MIGRATION.md` §1). Snapshot X values come from
[`snapshot-labs/sx-evm` `deployments/ethereum.json`](https://github.com/snapshot-labs/sx-evm/blob/main/deployments/ethereum.json).

| Label | Address |
|---|---|
| DAO Safe / treasury / avatar / target | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |
| Decent (Azorius) module — removed in Step 6 | `0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e` |
| Azorius freeze guard | `0xB04f553c482063a99B10C55033b56BD50b6B0334` |
| Azorius strategy — hats-gated proposal creation | `0x7FF645b803FF3Bc890e3568B503BC1F37d32Edd1` |
| Azorius strategy — 1M SHU proposal creation | `0x4b29d8B250B8b442ECfCd3a4e3D91933d2db720F` |
| Hats Protocol v1 | `0x3bc1A0Ad72417f2d411118085256fC53CBdDd137` |
| Security Council multisig / space controller | `0x3ea731dAF66D6A7980549f90152CD9A761B9c0C0` |
| SHU (ERC20Votes) | `0xe485E2f1bab389C08721B291f6b59780feC83Fd7` |
| sx-evm `ProxyFactory` | `0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c` |
| sx-evm `SpaceImplementation` | `0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D` |
| sx-evm `AvatarExecutionStrategyImplementation` | `0xecE4f6b01a2d7FF5A9765cA44162D453fC455e42` |
| sx-evm `OZVotesVotingStrategy` | `0x2c8631584474E750CEdF2Fb6A904f2e84777Aefe` |
| sx-evm `WhitelistVotingStrategy` | `0x3CEE21A33751A2722413fF62dEC3dEc48e7748A4` |
| sx-evm `EthTxAuthenticator` | `0xBA06E6cCb877C332181A6867c05c8b746A21Aed1` |
| sx-evm `EthSigAuthenticator` | `0x95CF9B585fDb12DeB78002B5643dFF8fe67a496D` |
| sx-evm `PropositionPowerProposalValidationStrategy` | `0x6D9d6D08EF6b26348Bd18F1FC8D953696b7cf311` |

Proposer hat: `0x0000004000010002000000000000000000000000000000000000000000000000`
(tree 64, hat 64.1.2). All of these live in `src/Config.sol`.

---

## Design notes

**The execution strategy is deployed with the space, never later.** snapshot.box
deploys the space proxy *and* the execution-strategy proxy in the same "Create" flow
— the doc's *Sign Transactions* section: *"you will have to sign multiple
transactions… Space contract; Execution strategy contracts."* Step 1 does exactly
that. `setUp` sets `owner = target = the Safe`, so the Safe controls the strategy
from the moment it exists, whoever paid the gas. The only thing outstanding
afterwards is `enableModule`, which is a separate vote that simply uses the recorded
address.

**There is no on-chain "add the strategy to the space".** The Space contract keeps
no execution-strategy whitelist; the strategy is named per proposal. The only
on-chain link runs the other way: the strategy whitelists which spaces may call
`execute`, via `_spaces` in `setUp` (or `enableSpace`, which is `onlyOwner` = the
Safe = another vote). Step 1 sets `_spaces = [space]` at deploy time and Step 2
verifies `isSpaceEnabled(space) == 1`. Any "add execution strategy" action in the
snapshot.box UI is space metadata, not a Safe transaction.

**Why the strategy also becomes the Safe owner.** Azorius is currently both the only
module and the only owner. Removing it as a module would leave a dead, non-signing
owner behind, so Vote 2 swaps it for the strategy. This mirrors today's layout and
keeps the treasury module-only with no multisig backdoor; being an owner grants no
execution power by itself, since execution goes through
`execTransactionFromModule`.

**Never trust transaction success alone.** `execTransactionFromModule` swallows
inner reverts and returns `false`. Every step here checks the return value *and*
re-reads the resulting state (`isModuleEnabled`, `getOwners`,
`getModulesPaginated`), and Step 6 reproduces the failure mode explicitly.

---

## What is *not* simulated

- **The Decent vote itself.** Step 4 impersonates the Azorius module and calls
  `Safe.execTransactionFromModule` — exactly what `Azorius.executeProposal` does
  once a proposal has passed and its timelock (14400 blocks) has elapsed. Proposal
  submission, the two linear ERC20 voting strategies, the timelock and the execution
  window are not modelled.
- **The Security Council freeze guard** (`0xB04f553c…`). Impersonating the module
  bypasses it. Its interaction with the migration window is an open item in
  `MIGRATION.md` §8.
- **Off-chain snapshot.box state.** Space profile, metadata pinning, and whether
  the snapshot.box indexer picks up a space created outside its own flow.
- **The real electorate.** Step 5 funds two throwaway addresses out of the treasury
  and self-delegates so there is enough proposition power to open a proposal. Those
  transfers are labelled `[sim-only]` in the output and are excluded from the
  treasury-delta assertions.

---

## Layout

```
src/Config.sol                   every fixed address, in one place
src/interfaces/ISnapshotX.sol    ABI-exact mirror of the sx-evm types we touch
src/interfaces/ISafe.sol         Safe v1.3.0, SHU, Azorius, Hats (read-only)
script/SimBase.s.sol             fork setup, calldata builders, both execution
                                 paths, the doc test matrix, the assertion tally
script/Step1..Step6              the six steps; each inherits the previous
script/ProbeNotYetEnabled.s.sol  what works before the module is enabled
script/ExecMatrix.s.sol          ETH/batch/delegatecall/failure/perm-exec + gov admin
script/RunAll.s.sol              all five
test/Migration.t.sol             every step + probe/azorius/exec-matrix, as forge tests
sim.sh                           driver
sim/state.json                   output: addresses + production calldata
```

Related: [`MIGRATION.md`](./MIGRATION.md) (findings and the production plan) and
[`snapx-strategy.sh`](./snapx-strategy.sh) (read-only verification of a *live*
strategy address, once one exists on mainnet).

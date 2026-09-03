# Shutter DAO 0x36 — Governance Migration: Decent → Snapshot X

Working notes, on-chain findings, transaction construction, simulation results, and
verification procedure for migrating Shutter DAO 0x36 governance from **Decent
(Azorius/Zodiac)** to **Snapshot X**.

> Source of truth for parameters: `SD 0x36_Snapshot X` migration doc (the PDF).
> All on-chain facts below were read from Ethereum mainnet and are reproducible with
> the commands shown.

---

## 0. TL;DR

- "Decent" = an **Azorius Zodiac module** at `0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e`,
  attached to the DAO Safe `0x36bD3044ab68f600f6d3e081056F34f2a58432c4`. On this Safe the
  Azorius contract is registered **both as the only module AND as the only owner** — so
  fully removing Decent means removing **both** references.
- Governance runs **only** through the module: the sole owner is a contract that can't sign,
  so `execTransaction` by owners is unusable. Every Safe state change is executed by a passed
  proposal (Decent now, Snapshot X after migration).
- **The execution strategy is deployed with the space, never later.** snapshot.box deploys
  the space proxy *and* the execution-strategy proxy in the same "Create" flow (the doc's
  *Sign Transactions* section). `setUp` sets `owner = target = the Safe`, so the Safe controls
  the strategy from the moment it exists, whoever paid the gas. The address is read back from
  the `ProxyDeployed` event and used in the module vote. See §3.5.
- **Two votes:**
  - **Vote 1 (via Decent):** `enableModule(SNAPSHOT_X_STRATEGY)` — one action. Then test.
  - **Vote 2 (via Snapshot X, after testing):** `swapOwner(Azorius → SNAPSHOT_X_STRATEGY)` + `disableModule(prevModule, Azorius)`. Purges Decent as owner *and* module.
- **Proposal creation is gated by Azorius *voting strategies*, not by a Safe module.** One is
  hats-gated (zero SHU, must wear the proposer hat), one needs 1M SHU. Both are only reachable
  through Azorius, so they retire with it — there is no separate "Hats module" to remove.
  See §1.5.
- **The strategy is a Zodiac *module*, never a Safe *owner* for execution purposes.**
  Snapshot X executes via `execTransactionFromModule` (modules bypass owners entirely).
  Setting the strategy as the *owner* is a deliberate **cleanup** choice (mirrors today's
  "governance module is also owner" pattern, keeps treasury module-only with no multisig
  backdoor) — it grants no execution power by itself.

---

## 1. Verified on-chain state (mainnet)

RPC used: `https://ethereum-rpc.publicnode.com` (any mainnet RPC works).

| Entity | Address / value | Source call |
|---|---|---|
| DAO Safe (treasury, target, controller) | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` | — |
| Safe version | `1.3.0` | `VERSION()` |
| Safe threshold | `1` | `getThreshold()` |
| Safe owner(s) | `[0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e]` (the Azorius module itself) | `getOwners()` |
| Enabled module(s) | `[0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e]` (only one) | `getModulesPaginated(0x1,10)` |
| Safe transaction guard | none (storage slot is zero) | `cast storage` at guard slot |
| Decent module type | EIP-1167 proxy → impl `0xd16368…`; `avatar()==target()==Safe` | `avatar()`, `target()` |
| Decent timelock / execution period | `14400` blocks (~2d) / `21600` blocks (~3d) | `timelockPeriod()`, `executionPeriod()` |
| Decent proposals so far | `177` | `totalProposalCount()` |
| Azorius freeze guard | `0xB04f553c482063a99B10C55033b56BD50b6B0334`, `owner()==0x3ea731…` (Security Council) | `getGuard()` |
| Azorius voting strategies (see §1.5) | `0x7FF645b803FF3Bc890e3568B503BC1F37d32Edd1` (hats-gated), `0x4b29d8B250B8b442ECfCd3a4e3D91933d2db720F` (1M SHU) | `getStrategies(0x1,10)` |
| SHU token | `0xe485E2f1bab389C08721B291f6b59780feC83Fd7`, symbol `SHU`, 18 dp | `symbol()`, `decimals()` |

Reproduce, e.g.:

```bash
RPC=https://ethereum-rpc.publicnode.com
SAFE=0x36bD3044ab68f600f6d3e081056F34f2a58432c4
cast call $SAFE "getModulesPaginated(address,uint256)(address[],address)" \
  0x0000000000000000000000000000000000000001 10 --rpc-url $RPC
```

**Implication:** the Safe is governed *exclusively* through the Azorius module. The single
owner is a contract that can't produce an ECDSA signature, so `execTransaction` by owners
is not a usable path. Every state change (including this migration) routes through a
Decent/Azorius proposal whose execution calls the Safe.

---

## 1.5 How Decent gates proposal creation (the "Hats module" question)

The doc's final step says *"Remove Azorius module AND the Hats module from SD 0x36 safe"*.
There is **no Hats Safe module**. The Safe has exactly one module and one owner, both the
Azorius contract.

Proposal-creation access control lives inside Azorius's **voting strategies**. Azorius keeps
a list of them (`getStrategies`), and each strategy decides for itself who may open a
proposal:

| Strategy | Address | Implementation | Who may propose |
|---|---|---|---|
| hats-gated | `0x7FF645b803FF3Bc890e3568B503BC1F37d32Edd1` | `LinearERC20VotingWithHatsProposalCreation` | `requiredProposerWeight() == 0`; author must wear the proposer hat |
| token-gated | `0x4b29d8B250B8b442ECfCd3a4e3D91933d2db720F` | `LinearERC20Voting` | `requiredProposerWeight() == 1,000,000 SHU` |

Both share `votingPeriod = 21600` blocks (~3d), `quorumNumerator = 30000`,
`basisNumerator = 500000`, `governanceToken = SHU`, `owner = the Safe`.

The hats-gated strategy calls Hats Protocol `0x3bc1A0Ad72417f2d411118085256fC53CBdDd137`:

```bash
cast call 0x7FF645b803FF3Bc890e3568B503BC1F37d32Edd1 "getWhitelistedHatIds()(uint256[])" --rpc-url $RPC
# -> [0x0000004000010002000000000000000000000000000000000000000000000000]   (tree 64, hat 64.1.2)
cast call 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137 "viewHat(uint256)(string,uint32,uint32,address,address,string,uint16,bool,bool)" \
  0x0000004000010002000000000000000000000000000000000000000000000000 --rpc-url $RPC
# -> maxSupply 100, supply 9, active true
```

**The nine wearers of that hat are exactly the nine addresses the migration doc puts in the
Snapshot X whitelist** (proposal validation strategy 2, 10M SHU each). Verified wearer by
wearer in Step 1 of the simulation. The doc's whitelist is therefore a faithful port of
today's proposer roles.

Consequences:

- **Nothing extra to remove.** Both strategies are only reachable through Azorius;
  `disableModule(Azorius)` retires them. No `disableModule` call exists for them because they
  were never modules.
- **The hat tree survives.** Hats are objects in Hats Protocol, not in the Safe. The DAO Safe
  wears the tree's **top hat** (`0x00000040000…`), so a later Snapshot X proposal can retire
  or re-point the tree if the DAO wants. Out of scope for this migration.
- **Confirm with the Security Council** what "the Hats module" was meant to refer to, so the
  final proposal targets something that exists.

---

## 2. Migration process (from the doc) and what is on-chain vs off-chain

| Step | Doc says | On-chain? |
|---|---|---|
| 1 | Create a Snapshot X space at `snapshot.box/#/create/snapshot-x` | Yes — deploys the space proxy **and** the execution-strategy proxy, both signed by the creating wallet (this is where `SNAPSHOT_X_STRATEGY` is born; §3.5) |
| 2 | Add the Snapshot X Safe module via Zodiac Safe App | **Yes — TX 1: `enableModule`** |
| 3 | Test Snapshot X end-to-end | A real proposal/vote/execute through the new module |
| 4 | Remove the Decent Safe module via Zodiac Safe App | **Yes — TX 2: `disableModule`** |

Everything in the doc's *Profile / Strategies / Voting / Controller* sections is **off-chain
space configuration** entered into the snapshot.box form. The only Safe mutations are TX 1
and TX 2.

---

## 3. The two transactions

Both target the Safe and are executed **with `msg.sender == the Safe`** (the Safe's
ModuleManager only lets the Safe modify its own module list). In production that means the
calldata below is wrapped as the action(s) of a Decent proposal; on execution the Azorius
module calls the Safe via `execTransactionFromModule`.

### TX 1 — enable Snapshot X strategy

```
to:        0x36bD3044ab68f600f6d3e081056F34f2a58432c4   (the Safe)
value:     0
operation: 0 (CALL)
function:  enableModule(address module)
selector:  0x610b5925
data:      0x610b5925 000000000000000000000000<SNAPSHOT_X_STRATEGY>
```

Build it: `cast calldata "enableModule(address)" <SNAPSHOT_X_STRATEGY>`

### TX 2 — disable Decent module

```
to:        0x36bD3044ab68f600f6d3e081056F34f2a58432c4   (the Safe)
value:     0
operation: 0 (CALL)
function:  disableModule(address prevModule, address module)
selector:  0xe009cfde
data:      0xe009cfde <prevModule> <0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e>
```

Build it: `cast calldata "disableModule(address,address)" <prevModule> 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e`

#### The `prevModule` trap (read this before signing TX 2)

The Safe stores modules as a **linked list** `SENTINEL(0x1) → … → SENTINEL`. `disableModule`
needs the entry **pointing at** the module you remove. New modules are inserted at the
**head**. So:

- If you removed Decent **today** (Decent is the only module): `prevModule = 0x0000…0001`.
- After TX 1 the list is `SENTINEL → SnapshotX → Decent → SENTINEL`, so when TX 2 runs
  (the doc's order: enable, test, then remove): **`prevModule = SNAPSHOT_X_STRATEGY`**.

Always recompute `prevModule` from the live list at execution time:

```bash
cast call 0x36bD3044ab68f600f6d3e081056F34f2a58432c4 \
  "getModulesPaginated(address,uint256)(address[],address)" \
  0x0000000000000000000000000000000000000001 10 --rpc-url $RPC
# prevModule = the element listed immediately BEFORE Decent
# (if Decent is first in the array, prevModule = 0x...0001)
```

**Silent-failure warning:** when executed via `execTransactionFromModule`, a wrong
`prevModule` makes the inner `disableModule` revert but the **outer transaction still
returns success** — the module is simply *not* removed. Never trust tx success alone;
confirm with `isModuleEnabled` (below).

### TX 3 — swap the Safe owner (full Decent decommission)

Azorius is also the Safe's sole owner. After it is no longer the module it remains a dead,
non-signing owner, so we replace it. **Chosen new owner: the Snapshot X strategy** (mirrors
the current "module is also owner" pattern; keeps the treasury module-only with no multisig
backdoor). Owners are a sentinel-linked list exactly like modules.

```
to:        0x36bD3044ab68f600f6d3e081056F34f2a58432c4   (the Safe)
value:     0
operation: 0 (CALL)
function:  swapOwner(address prevOwner, address oldOwner, address newOwner)
data:      swapOwner(0x0000…0001, 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e, SNAPSHOT_X_STRATEGY)
```

Build it: `cast calldata "swapOwner(address,address,address)" 0x0000000000000000000000000000000000000001 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e <SNAPSHOT_X_STRATEGY>`

Single owner ⇒ `prevOwner = SENTINEL (0x..01)`. Keeps owner-count 1 / threshold 1. Pre-reqs
enforced by the Safe: `newOwner` must not already be an owner, `oldOwner` must be the current
owner, and `owners[prevOwner] == oldOwner`.

---

## 3.5 Where the execution strategy comes from

**The strategy is deployed with the space, in the same snapshot.box "Create" flow, and never
later.** The doc's *Sign Transactions* section: *"You will have to sign multiple transactions,
each for individual contracts to be deployed: Space contract; Execution strategy contracts —
each space has its execution strategy deployed as an individual contract."*

`ProxyFactory.deployProxy` is called twice by the creating wallet — once for the `Space`
implementation, once for `AvatarExecutionStrategy`. The strategy's `setUp` receives
`(owner = Safe, target = Safe, spaces = [space], quorum = 30,000,000 SHU)`, so **the Safe owns and
targets the strategy from the moment it exists**, regardless of who paid the gas. The creating
wallet keeps no power over it.

You then read the strategy address out of the create transaction (`ProxyDeployed`, or the
space's settings page) and use it in the `enableModule` proposal. Nothing has to be atomic:
enabling the module is a separate, later vote in the doc's process, and by then the address is
simply known.

> An earlier revision of this document recommended deploying the strategy *inside* the Decent
> proposal, so that `msg.sender == Safe` and the address was pre-computable before anything was
> signed. That is unnecessary given the sequencing above, and it deviates from the doc. It is
> no longer the plan.

### There is no "add the strategy to the space" transaction

The `Space` contract keeps **no execution-strategy whitelist** — the strategy is named
per-proposal in `propose(author, metadataURI, Strategy executionStrategy, …)`. The only
on-chain link runs one way: the **strategy** whitelists which **spaces** may call `execute`,
via `_spaces` in `setUp`, or later `enableSpace(space)` which is `onlyOwner` (= the Safe → a
vote). Setting `_spaces = [space]` at creation closes it. Any "execution strategies" list in
the snapshot.box UI is space metadata, not a Safe transaction.

### Encoding note

`initializer` is the **full `setUp(bytes)` calldata** — the `setUp` selector plus
`abi.encode(bytes initParams)`, where `initParams = abi.encode(owner, target, spaces[], quorum)`
(nested encoding). `script/SimBase.s.sol` builds exactly these bytes and Step 2 decodes them
back out.

### Vote 1 (executed by Decent) — one action

```
Safe.enableModule(SNAPSHOT_X_STRATEGY)
```

### Vote 2 — purge Decent

Run **via Snapshot X** after step-3 testing (the executor isn't being removed, so order is
free, and it doubles as the end-to-end proof the new governance can move the treasury):

```
tx[0]  Safe.swapOwner(0x..01, Azorius, SNAPSHOT_X_STRATEGY)
tx[1]  Safe.disableModule(prevModule = SNAPSHOT_X_STRATEGY, Azorius)   // SnapX is list head
```

If instead run **via Decent**, `disableModule(Azorius)` **must be the last tx** — once Decent
disables its own module it cannot execute any remaining tx in the same batch (the whole
proposal would revert). Order: `swapOwner` first, `disableModule(Azorius)` last.

---

## 4. Simulation (mainnet fork) — performed, passed

> **Superseded by the Foundry harness.** The six-step, fully-asserted version of this
> simulation now lives in `script/Step1..Step6` — see [README.md](./README.md). It deploys a
> real Snapshot X space and execution strategy on a mainnet fork, runs both votes against the
> doc's parameters, and checks 195 assertions. The hand-run results below are kept for the
> record; note they predate the current plan (they used a placeholder strategy address and a
> two-action Vote 1).

Method: `anvil --fork-url <mainnet>`, impersonate the Azorius module, and execute the exact
production path `Safe.execTransactionFromModule(Safe, 0, <calldata>, 0)`. Placeholder
`SNAPSHOT_X_STRATEGY = 0x1111…1111`.

```
BEFORE:  getModulesPaginated => [Decent]
TX1 enableModule(SnapX)            => status 0x1, gas 61,730
        => modules [SnapX, Decent]   isModuleEnabled(SnapX)=true
TX2 disableModule(SnapX, Decent)   => status 0x1, gas 38,269
        => modules [SnapX]           isModuleEnabled(Decent)=false   ✅
```

Negative control (clean fork, only Decent enabled):

```
disableModule(0x2222…2222 /*wrong prev*/, Decent) => tx status 0x1 BUT module still enabled (silent no-op)
disableModule(0x0000…0001 /*sentinel  */, Decent) => module removed ✅
```

This confirms (a) the calldata/selectors, (b) the `prevModule` ordering, and (c) the
silent-failure behaviour. Re-run on a fork before the real proposal once you have the real
strategy address.

> Note: a follow-up re-run was blocked by a sandbox network-proxy change mid-session; the
> results above are from the live run earlier in the same session.

---

## 5. Where `SNAPSHOT_X_STRATEGY` comes from, and what changes it

Snapshot X spaces and their execution strategies are deployed by **`ProxyFactory.deployProxy`**
(`snapshot-labs/sx-evm`) as ERC-1967 proxies via **CREATE2**:

```solidity
function deployProxy(address implementation, bytes initializer, uint256 saltNonce) {
    bytes32 salt = keccak256(abi.encodePacked(msg.sender, saltNonce));   // deployer + nonce ONLY
    address proxy = new ERC1967Proxy{ salt: salt }(implementation, "");
    proxy.call(initializer);                                             // params applied AFTER deploy
    emit ProxyDeployed(implementation, proxy);
}
// addr = keccak256(0xff ++ factory ++ salt ++ keccak256(proxyCreationCode ++ abi.encode(impl,"")))[12:]
```

So the deployed address depends on **exactly four inputs**:

| Input | Determined by | Changes the address? |
|---|---|---|
| `factory` | Snapshot X deployment on the chain | per-network constant |
| `implementation` | Snapshot X `AvatarExecutionStrategy` master copy | yes, if Snapshot X upgrades it |
| `msg.sender` | **the wallet that signs "Create"** (the deployer) | **yes** |
| `saltNonce` | chosen by the snapshot.box frontend at click-time | **yes** (every attempt differs) |

**The strategy's config does NOT affect its address.** `owner/controller`, `target/safe`,
`quorum`, and the whitelisted `spaces` are applied in the post-deploy `setUp(initializer)`
call (verified in `AvatarExecutionStrategy.sol`). They determine whether the strategy *works*,
not where it lives.

### What hampers / changes it (mapped to the doc)

- **Who signs "Create".** The doc says the space controller is the dev wallet at creation and
  is then handed to the Security Council multisig `0x3ea731dAF66D6A7980549f90152CD9A761B9c0C0`.
  The **addresses are salted by the wallet that actually signs**, i.e. the dev wallet, for both
  the space and the strategy. Different signer → different addresses. Decide and record the
  deployer. Because the frontend picks `saltNonce` at click-time, don't try to pre-commit the
  address — read it from `ProxyDeployed` afterwards (below), then verify it.
- **Retries / multiple signatures.** The doc warns you sign several txs (space + each strategy).
  A fresh deploy uses a new `saltNonce` → different address. Reusing `(sender, saltNonce)`
  reverts `SaltAlreadyUsed`; a bad initializer reverts the whole deploy `FailedInitialization`
  (so a half-failed create yields *no* address — start over).
- **Network.** Doc says Ethereum. Other chain → different factory → different address.
- **Implementation version bump** by Snapshot X → different address for new deploys.
- **Config that must be right but doesn't move the address** (in `setUp`): controller
  `0x36bD…58432c4`, target/safe `0x36bD…58432c4`, quorum `30000000000000000000000000` (30M SHU), and the
  **space must be whitelisted** (`isSpaceEnabled(space) == 1`, set at deploy or via
  `enableSpace`) or proposals can't execute.

### Three ways to obtain the address

1. **UI:** space *Settings → Execution strategies* page (also gives the pre-filled Zodiac
   `enableModule` link = TX 1).
2. **Deploy tx event (recommended):** read `ProxyDeployed(implementation, proxy)` from the
   create tx — `proxy` is your strategy. Both args are non-indexed (in `data`).
3. **Pre-compute:** `predictProxyAddress(implementation, keccak256(abi.encodePacked(deployer, saltNonce)))`.

---

## 6. The helper: `snapx-strategy.sh`

Read-only. Signs/sends nothing. Requires `cast` (foundry) and `python3`.

```bash
# A) After the space is created — auto-find the strategy in the deploy tx and verify it:
./snapx-strategy.sh from-tx <DEPLOY_TX_HASH> --space <SNAPSHOT_X_SPACE_ADDR>

# B) Verify a known strategy address against the doc's parameters:
./snapx-strategy.sh check <STRATEGY_ADDR> --space <SNAPSHOT_X_SPACE_ADDR>

# C) Pre-compute the CREATE2 address before deploying:
./snapx-strategy.sh predict <IMPLEMENTATION> <DEPLOYER> <SALT_NONCE> <FACTORY>

# --rpc <URL> overrides the RPC (default: $RPC_URL or a public node).
```

It asserts, against the values baked in at the top of the script (edit if the doc changes):

| Check | Getter | Expected |
|---|---|---|
| strategy type | `getStrategyType()` | `SimpleQuorumAvatar` |
| target (avatar) | `target()` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |
| owner (controller) | `owner()` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |
| quorum | `quorum()` | `30000000000000000000000000` (30,000,000 SHU) |
| space whitelisted | `isSpaceEnabled(space)` | `1` (only if `--space` given) |

On all-pass it prints the ready-to-use `enableModule(<strategy>)` calldata for TX 1.

`from-tx` collects **every** `ProxyDeployed` proxy in the create tx (a space-create emits
several: the space proxy plus one per execution strategy) and picks the one whose
`getStrategyType()` is `SimpleQuorumAvatar`.

> Validation status: bash syntax, `--help`, the `ProxyDeployed` log parser (unit-tested with
> a synthetic receipt), and the `ProxyDeployed` topic hash
> (`0x3d2489efb661e8b1c3679865db649ca1de61d76a71184a1234de2e55786a6aad`) are all verified
> offline. The live `check`/`from-tx` RPC reads use the ABI signatures confirmed against the
> `sx-evm` source; run them against a real strategy/tx when network access permits.

---

## 7. Step-by-step with verification

Mirrors the doc's *Migration Process* checklist. Everything marked *fork-test* is automated by
the Foundry harness — see [README.md](./README.md).

1. **Simulate the whole thing on a fork:** `./sim.sh` (195 assertions across 5 steps).
2. **Create the space** on snapshot.box, signed by the dev wallet. This deploys the `Space`
   proxy **and** the `AvatarExecutionStrategy` proxy. Record both addresses from the create
   transaction's `ProxyDeployed` events.
3. **Verify the parameters** against the *real* addresses. Both of these work on the live
   space, and neither touches it:
   `./sim.sh 2 --space <SPACE> --strategy <STRATEGY>` (full parameter audit on a fork), and
   `./snapx-strategy.sh from-tx <CREATE_TX> --space <SPACE>` → ALL CHECKS PASSED
   (`getStrategyType == SimpleQuorumAvatar`, `target == owner == Safe`, `quorum == 30,000,000 SHU`,
   `isSpaceEnabled(space) == 1`). Cross-check the space's voting strategy, both validation
   strategies (10M SHU threshold **and** the nine-address whitelist), authenticators, voting
   delay and durations against the doc. `./sim.sh 2` does all of this on the fork.
4. **Internal testing** while the module is still off — rehearse it first with
   `./sim.sh probe --space <SPACE> --strategy <STRATEGY>` — proposal validation, SHU voting incl.
   delegation, quorum, pre-vote delay, Security Council veto. All of it works before
   `enableModule`; only `execute()` fails, with `GS104`, and a failed `execute()` does not
   consume the proposal. `./sim.sh probe` demonstrates this.
5. **PAUSE & REVIEW.**
6. **Hand the space controller** from the dev wallet to the Security Council multisig:
   `Space.transferOwnership(0x3ea731…c0C0)`, signed by the dev wallet — a **separate step**,
   done only after the verification above is reviewed. This is OpenZeppelin `onlyOwner`,
   single-step and effective immediately; it lives entirely inside the `Space` contract, so it
   needs **no Safe transaction, no DAO vote and no module** — which is why the doc puts it
   before the module proposal. Rehearse and verify on a fork with
   `./sim.sh 3 --space <SPACE> --strategy <STRATEGY>`; check `owner()` and that the old
   controller can no longer act.

   Do not confuse this with the *Execution strategies → Controller address* field in the doc:
   that is `AvatarExecutionStrategy.owner()`, which is the Safe `0x36bD…32c4`, set in `setUp`
   at creation and never changed.
7. **Submit Vote 1 via Decent:** `enableModule(SNAPSHOT_X_STRATEGY)`. Pass, execute, then
   verify on mainnet: `isModuleEnabled(STRATEGY) == true` **and** `isModuleEnabled(Azorius)
   == true` (do not remove Decent yet).
8. **DAO testing of space + module:** a real proposal → vote → execute that moves Safe state.
   Rehearse it against the live space first: `./sim.sh 5 --space <SPACE> --strategy <STRATEGY>`.
9. **PAUSE & REVIEW.**
10. **Submit Vote 2 via Snapshot X** (rehearse with
    `./sim.sh 6 --space <SPACE> --strategy <STRATEGY>`): `swapOwner(0x..01, Azorius, STRATEGY)` +
    `disableModule(prevModule = STRATEGY, Azorius)`. **Verify on mainnet:** `getOwners()` →
    `[STRATEGY]`; `getModulesPaginated` → only `STRATEGY`; `isModuleEnabled(0xAA6BfA…)` →
    `false`. Decent is now gone as owner *and* module, and both Azorius voting strategies —
    including the hats-gated one — are unreachable (§1.5).

Always confirm post-state via `getOwners` / `isModuleEnabled` / `getModulesPaginated`, never
tx-success alone (a wrong `prevModule`/`prevOwner` silently no-ops under module execution).
Decode every calldata before signing: `cast 4byte-decode <calldata>`.

---

## 8. Open items to confirm with the Security Council before execution

- **Decisions already taken:** the strategy is deployed with the space by snapshot.box, never
  later (§3.5); new Safe owner = the Snapshot X strategy.
- **Resolved:** all mainnet Snapshot X addresses are now in §9, read from
  `snapshot-labs/sx-evm` `deployments/ethereum.json` and confirmed on-chain.
- **"Remove the Hats module".** There is no Hats Safe module (§1.5). Confirm what the doc
  meant. The hats-gated proposer strategy retires with Azorius automatically; retiring the hat
  *tree* is a separate Hats Protocol action the DAO can take later as top-hat wearer.
- **Days → blocks.** The doc gives voting delay 2D and min/max voting duration 3D. Snapshot X
  counts blocks; the harness uses 14400 / 21600 / 21600 at 12s per block. Confirm this matches
  what snapshot.box writes at create time.
- **`min == max` voting duration.** Both 3 days means a proposal is never executable early,
  only after the full 3 days — consistent with the doc's "Timelock after pass: 0D".
- **Execution path.** Owner is the Azorius contract (threshold 1) and can't sign, so all
  votes execute through a governance module (Decent for Vote 1; Snapshot X for Vote 2).
  Confirm the SC is comfortable running Vote 2 through the freshly-tested SnapX module.
- **Freeze-guard / Security-Council veto** interaction during the migration window
  (guard `0xB04f…`, owner = Security Council `0x3ea731…`).
- **Quorum:** doc quorum `30000000000000000000000000` (= 30,000,000 SHU) vs proposal
  threshold `10000000000000000000000000` (= 10M SHU). Confirmed against the deployed space.
  Note snapshot.box stores the quorum as the float64 rounding of `30000000 * 1e18`, i.e.
  `30000000000000000570425344` on chain — the same 30M SHU, off by ~5.7e-10 SHU.

---

## 9. Key addresses (quick reference)

| Label | Address |
|---|---|
| DAO Safe / treasury / controller / target | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |
| Decent (Azorius) module — **to remove** | `0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e` |
| Azorius freeze guard | `0xB04f553c482063a99B10C55033b56BD50b6B0334` |
| Azorius strategy — hats-gated proposal creation | `0x7FF645b803FF3Bc890e3568B503BC1F37d32Edd1` |
| Azorius strategy — 1M SHU proposal creation | `0x4b29d8B250B8b442ECfCd3a4e3D91933d2db720F` |
| Hats Protocol v1 | `0x3bc1A0Ad72417f2d411118085256fC53CBdDd137` |
| Proposer hat id (tree 64, hat 64.1.2) | `0x0000004000010002000000000000000000000000000000000000000000000000` |
| Security Council multisig / Snapshot X space controller | `0x3ea731dAF66D6A7980549f90152CD9A761B9c0C0` |
| SHU token (ERC-20 Votes) / delegation contract | `0xe485E2f1bab389C08721B291f6b59780feC83Fd7` |
| Snapshot X execution strategy | `TBD — born at space creation; verify with snapx-strategy.sh` |
| `WhitelistVotingStrategy` (proposal validation 2) | `0x3CEE21A33751A2722413fF62dEC3dEc48e7748A4` |
| Snapshot X `ProxyFactory` (mainnet) | `0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c` |
| `AvatarExecutionStrategy` implementation (mainnet) | `0xecE4f6b01a2d7FF5A9765cA44162D453fC455e42` |
| Snapshot X `SpaceImplementation` (mainnet) | `0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D` |
| `OZVotesVotingStrategy` (mainnet) | `0x2c8631584474E750CEdF2Fb6A904f2e84777Aefe` |
| `EthTxAuthenticator` / `EthSigAuthenticator` | `0xBA06E6cCb877C332181A6867c05c8b746A21Aed1` / `0x95CF9B585fDb12DeB78002B5643dFF8fe67a496D` |
| `PropositionPowerProposalValidationStrategy` | `0x6D9d6D08EF6b26348Bd18F1FC8D953696b7cf311` |
| `enableModule(address)` selector | `0x610b5925` |
| `disableModule(address,address)` selector | `0xe009cfde` |
| `swapOwner(address,address,address)` selector | `0xe318b52b` |
| `ProxyDeployed(address,address)` topic0 | `0x3d2489efb661e8b1c3679865db649ca1de61d76a71184a1234de2e55786a6aad` |

---

## 10. References

- Snapshot X execution strategies: https://docs.snapshot.box/snapshot-x/protocol/execution-strategies
- `sx-evm` ProxyFactory: https://github.com/snapshot-labs/sx-evm/blob/main/src/ProxyFactory.sol
- `sx-evm` AvatarExecutionStrategy: https://github.com/snapshot-labs/sx-evm/blob/main/src/execution-strategies/AvatarExecutionStrategy.sol
- Safe (v1.3.0) ModuleManager: `enableModule` / `disableModule` / `getModulesPaginated` / `execTransactionFromModule`
- Snapshot X space creation: https://snapshot.box/#/create/snapshot-x

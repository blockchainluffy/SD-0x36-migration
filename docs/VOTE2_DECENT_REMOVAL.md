# Vote 2: removing Decent (Azorius) from Shutter DAO 0x36

How the Vote 2 transaction data was built, and how we know it is correct.
Checked against Ethereum mainnet on 29 September 2026.

## The goal

Azorius sits in two places on the DAO Safe. It is an enabled module, which is what lets
it move the treasury, and it is the sole owner. Vote 2 removes both, in one Snapshot X
proposal with two actions.

| | Address |
|---|---|
| DAO Safe | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |
| Azorius, to be removed | `0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e` |
| Snapshot X space | `0x594EB60b35C4E91A06a5df988e0504f7463cB769` |
| Snapshot X strategy, the new module and new owner | `0x5716a3b2d988Bd7a2D95942ee8a175D27a75E7bB` |
| Security Council, the space controller | `0x3ea731dAF66D6A7980549f90152CD9A761B9c0C0` |

Current state on mainnet: owners are `[Azorius]`, modules are `[strategy, Azorius]`,
threshold 1, no Safe guard. So Vote 1 has already run and Vote 2 has not.

## The two transactions

Both go to the Safe, value 0, operation 0 (a normal call).

**Action 1, `swapOwner(0x…01, Azorius, strategy)`**

```
0xe318b52b
0000000000000000000000000000000000000000000000000000000000000001   prevOwner (list marker)
000000000000000000000000aa6bfa174d2f803b517026e93dbbec1eba26258e   Azorius, removed
0000000000000000000000005716a3b2d988bd7a2d95942ee8a175d27a75e7bb   strategy, added
```

**Action 2, `disableModule(strategy, Azorius)`**

```
0xe009cfde
0000000000000000000000005716a3b2d988bd7a2d95942ee8a175d27a75e7bb   prevModule (pointer, stays enabled)
000000000000000000000000aa6bfa174d2f803b517026e93dbbec1eba26258e   Azorius, disabled
```

Generate them with `./sim.sh vote2-tx --strategy 0x5716a3…`. That writes
`sim/vote2.safe-batch.json` to import into the proposal builder, plus the same data as
decoded actions and raw calldata.

Do not paste `vote2.executionPayload.txt` into the proposal. It contains a salt that
snapshot.box sets itself, so a hand pasted payload will not match.

## Why `prevModule` is the strategy

A Safe keeps its modules in a one way chain, so to remove an item you must also name the
item in front of it. Straight from Safe storage:

```
modules[0x…0001]   -> strategy     (start of chain)
modules[strategy]  -> Azorius
modules[Azorius]   -> 0x…0001      (end of chain)
```

The strategy is in front of Azorius, because `enableModule` inserts at the start and
Vote 1 pushed Azorius back one place.

Naming the strategy does not remove it. Only the second argument is removed. The first
argument just has its pointer rewritten. **The address being removed is always the
second one.**

This value goes stale if any module is enabled before Vote 2 runs. That is why the
builder reads it live every time.

## Why these choices

**Why send Vote 2 through Snapshot X and not Azorius.** Azorius does not check whether
its Safe call worked. A wrong argument leaves Azorius still enabled while the proposal
is marked executed and used up, and fixing it means another vote plus a 14400 block
timelock. The Snapshot X strategy does check: a failure reverts the whole execution and
the proposal can simply be executed again. Azorius also stays enabled as a fallback
until the Snapshot X execution succeeds.

The Security Council can stop Vote 2 on either route, so that is not a factor.

**Why the new owner is the strategy, not the space.** The owner slot should hold
whatever actually calls the Safe, and only the strategy does that. The space only holds
proposals and votes. The slot carries no real power either way, because moving funds
through the owner path needs a signature and the strategy cannot sign, so all governance
keeps running through the module. We change it only because a Safe cannot have zero
owners, and leaving a retired contract listed as owner would mislead every UI.

## How we checked it

**Read the raw storage.** We computed the Safe's storage slots by hand and read the
module and owner chains directly, rather than trusting a helper function.

**Simulated both calls on live mainnet state**, sent from the strategy, which is the
exact path the proposal will take. We also tried the wrong versions on purpose:

| call | result |
|---|---|
| `disableModule(strategy, Azorius)` our action 2 | works |
| `disableModule(Azorius, strategy)` arguments swapped | fails |
| `disableModule(sentinel, Azorius)` wrong front item | fails |
| `swapOwner(sentinel, Azorius, strategy)` our action 1 | works |

A wrong `prevModule` cannot quietly remove the wrong module. The Safe rejects it, and on
this route that failure reverts the whole execution.

These simulations were run twice against the same mainnet state, through Tenderly's
public node and on a local anvil fork, with identical results.

**Ran the whole migration on a fork of the live space.** `./sim.sh test` propose, vote,
execute, then verify. 149 assertions in the Vote 2 step, all passing. It ends with one
module and one owner, both the strategy, and a separate test then impersonates Azorius
and fails to move funds, add itself back, or take an owner seat.

**Tried both transaction orders.** `disableModule` first also works and ends in
identical storage. The two calls touch different storage and neither depends on the
other. We kept `swapOwner` first because that order is also valid if the route ever
changes to Azorius, where `disableModule` must be last.

**Used the new module for real, on mainnet.** Two proposals on the live space:

- [Proposal 4](https://snapshot.box/#/eth:0x594EB60b35C4E91A06a5df988e0504f7463cB769/proposal/4)
  passed and was executed on 28 September, moving 1 SHU out of the DAO Safe
  ([tx](https://etherscan.io/tx/0xac0ce49e0bdddfaf1563f100f6e428cd6d27985a51e56cba977e54db81d5f59a)).
  This proves the strategy really is an enabled module and that the whole path works.
  It was executed by an address that was not the proposer, so execution is permissionless
  and there is no timelock.
- [Proposal 3](https://snapshot.box/#/eth:0x594EB60b35C4E91A06a5df988e0504f7463cB769/proposal/3)
  was cancelled by the Security Council multisig on 18 September
  ([tx](https://etherscan.io/tx/0x8b11d3c75794c0ff768b4aa731a6569a2b0f1526f950d34f3ebde34e91668b37)).
  This proves the council's veto works. It replaces the lever they lose when Azorius
  goes. See `docs/SECURITY_COUNCIL_VETO_GUIDE.md`.

## Nothing else needs removing

We checked everything that refers to Azorius. Only the module slot and the owner slot
need a transaction, and Vote 2 covers both.

The Azorius guard, its two voting strategies and its Hats based proposer gating all stop
working by themselves, because they can only be reached through the module. The Hats
tree, the SHU token and the Safe itself carry no Azorius references. There is no separate
"Hats module" to remove, despite the wording in the original migration note.

Azorius also has no proposals in flight, so nothing is left stranded.

## Before you post

1. Regenerate the data with `./sim.sh vote2-tx --strategy 0x5716a3…`. It re-reads
   `prevModule` and stops if anything looks different.
2. Check that action 2 ends in `…aa6bfa…`, Azorius. That is the module being removed and
   it must never be the strategy.
3. Check no Azorius proposal has appeared, and no open Snapshot X proposal is about to
   change the Safe's modules.
4. Import `sim/vote2.safe-batch.json`, or enter the two actions by hand.

Do not import that file into the Safe wallet app to execute directly. The Safe's only
owner is a contract that cannot sign. It is the payload for the Snapshot X proposal.

## After it executes

```
cast call 0x36bD3044ab68f600f6d3e081056F34f2a58432c4 "getOwners()(address[])"
# expect [0x5716a3b2d988Bd7a2D95942ee8a175D27a75E7bB]

cast call 0x36bD3044ab68f600f6d3e081056F34f2a58432c4 \
  "isModuleEnabled(address)(bool)" 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e
# expect false
```

Check `isModuleEnabled` directly. Do not assume that an executed proposal means the
module is gone. That is the exact mistake this route is chosen to avoid.

## What we did not check

We did not watch a real Azorius proposal fail after removal. There are none in flight,
and we have already simulated the thing that would stop one. After running Vote 2 on a
fork, we impersonated Azorius and tried every action it could want against the Safe:
move SHU, move ETH, enable a module, take an owner seat, install a guard, run a
delegatecall. The Safe refused all of them. Azorius is inert once the vote succeeds, and
since every Azorius proposal has to reach the treasury through that same refused call,
such a test would show nothing new.

We did not confirm what the Decent app will still display. That is presentation only,
with no funds or permissions attached, and the DAO can tidy it later.

## Running it yourself

```bash
export MAINNET_RPC_URL=<an ethereum mainnet rpc>
SPACE=0x594EB60b35C4E91A06a5df988e0504f7463cB769
STRATEGY=0x5716a3b2d988Bd7a2D95942ee8a175D27a75E7bB

./sim.sh vote2-tx --strategy $STRATEGY              # build the transaction data
./sim.sh 6       --space $SPACE --strategy $STRATEGY # rehearse the whole migration
./sim.sh azorius --space $SPACE --strategy $STRATEGY # prove Azorius is inert afterwards
./sim.sh help                                        # every command
```

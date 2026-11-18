# New proposal rules for Shutter DAO 0x36

This document explains how the live Snapshot X space enforces two new proposal rules, how
we tested them, and what is left to do. Last checked against Ethereum mainnet on
16 November 2026 (block 26427103). The first version was checked on 5 October 2026.

1. **Raise the minimum to propose to 50M SHU.** Before the change it was 10M SHU.
2. **Allow one proposal per address every 24 hours.** Today there is no limit.

To keep the nine whitelisted proposers able to propose, their deemed SHU power also had to
rise from 10M to 50M. Without that change all nine would have lost their proposer role.

| | Address |
|---|---|
| Snapshot X space | `0x594EB60b35C4E91A06a5df988e0504f7463cB769` |
| Space controller (Security Council multisig) | `0x3ea731dAF66D6A7980549f90152CD9A761B9c0C0` |
| Current validation contract (`PropositionPower`) | `0x6D9d6D08EF6b26348Bd18F1FC8D953696b7cf311` |
| New validation contract (`PropositionPowerAndActiveProposalsLimiter`) | `0x358e4Ba219CC1e1c7084A14c3a504772acfc40b1` |
| SHU voting strategy (unchanged) | `0x2c8631584474E750CEdF2Fb6A904f2e84777Aefe` |
| Merkle whitelist strategy (unchanged) | `0x34f0AfFF5A739bBf3E285615F50e40ddAaf2A829` |
| Testnet rehearsal space (Sepolia) | `0x4cf33Ed850282dEE3cadF91857dB562A5D4B4381` |

## Status on 16 November 2026

| Rule | Status |
|---|---|
| 50M threshold and 50M whitelist | **Live on mainnet.** The space still uses the plain `PropositionPower` contract, with threshold `50000000000000000000000000` and whitelist root `0x4a4e…6869` (nine addresses at 50M). Checked on chain and on `api.snapshot.box`. |
| 1 proposal per address every 24 hours | **Not applied yet.** snapshot.box now supports the rate-limited contract, and the testnet rehearsal passed on 18 November 2026 (see "Testing on testnet.snapshot.box"). Next step: the Security Council applies it on mainnet. |

### The chosen limits

The limit is **1 proposal per address per 86,400 seconds (24 hours)**. These values come
from the original request ("one proposal per address every 24 hours") and are the
defaults in `src/Config.sol` (`PROPOSAL_COOLDOWN = 24 hours`,
`MAX_PROPOSALS_PER_COOLDOWN = 1`). The threshold (50M) and the whitelist (nine addresses
at 50M) stay as they are now.

This document records no formal DAO vote on these values. If the DAO wants to approve them
first, it can hold a signal vote before the Security Council signs (see "Who makes the
change").

## snapshot.box now supports the 24 hour limit

### Before November 2026: not supported

When we first checked (6 October 2026, `sx-monorepo` `main` at `d03f6b8`), snapshot.box
did not support the rate-limited contract:

- The indexer read the threshold and the allowed strategies only for the plain
  `PropositionPower` contract. For any other validation contract it stored an empty list
  of strategies.
- The website builds the proof of voting power for a new proposal from that list. With an
  empty list, the proposal carried no voting power, so the space rejected it.
- The settings page offered only "Vanilla" and "Voting power".

We confirmed this on testnet.snapshot.box. We switched the test space
`0x4cf3…4381` to the rate-limited contract with
`./sim.sh testnet-rate-limit --space 0x4cf3… --broadcast`
([tx](https://sepolia.etherscan.io/tx/0xfc5d3a7b8d80d0273d6ee246923af0974c1fdf3bab81647ce5b1308cf155eabf)).
The on-chain settings were correct, but the website refused to create a proposal for a
whitelisted wallet. It showed an error that the space has no proposal strategy. After we
switched back to the plain contract, the same wallet could propose again.

### Since 13 November 2026: supported

Snapshot Labs added support in two pull requests:

| Part | Change |
|---|---|
| Indexer (`apps/api`) and sx.js | `3ebf494a`, [#2394](https://github.com/snapshot-labs/sx-monorepo/pull/2394), 12 November. Adds `0x358e…40b1` as `VotingPowerWithCooldown` on every EVM network. The indexer decodes its settings (cooldown, max proposals, threshold, strategies), so the threshold and the allowed strategies are stored again. |
| Website (`apps/ui`) | `8849d7dc`, [#2445](https://github.com/snapshot-labs/sx-monorepo/pull/2445), 13 November. Adds **"Voting power with cooldown"** to the space settings, with the fields **Proposal threshold**, **Max. proposals** (at least 1) and **Cooldown** (days, hours and minutes, at least 1 minute). Shows "Proposal limit reached. Try again later." when the contract rejects a proposal. |

Both changes are live (checked 16 November 2026):

- `api.snapshot.box` and `testnet-api.snapshot.box` both report
  `version_tag: commit:3ebf494a4718`.
- The JavaScript served by snapshot.box and testnet.snapshot.box contains the
  rate-limited contract's address and the "Voting power with cooldown" label.
- On 16 November the testnet indexer stored the whitelist strategy for our test space,
  which was then on the rate-limited contract (600 seconds, 1 proposal). In October the
  list was empty.
- No mainnet space uses the rate-limited contract yet.

On 18 November 2026 we rehearsed the change on testnet.snapshot.box. The settings page
created the rate-limited settings correctly, whitelisted members created proposals
through the website, and the limit worked (see "Testing on testnet.snapshot.box").

### How the Security Council should make the change

Use the snapshot.box settings page, as for the 50M change. The step by step guide is
[`SECURITY_COUNCIL_RATE_LIMIT.md`](SECURITY_COUNCIL_RATE_LIMIT.md). The settings page pins
the metadata files itself, so the website keeps showing the whitelist and can build proofs
for whitelisted members.

The settings page cannot change the type of an existing validation in place. The signer
removes the current "Voting power" validation, adds "Voting power with cooldown", and then
adds the two strategies (SHU and the whitelist) again. The guide gives the exact values.

The transaction builder in this repository (`./sim.sh proposal-rules-tx`) is a fallback.
`SETTINGS_CALLDATA` lets the simulation check the exact transaction the website creates
(see "How we checked it").

## How proposal creation is checked today

Every new proposal is checked by one contract, the space's **proposal validation
strategy**. It adds up the author's voting power from a list of allowed sources and
compares the total with a threshold. The live space has (since the 50M change):

- **threshold:** 50,000,000 SHU (10,000,000 SHU before the 50M change)
- **source 0:** SHU delegated to the author (SHU is an ERC20Votes token)
- **source 1:** a whitelist of nine addresses, each given 50,000,000 SHU of *deemed*
  power (10,000,000 SHU before the 50M change). The whitelist is stored as a Merkle root, which is a single hash that stands for
  the whole list. A whitelisted author proves membership with a short Merkle proof.

Deemed power counts only for creating proposals. It is not voting power. The space's only
voting strategy is delegated SHU, and this change does not touch it.

## What changes

Each change is one transaction. The Security Council calls `Space.updateSettings` and
replaces the proposal validation strategy. Every other setting is left as it is. The
first step is done. The second step is still to do.

| | Before | After step 1 (live) | After step 2 (to do) |
|---|---|---|---|
| Validation contract | `PropositionPower` `0x6D9d…f311` | `PropositionPower` `0x6D9d…f311` | `PropositionPowerAndActiveProposalsLimiter` `0x358e…40b1` |
| Threshold | 10,000,000 SHU | 50,000,000 SHU | 50,000,000 SHU |
| Source 0 | delegated SHU | delegated SHU | delegated SHU |
| Source 1 | whitelist root `0x3be9…cf01`, 9 addresses at 10M | whitelist root `0x4a4e…6869`, same 9 addresses at 50M | whitelist root `0x4a4e…6869` (unchanged) |
| Rate limit | none | none | 1 proposal per 86,400 seconds per address |

The new contract does two checks, and both must pass:

1. **Proposition power.** This check is identical to the current check, with the same
   numbers. The author needs at least 50M SHU from delegated SHU plus deemed whitelist
   power. Exactly 50M is enough.
2. **Rate limit.** The contract remembers, for each author, when that author last created a
   proposal in this space. A new proposal is allowed only if 24 hours have passed since then.

### Why the whitelist root had to change (done in step 1)

The whitelist entries are part of the Merkle root. Each entry is an address *and* its
deemed power. Raising the threshold alone would leave the nine members at 10M, below the
new 50M minimum. So the new settings contain a new root, built from the same nine
addresses at 50M each. Old 10M proofs stop working. A whitelisted member has to use a
proof for the 50M entry. snapshot.box builds that proof automatically once it knows the
new list (see "Metadata").

### Exactly how the 24 hour limit behaves

These details come from the contract source (`ActiveProposalsLimiter.sol`) and are all
confirmed by the simulation:

- **The 24 hours count from the author's last successful proposal.** After a proposal at
  10:00 on Monday, the author's next proposal is allowed from 10:00 on Tuesday.
- **It is measured in seconds (block timestamps), not blocks.** 24 hours is 86,400 seconds.
- **Rejected attempts do not restart the clock.** A failed attempt changes nothing.
- **Cancelled proposals still count.** If the Security Council vetoes a proposal, its
  author still has to wait the full 24 hours.
- **It applies per address, to everyone.** Whitelisted members and SHU holders follow the
  same rule. One author's proposal never blocks another author.
- **Editing a proposal does not count.** `updateProposal` does not run the validation.
- **It starts fresh.** The contract has no history for this space, so every address may
  propose once straight after the change, even if it proposed under the old rules that day.
- The limit is "1 proposal per 24 hours". The contract's name says "active proposals", but
  it does not look at whether earlier proposals are still open. It only counts time.
- **Switching contracts resets the history.** The counts are stored in the validation
  contract, per space and per author. Switching to another contract and back gives every
  address a fresh start. Changing the cooldown applies straight away to existing counts.
- **Nobody can read the count in advance.** The contract keeps it private and has no
  function to read it. snapshot.box therefore cannot warn an author before they try. When
  the contract rejects a proposal, the website shows "Proposal limit reached. Try again
  later." The website shows this message for every `FailedToPassProposalValidation` error,
  so it also appears if an author's voting power is too low. The website checks voting
  power before it sends the proposal, so in practice this happens only for the limit.
- **The limit is per address, not for the whole space.** Different authors can each
  create one proposal in the same 24 hours.

### Who makes the change

Only the space controller, the Security Council multisig, can call `updateSettings`. The
DAO Safe cannot, because it does not control the space's settings. So a Snapshot X
proposal cannot execute this change. If the DAO wants to approve the change first, it can
hold a vote without execution (a signal vote), and the Security Council then signs the
transaction.

The new validation contract is an official sx-evm deployment
(`deployments/ethereum.json`). It is not a proxy and has no owner, so nobody can change
its code or its rules later.

## Building the transaction (fallback)

The Security Council should use the snapshot.box settings page (see
[`SECURITY_COUNCIL_RATE_LIMIT.md`](SECURITY_COUNCIL_RATE_LIMIT.md)). This builder is a
fallback if the settings page cannot be used.

```bash
./sim.sh proposal-rules-tx                         # both rules
RATE_LIMIT=0 ./sim.sh proposal-rules-tx            # 50M only
PV_METADATA_URI=ipfs://<CID> ./sim.sh proposal-rules-tx   # final, with metadata
```

The builder applies the transaction on a mainnet fork as the Security Council, checks the
result, and then writes these files to `./sim`:

| File | Contents |
|---|---|
| `proposalRules.safe-batch.json` | Safe Transaction Builder batch for the Security Council Safe |
| `proposalRules.tx.json` | to, value, operation and data |
| `proposalRules.calldata.txt` | the raw calldata |
| `proposalRules.whitelist-tree.json` | the new whitelist, nine addresses at 50M |
| `proposalRules.whitelist-metadata.json` | template that points at the tree |
| `proposalRules.validation-metadata.json` | template that points at the whitelist metadata |

The transaction goes **to the space**, with value 0, and is executed **by the Security
Council multisig**. It is not a DAO Safe transaction and it is not a proposal payload.

### Metadata

The on-chain settings hold only the Merkle root. snapshot.box also needs the full list of
addresses to build proofs for whitelisted members. It finds that list through the
`proposalValidationStrategyMetadataURI` field of the same transaction. The live space uses
three linked IPFS files. Pin them in this order, because each file points at the one
before:

1. Pin `proposalRules.whitelist-tree.json`.
2. Put its CID into `proposalRules.whitelist-metadata.json` and pin that file.
3. Put the second CID into `proposalRules.validation-metadata.json` and pin that file.
   Entry 0 of that file is the existing SHU metadata, which does not change.
4. Rebuild with `PV_METADATA_URI=ipfs://<third CID>`.

If the Security Council applies the change through the snapshot.box settings page, the
page pins these files itself, and this section can be skipped. Since 12 November 2026 the
indexer reads this metadata for the rate-limited contract too.

The metadata is required. If the transaction sets an empty metadata URI, the indexer keeps
showing old metadata entries from earlier settings. Our testnet space shows this: after
the script switched it with an empty URI, the indexer kept whitelist metadata from earlier
settings.

## How we checked it

`./sim.sh proposal-rules` forks mainnet, applies the transaction to the **real** space as
the Security Council, and tests every rule. Each "rejected" check also confirms the exact
error, so a rejection always comes from the rule being tested. On 18 November 2026
(block 26439997) all 66 checks pass. The 50M-only version (`RATE_LIMIT=0`) passes all 55
of its checks. That version matches the live settings, so for it the change does
nothing.

| Section | What is proven |
|---|---|
| A. Baseline | The live space is at 50M with the 50M whitelist and no limit. A 50M holder and a whitelisted member can each propose twice in a row. The old 10M whitelist proof is rejected. The new contract has code and is not a proxy. |
| B. Apply | A non-controller cannot apply the change. The controller can. The stored settings are exactly the new ones. Voting delay, voting durations, voting strategy, authenticators, controller and `daoURI` are unchanged. No proposal is created and the DAO Safe is not touched. |
| C. Threshold | A holder with 10M is rejected. A holder with 50M minus 1 wei is rejected. After a top-up to exactly 50M, the same holder is accepted. |
| D. Whitelist | All nine members can propose with the 50M proof. The old 10M proof is rejected (`InvalidProof`). Another address cannot use a member's entry (`InvalidProof`) or a member's real proof (`InvalidMember`). |
| E. Rate limit | A second proposal straight away, after 12 hours, and after 24 hours minus 1 second is rejected. At exactly 24 hours it is accepted, and the next attempt is rejected again. Member 1 is not blocked by member 0. A 50M SHU holder is limited too. A proposal vetoed by the Security Council still counts. |
| F. End to end | A proposal created under the new rules passes the vote and executes, moving 1 SHU out of the treasury. |

The simulated holders are funded from the treasury on the fork only. Nothing is signed or
broadcast.

Section A expects the 50M state that is live today. With a `FORK_BLOCK` from before the
50M change, section A fails on purpose.

To check the exact transaction the website puts in the Safe, copy its data and replay it:

```bash
SETTINGS_CALLDATA=0x<data from the Safe> ./sim.sh proposal-rules
```

Every check then runs against that transaction instead of the one the script builds.

## Running it yourself

```bash
export MAINNET_RPC_URL=<an ethereum mainnet rpc>
./sim.sh proposal-rules                 # simulate both rules on the live space
RATE_LIMIT=0 ./sim.sh proposal-rules    # simulate the 50M-only version
./sim.sh proposal-rules-tx              # build the Security Council transaction
./sim.sh test --match-test ProposalRules
```

Both commands use the live space by default. Other values can be tried with
`NEW_PROPOSAL_THRESHOLD`, `NEW_WHITELIST_VP`, `PROPOSAL_COOLDOWN` (seconds) and
`MAX_PROPOSALS_PER_COOLDOWN`.

## Testing on testnet.snapshot.box

This rehearsal checks that the website can create proposals under the rate-limited
contract, and lets us try the Security Council steps before they are used on mainnet. It
uses the Sepolia test space
[`0x4cf33Ed850282dEE3cadF91857dB562A5D4B4381`](https://testnet.snapshot.box/#/sep:0x4cf33Ed850282dEE3cadF91857dB562A5D4B4381)
("test space - punit").

### State of the test space before the rehearsal

Prepared on 18 November 2026:

| Setting | Value |
|---|---|
| Controller | `0xb9C303443c9af84777e60D5C987AbF0c43844918` (the `SEPOLIA_PRIVATE_KEY` wallet) |
| Validation | plain `PropositionPower` `0x6D9d…f311`, the same contract as mainnet today |
| Threshold | `10000000` |
| Allowed strategies | the Merkle whitelist only, root `0xa593…ba35` (the controller at `10000000`) |
| Validation metadata URI | empty (fixed in step 1) |
| Authenticators | `EthTx` only, so every proposal is a wallet transaction. There is no gasless relayer. |
| Voting delay | 0, so a proposal cannot be edited after it is created |

To get there, `MODE=revert ./sim.sh testnet-rate-limit` switched the space back from the
rate-limited contract
([tx `0xde04…a1b4`](https://sepolia.etherscan.io/tx/0xde04352fa0105f719d7b07226a8d7623fb7fce0475f6a4c45836b94f266ba1b4)).
A first attempt ran out of gas
([tx `0x636c…b269`](https://sepolia.etherscan.io/tx/0x636c74e22506f837fdddbf9c14cca9bf46eb89f34b28ef696215b935ad9cb269)),
because forge's gas estimate is too low for the controller wallet. `sim.sh` now adds a 2x
gas margin for this command.

The test space has no SHU strategy. The Sepolia dummy token (`0xa309…E281`) does not
support `getVotes`, so the "ERC-20 Votes" step cannot be rehearsed on testnet. The
rehearsal covers every other step.

The rehearsal uses a **10 minute cooldown** so the reset can be tested without waiting
24 hours. Mainnet uses 24 hours.

### What you need

| Wallet | Address | Role |
|---|---|---|
| A | `0xb9C303443c9af84777e60D5C987AbF0c43844918` | controller and whitelist member |
| B | `0x1480A3e821ADe08e5D9414b0F671B21638eC60D3`, or any other wallet you control | second whitelist member |
| C | any wallet that is not on the whitelist | outsider |

Wallets A and B need some Sepolia ETH. Every step uses
[testnet.snapshot.box](https://testnet.snapshot.box). Replace B's address below if you
use a different wallet.

### Step 1: repair the whitelist metadata and add member B

The space's whitelist metadata is empty, so the website cannot reliably show the
whitelist or build proofs. Saving the whitelist once on the website uploads new metadata.

1. Connect wallet A. Open the test space, go to **Settings** and then **Proposal**.
2. The page shows **Voting power (10000000)** with a **Whitelist** strategy. Click the
   pencil on **Whitelist**. Replace the whole field with the text below, set **Symbol**
   to `VP`, and click **Confirm**.

   ```
   0xb9C303443c9af84777e60D5C987AbF0c43844918:10000000
   0x1480A3e821ADe08e5D9414b0F671B21638eC60D3:10000000
   ```

3. Click **Save** and confirm the transaction in wallet A.
4. Wait about a minute, then reload the page. It must show **Voting power (10000000)**
   and **Whitelist (2 addresses)**.
5. Check the indexer. `voting_power_validation_strategy_metadata` must start with
   `ipfs://`:

   ```bash
   curl -s https://testnet-api.snapshot.box -H 'content-type: application/json' -d \
     '{"query":"{ space(id:\"0x4cf33Ed850282dEE3cadF91857dB562A5D4B4381\") { validation_strategy proposal_threshold voting_power_validation_strategy_strategies voting_power_validation_strategy_metadata } }"}'
   ```

6. Check the new whitelist root on chain. It must be
   `0xbab0156aff98ccf6feb3ae7b11e79d8fba3dc0d83de4ea29837e4c745e7b89cb`:

   ```bash
   cast call 0x4cf33Ed850282dEE3cadF91857dB562A5D4B4381 \
     "proposalValidationStrategy()(address,bytes)" \
     --rpc-url https://ethereum-sepolia-rpc.publicnode.com
   ```

7. Control test, with no limit yet: create two proposals in a row with wallet A. Both
   must succeed.

### Step 2: switch to "Voting power with cooldown"

This is the Security Council procedure
([`SECURITY_COUNCIL_RATE_LIMIT.md`](SECURITY_COUNCIL_RATE_LIMIT.md), steps 3 to 8), with
testnet values. Take a screenshot of each screen for the Council guide.

1. Still connected as wallet A, go to **Settings** and then **Proposal**.
2. Click the bin icon on **Voting power**. Check that the validation and its whitelist
   disappear and that a **Voting power with cooldown** button appears.
3. Click **Voting power with cooldown**. Enter these values, then click **Confirm**:

   | Field | Value |
   |---|---|
   | Proposal threshold | `10000000` |
   | Max. proposals | `1` |
   | Cooldown | `0` days, `0` hours, `10` minutes |

4. Under **Included strategies**, click **Whitelist**. Paste the same two lines as in
   step 1, set **Symbol** to `VP`, and click **Confirm**. Skip ERC-20 Votes on testnet.
5. Check that the page shows **Voting power with cooldown (10000000, max. 1, 10m
   cooldown)** and **Whitelist (2 addresses)**. Click **Save**.
6. Before you confirm in wallet A, open the transaction data. It must contain
   `358e4ba219cc1e1c7084a14c3a504772acfc40b1`, then the lines below as the first three
   words of the validation params (cooldown 600, max 1, threshold 10000000), and the
   root `bab0156a…7b89cb`:

   ```
   0000000000000000000000000000000000000000000000000000000000000258
   0000000000000000000000000000000000000000000000000000000000000001
   0000000000000000000000000000000000000000000000000000000000989680
   ```

   Confirm the transaction. Write down the time it was mined.

### Step 3: check the stored settings

1. Run the `cast call` from step 1.6. The first line must be
   `0x358e4Ba219CC1e1c7084A14c3a504772acfc40b1`. The params must start with the three
   lines above and end with the root `bab0156a…7b89cb`.
2. Run the `curl` from step 1.5. `validation_strategy` must be `0x358e…40b1`,
   `voting_power_validation_strategy_strategies` must be
   `["0x34f0AfFF5A739bBf3E285615F50e40ddAaf2A829"]` (not empty), and the metadata must
   start with `ipfs://`.
3. Reload the settings page. It must still show **Voting power with cooldown (10000000,
   max. 1, 10m cooldown)** and **Whitelist (2 addresses)**.

If the strategy list is empty or the page shows no whitelist, stop. The website will
not be able to create proposals. Note what you see and switch back (step 6).

### Step 4: test proposal creation

The cooldown is counted from each author's last successful proposal, so do rows 1 to 6
within 10 minutes of row 1.

| # | Wallet | Action | Expected result |
|---|---|---|---|
| 1 | A | Create a proposal. Note the time. | Created |
| 2 | A | Create a second proposal straight away | Refused with "Proposal limit reached. Try again later." No transaction is mined, or it fails. |
| 3 | B | Create a proposal | Created. A's limit does not affect B. |
| 4 | B | Create a second proposal straight away | Refused |
| 5 | C | Open the new proposal page | No proposing power. The website does not let C publish. |
| 6 | A | Cancel the proposal from row 1 (A is the controller), then try to create a proposal | Refused. A cancelled proposal still counts. |
| 7 | A | At least 10 minutes after row 1, create a proposal | Created |
| 8 | A | Create another proposal straight away | Refused |

### Step 5: record the result

Write the date, the transaction hashes, the screenshots and any difference from the
expected results into this document. Put the date into
[`SECURITY_COUNCIL_RATE_LIMIT.md`](SECURITY_COUNCIL_RATE_LIMIT.md), and update its button
and field names if the website used different ones.

### Step 6: switch back (optional)

To put the test space back on the plain contract:

```bash
MODE=revert ./sim.sh testnet-rate-limit --space 0x4cf33Ed850282dEE3cadF91857dB562A5D4B4381            # dry run
MODE=revert ./sim.sh testnet-rate-limit --space 0x4cf33Ed850282dEE3cadF91857dB562A5D4B4381 --broadcast
```

The script sets an empty metadata URI. Repeat step 1 afterwards so the website shows the
whitelist correctly again.

### Result (18 November 2026): passed

The settings change and every test passed on testnet.snapshot.box. Step 1 was skipped:
the settings were changed in one save, straight from the plain contract to the
rate-limited contract with the two-member whitelist. That save also uploaded fresh
metadata, so step 1 was not needed.

| | Value |
|---|---|
| Settings change | [tx `0xffc4…501a`](https://sepolia.etherscan.io/tx/0xffc40fc565de6374b876bf4adc10a9147d5ad1fa91563662847a5058eb33501a), block 12160132 |
| Stored on chain | validator `0x358e…40b1`, cooldown 600, max 1, threshold 10000000, root `0xbab0…89cb` |
| Indexer | strategy list `[0x34f0…]` (not empty), metadata `ipfs://bafkreidcv…`, whose tree holds both members at `10000000` |

| # | Wallet | Action | Result |
|---|---|---|---|
| 1 | A | Propose | Created: proposal 3, 07:58:12 UTC, [tx `0x493c…b25e`](https://sepolia.etherscan.io/tx/0x493cb2232392473fd0ff3a726ca2c4ba24e9a1e23c780b2641d0273045b2b25e) |
| 2 | A | Propose again straight away | Refused on the website |
| 3 | B | Propose | Created: proposal 4, 07:59:00 UTC, [tx `0x56e5…cb94`](https://sepolia.etherscan.io/tx/0x56e5890dd2d06e1ca790ccabe45a8da74b7425a683853e8ce191f0fdebf6cb94) |
| 4 | B | Propose again straight away | Refused on the website |
| 5 | C | Open the new proposal page | Could not publish |
| 6 | B | Cancel proposal 4, then propose | Proposal 4 shows as cancelled. The new attempt was refused. |
| 7 | B | Propose after the cooldown (from 08:09:00) | Created: proposal 5, 08:11:12 UTC, [tx `0xfbec…8fde`](https://sepolia.etherscan.io/tx/0xfbec533409c87af15191d4168cffa09af6b487f6365e5f553f10de74beef8fde) |
| 8 | B | Propose again straight away | Refused on the website |

Rows 6 to 8 were run with wallet B instead of wallet A. The rule is the same for every
address.

Refused attempts are stopped by the website before a transaction is sent, so they leave
nothing on chain. Their results come from the website. The accepted proposals were
confirmed on chain and on the indexer. The contract's stored counters (read directly
from its storage) match: after the test, A had count 1 with its last proposal at
07:58:12, and B had count 1 with its last proposal at 08:11:12, which shows the counter
was reset after the cooldown.

## Before the Security Council signs

1. The testnet rehearsal above passes, including proposal creation through the website.
   Done on 18 November 2026.
2. The DAO has approved the limits, if a signal vote is wanted (see "Who makes the
   change").
3. Whitelisted members and other regular proposers know about the new rule: one proposal
   per address every 24 hours, and a vetoed or cancelled proposal still counts.
4. The Security Council follows
   [`SECURITY_COUNCIL_RATE_LIMIT.md`](SECURITY_COUNCIL_RATE_LIMIT.md).

## After it executes

```bash
cast call 0x594EB60b35C4E91A06a5df988e0504f7463cB769 \
  "proposalValidationStrategy()(address,bytes)"
# expect 0x358e4Ba219CC1e1c7084A14c3a504772acfc40b1 and params with cooldown 0x15180
# (86400), max 1, threshold 0x295be96e64066972000000 (50M), the SHU token and
# whitelist root 0x4a4e…6869
```

Then check that:

- The snapshot.box settings page shows "Voting power with cooldown", the SHU strategy and
  "Whitelist (9 addresses)".
- `api.snapshot.box` lists both strategies for the space, not an empty list:

  ```bash
  curl -s https://api.snapshot.box -H 'content-type: application/json' -d \
    '{"query":"{ space(id:\"0x594EB60b35C4E91A06a5df988e0504f7463cB769\") { validation_strategy proposal_threshold voting_power_validation_strategy_strategies voting_power_validation_strategy_metadata } }"}'
  ```

- A whitelisted member can create a proposal on the website, and a second proposal from
  the same address within 24 hours is refused.

## What we did not check

- We did not test the website on mainnet. testnet.snapshot.box runs the same code, and
  the rehearsal there passed on 18 November 2026.
- The SHU ("ERC-20 Votes") strategy step was not rehearsed, because no Sepolia token
  supports delegated votes. On mainnet that strategy is added with the values in the
  Security Council guide, and the Safe check confirms them.
- We did not list which SHU holders today have between 10M and 50M of delegated power.
  Those holders lost the ability to propose unless they gather more delegations.

# Hamster Hour v2

Pari-mutuel IMD betting on the Squeekchain hamster wheel, on Ethereum mainnet. One contract,
`HamsterHour`, with no owner, pause, upgrade or withdrawal power. TEAM (the launch wallet) holds
only three 12-hour timelocked settings. Results come only from IMD oracle v2 EIP-712 attestations
signed for this contract's own domain. It replaces the unused v1 at
`0xc5217f129da200a8e86229de4eabf3686eef64b1`; the design follows the v2 design review except where
the brief differs (fixed line 2100 instead of a dynamic line, 0.5% EXACT band, 12-hour timelocks).

## Build and test

```sh
forge build
FOUNDRY_FUZZ_SEED=0x505c38d385d3b9119c30cbebc45173e62d48fe52395326454011c2392777ebd9 forge test
forge fmt --check
```

Solidity 0.8.26, Cancun, optimizer 200 runs, `bytecode_hash = "none"`. The fuzz seed is also pinned
in `foundry.toml`. The only dependency is forge-std, vendored as ordinary files under `lib/`. Tests
use no environment variables, FFI or filesystem access; IMD is a mock etched at the real IMD address
and the Intake is a mock that delivers with the documented 200,000 gas stipend. The ABI is exported
to `abi/HamsterHour.json`. Runtime size is about 23.1 KB of the 24 KB limit.

## Deployment parameters (real addresses only)

| Contract | Constructor argument | Value | Source |
| --- | --- | --- | --- |
| `HamsterHour` | `team_` | `$owner` = `0x6cba4751742f6989fa224b2dc5d5d52fcef98a34` | the launch wallet, from the launch |
| | `attester_` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` | `attester` field of `GET https://api.imd.fun/oracle/requests` on 2026-10-19, and the signer recovered from a real signed Squeekchain attestation (test `test_realAttestationRecoversProductionAttester`) |
| | `intake_` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` | IMD Intake v2, "Pay onchain" table at imd.fun/docs (live since 2026-10-10, same address on every chain) |

Chain id 1. IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` is a constant. The constructor is
nonpayable, makes no external calls and grants nothing to `msg.sender` or `tx.origin`. The table is
guidance for the separate manifest step, not a manifest; no `launch.json` is written here.

## Time

- Genesis `1791847200`, rounds of 600 s, window `k` = rounds `6k..6k+5`, starts `GENESIS + 3600k`,
  ends one hour later. Half-open intervals.
- Betting on window `k` is open while `now < start(k)` and `start(k) <= now + 24h`: up to 24 windows
  ahead, closing strictly at window start.
- A window is created by its first bet and snapshots its line then (`lineFor(k)`, see "After
  launch": the line of a window never changes once the window can be bet on). Source and genesis
  are constants, so they are the same for every window and are bound into every oracle question.
- Settle while `end <= now < end + 48h`. From `now >= end + 48h` the window can only time out, which
  refunds everything in it with no fees.

## Markets

- **OVER/UNDER** (`betOverUnder(k, over, amount)`, min 0.5 IMD, can be added to): OVER iff
  `result > line`, otherwise UNDER (equality is UNDER). If `result < 100` (asleep) the whole market
  is refunded, no fees.
- **SNOOZE** (`betSnooze(k, yes, amount)`): YES iff `result < 100`.
- **EXACT** (`buyTicket(k, guess)`): 5 IMD, one per address per window, at most 256 per window,
  guess at most `2^64 - 1`. Wins iff `|guess - result| * 1000 <= result * 5`, evaluated as
  `|guess - result| * 200 <= result` without overflow. Asleep results have no winners.
- A binary market with only one side funded refunds fully, no fees.
- Binary fee split on each settled market pool: 5% staking, 2% jackpot, 1% oracle reserve, 1% TEAM,
  remainder (91% plus rounding) to winners pro rata by stake. Ticket split: 5% staking, 1% oracle,
  1% TEAM, remainder (93%) is that window's jackpot contribution.
- Line fixed at 2100 initially; TEAM can change it with the 12-hour timelock for windows that open
  after the change is ready.
- There is no cap on binary bettors and no per-user list anywhere: nothing a sybil can fill.

## Settlement and fee allocation

Settlement has two steps so the Intake callback fits its gas stipend:

1. **Record the result**: the attestation checks below, then `status = Settled`, `result`,
   `requestId`, replay mark, `Settled` event. This is all `onOracleResult` does (about 120k-141k
   gas, measured; the Intake grants 200,000).
2. **Allocate fees** (`allocate(k)`, permissionless and idempotent; also run by the public `settle`
   and by `finalize`): moves the 9% binary fees and the ticket split to the staking bucket, the
   window's jackpot inflow (`jackpotInFlight`), the oracle reserve and TEAM, and emits
   `FeesAllocated` and `MarketVoided`.

Winner and refund entitlements are computed from the pools and the result, so `claim(k)`,
`claimable` and `lossOf` are correct from the moment the result is recorded and do not depend on
step 2. `windowInfo(k).feesAllocated` says whether step 2 has run.

## Jackpot

`finalize(maxWindows)` is permissionless and advances `nextFinalizeWindow` strictly in index order.
It stops at a window that is still open and not yet timed out, times out one that is, and passes a
window nobody created as soon as that window has started (from then on it can never be created and
its pending deposits are frozen, so an empty quiet hour never delays later windows' jackpots or loss
history). For each window in order:

1. pot = carried seed + pending external deposits assigned to this window + (if settled) the
   window's 93% ticket contribution and its 2% binary fees;
2. if settled, awake and some tickets win: 80% of the pot is split equally into fixed per-winner
   liabilities (`jackpotShare`) and the remaining 20% (plus split dust) carries;
3. otherwise everything carries. A timeout refunds tickets and leaves the seed unchanged.

`feedHamster(amount)` sends 90% to the jackpot and 10% to the Squeektoshi tip jar and emits
`Fed(from, amount)`. `depositJackpot(amount)` (donations, a future token hook) sends 100%. Both go
to the pending bucket of the earliest not-started window, so they cannot change a prize already
fixed. The jackpot is never read from the token balance; stray transfers are ignored.

**Coverage note (design property of the brief's parameters).** A ticket covers
`2 * floor(result / 200) + 1` consecutive results (21 at a result near 2100). One ticket per
address is sybil-trivial and the 256-ticket cap is first come, so 256 tickets spaced 21 apart cover
every awake result in roughly `[2000, 7375]` for 1,280 IMD, of which 1,190.4 IMD flows back into
the pot. Such a sweep is profitable once the carried seed exceeds about 410 IMD (80% payout of seed
plus own contribution), and it locks other players out of that window's tickets. The brief fixes
the ticket price, the one-per-address rule, the 256 cap, the band and the 80% split, so the contract
implements them as written; operators should expect the seed to be swept when it grows past that
level, and may ask for a different ticket cap or payout rule in a later version.

## Oracle

The attestation is the IMD v2 EIP-712 type (`OracleAttestation.sol`), domain
`{"IdentityMD Oracle", "2", chainId 1, verifyingContract = HamsterHour}`. Recording a result requires:
`a.questionHash == keccak256(questionDocument(k, a.fromBlock, a.toBlock))` (the canonical sorted-key
document of `question(k)`, which names the six round ids, the genesis and the source), chain id 1,
typed `uint256` answer of 32 bytes, `panelSize >= 5`, `agreed >= 4`, `agreed >= quorum`,
`agreed <= panelSize`, `issuedAt >= end`, `issuedAt <= now + 300`, `now <= expiresAt`, a never
consumed `requestId` (consumer-scoped: the mapping lives in this contract), and an ECDSA signature
by the attester over this contract's domain. The question says missing rounds are unanswerable and
must never be answered 0, so missing data cannot become "asleep". A panel that cannot answer leaves
the window to its 48-hour timeout.

**Paying from the reserve.** The IMD Intake sells `oracle.request` on Ethereum for 0.5 IMD, so the
reserve pays requests directly and there is no settler reimbursement. `requestOracle(k)` (anyone,
after the window ends, while it is settleable) moves 0.5 IMD from `oracleReserve`, approves the
Intake and calls `requestWithFailure("oracle.request@oracle-1", requestBody(k),
(this, onOracleResult), onOracleFailure, IMD, 0.5e18)`; on an Intake that does not offer
`requestWithFailure` it falls back to `request` (same arguments, no failure hook), and the
`OracleRequested` event says which (`withFailureHook`). The reserve pays only for windows that can
produce fees (`hasFeePayingActivity(k)`: a two-sided binary market or at least one ticket), so a
single refundable 0.5 IMD bet cannot drain it.

The control plane calls back once with 200,000 gas:

- `onOracleResult(intakeRequestId, a, sig)`: accepted only from the Intake and only for a request
  this contract paid for; records the result (step 1 above) and clears the outstanding request.
- `onOracleFailure(intakeRequestId, status, reason, agreed, answered, signature)`: status 1
  (refused) or 2 (no result: the panel disagreed or the job was cancelled). Unsigned, so it only
  clears the outstanding request and emits `OracleRequestFailed`; nothing moves.

A paid request is **outstanding** (`oracleRequestPending(k)`) from `requestOracle` until it
delivers, fails, or 86,400 s (the body's `validForSeconds`) have passed. While it is outstanding a
second `requestOracle(k)` reverts `AlreadyRequested`. The public `settle(k, a, sig)` reverts
`PaidRequestPending` while `publicSettleHeld(k)`: an outstanding request **and** less than
`PUBLIC_SETTLE_HOLD` (24 h) since the window's end. So the answer the contract paid for is the one
that settles the window and a bettor's own attestation cannot pre-empt it, but no sequence of paid
requests (a request at the end and another after the first lapses, which keepers are told to make)
can hold the public path past `end + 24h`: the second half of the 48 h settlement period is always
open to any correctly signed attestation, and an Intake that never calls back costs at most two
reserve payments, never the window. A later paid request may still deliver through
`onOracleResult` while the window is open. After a failure or the lapse, anyone may pay a new
request from the reserve or submit a public attestation; a late delivery of a lapsed request is
still accepted while the window is open. Timing: a request made at the exact end of a window may
reach the panel before Squeekchain has published the last round as settled; the panel then ends
without a result, the failure hook releases the window, and a new request can be paid. Keepers
should wait a few minutes after `windowEnd(k)` before calling `requestOracle(k)`.

The body was checked against the free `POST /requests/check` on 2026-10-19 with no blockers (the
"not answerable" advisory was for rounds in the future). An empty reserve only makes
`requestOracle` revert; recording results, fee allocation, timeouts and claims never depend on it.
`fundOracleReserve` is open to anyone, and 1% of fee-paying volume refills it.

## Staking, tip jar and TEAM

The 5% staking share accrues to `pendingStakingFees` until TEAM sets the staking recipient (the
future MiningVault) once; the held amount moves to that recipient's pull balance on execution and
later fees accrue there directly. The 10% feed tip accrues the same way until the tip jar recipient
is set once. TEAM's 1% accrues to `balances[TEAM]`. Every recipient pulls with `withdraw()`.

## Mining history

`lossOf(k, account) = max(0, binary paid - refund entitlement - payout entitlement)`, netted across
OVER/UNDER and SNOOZE, EXACT excluded, computed from entitlements so it is identical before and
after claims; zero while a window is open and zero after a timeout. The payout entitlement is
rounded **up** inside `lossOf` while claims round it down, so a recorded loss is never more than
the real one and is short of it by less than one wei per winning side.

At chronological finalization the contract stores `totalEligibleLoss[k]`, `cumulativeLossBefore[k]`
and `cumulativeLossAfter[k]` and emits `LossHistory`. `totalEligibleLoss[k]` is computed at pool
level with no loop over users: for each non-void binary market, the losing side's whole stake plus
the winning side's shortfall when the 9% fee leaves it less than its stake (a market where the
losers hold under about 9.9% of the winners' stake). Properties, tested:

- it equals the sum of `lossOf` over all accounts whenever no account holds more than one side in
  the window and no winner's share needs rounding (the normal case); when the winning side has a
  shortfall and shares do not divide evenly, the sum is below the total by under one wei per
  winning account, never above it;
- an account that hedges within itself nets its own loss (`lossOf` is per account) while the
  pool-level total counts the whole losing side, so hedging raises `totalEligibleLoss[k]` above
  the sum of `lossOf` and dilutes other accounts' share of that window; the hedger pays the 9% fee
  on both legs for it. An exact total would need a loop over users, which the brief forbids.

In every case the sum of `lossOf` over all accounts is at most `totalEligibleLoss[k]`, so a vault
paying `reward * lossOf / totalEligibleLoss` never over-distributes.

## Claims and conservation

`claim(k)` pays the caller's winnings, refunds and jackpot share for window `k`, never expires and
can be called again after the window's jackpot is finalized. Every incoming unit is assigned to a
bucket: `windowFunds[k]` (pools until paid or allocated), pull balances, `pendingStakingFees`,
`pendingTips`, `jackpotSeed`, `pendingJackpotDeposits` (summed in `totalPendingJackpotDeposits`),
`jackpotInFlight` (settled windows' jackpot inflow until finalized), `jackpotOutstanding` and
`oracleReserve`. `trackedLiabilities()` is the sum of every bucket except `windowFunds[k]`, so
`IMD.balanceOf(game) == trackedLiabilities() + sum of windowFunds` up to stray transfers. Pro-rata
floor division leaves at most one unit per payout in `windowFunds[k]` forever; the invariant
"IMD held >= all liabilities" is fuzzed in `test/Conservation.t.sol`. Reentrancy is guarded.

## After launch

| Setting | Calls (TEAM only) | Value |
| --- | --- | --- |
| Line | `scheduleLine(v)` | new OVER/UNDER line; ready 12 h later, applies from `nextLineFrom` |
| Staking recipient, once | `scheduleStakingRecipient(a)` then `executeStakingRecipient(a)` after 12 h | the deployed MiningVault (or an interim recipient) from its own deployment record |
| Tip jar, once | `scheduleTipRecipient(a)` then `executeTipRecipient(a)` after 12 h | Squeektoshi's wallet |

**Line changes.** `scheduleLine(v)` emits `LineScheduled(v, readyAt, fromWindow)` with
`readyAt = now + 12h` and `fromWindow` the first window that starts after `readyAt + 24h`, i.e. the
first window that cannot be bet on before the change is ready. `lineFor(k)` and `windowInfo(k).line`
show `v` for every `k >= fromWindow` from the moment of scheduling, and the old line below it, so
the line a bettor reads for any window they can bet on is the line that window gets. A schedule
that is not yet ready may be overwritten (it affects no bettable window); once ready it is locked
until every window below `fromWindow` has closed (24 h), after which `LineApplied` is emitted and a
new change may be scheduled. `line()` is the line in force for the next window to start.

Operational responsibilities: keep `oracleReserve` funded (24 settlements/day cost 12 IMD/day at
the current 0.5 IMD price, only for windows with fee-paying activity), call `requestOracle(k)` a
few minutes after each window ends, call `allocate(k)` or `finalize(n)` regularly (fees reach
stakers, the reserve and TEAM at allocation; jackpots and loss history at finalization), and watch
`LineScheduled`, `SettingScheduled` and `OracleRequestFailed` events. Nobody has to run a keeper
for users to recover timeout refunds. Tests are not an audit; an independent adversarial review is
still required.

## Chosen values not fixed by the brief

`OPEN_AHEAD` 24 h, `ISSUED_AT_TOLERANCE` 300 s, `MAX_GUESS` `2^64 - 1`, `ORACLE_REQUEST_VALIDITY`
86,400 s (equal to the body's `validForSeconds`), `PUBLIC_SETTLE_HOLD` 24 h (half the timeout), source `https://sepolia.squeekchain.com` (as v1
and the live site), Intake body
`{"window":{"hours":24},"panelSize":5,"quorum":4,"validForSeconds":86400}`, pool cap `uint128`.

## Trust assumptions

- The attester key and panel are trusted for truth; a valid false answer is final. The timeout only
  covers absence. The attester is immutable: if IMD rotates it, a new deployment is needed and open
  windows refund at their timeout.
- The Intake address is immutable; if IMD moves it, requests can still be paid off-chain and
  settled through `settle`. The public path waits for an outstanding reserve-paid request only
  until 24 h after the window's end (`PUBLIC_SETTLE_HOLD`), whatever requests were paid or renewed;
  a window therefore always has at least 24 h of public settlement before its 48 h timeout, and an
  Intake outage can never force a timeout on a window whose attestation exists.
- If the attester ever signs two different answers to one question, the first valid one to reach
  the contract through the allowed path is final; the Intake-paid path has priority while it is
  outstanding, nothing more.
- TEAM's one-time staking recipient choice decides where the 5% share goes.

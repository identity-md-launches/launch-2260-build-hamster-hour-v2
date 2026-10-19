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
use no environment variables, FFI or filesystem access; IMD is a mock etched at the real IMD address.
The ABI is exported to `abi/HamsterHour.json`.

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
- A window is created by its first bet and snapshots the line then. Source and genesis are constants,
  so they are the same for every window and are bound into every oracle question.
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
- Line fixed at 2100 initially; TEAM can change it with the 12-hour timelock for windows created
  after execution.
- At most 256 distinct binary bettors per window (`MAX_BINARY_BETTORS`), see "Mining history".

## Jackpot

`finalize(maxWindows)` is permissionless and advances `nextFinalizeWindow` strictly in index order.
It stops at a window that is still open and not yet timed out, times out one that is, and passes
an empty (never created) window once its timeout would have elapsed. For each window in order:

1. pot = carried seed + pending external deposits assigned to this window + (if settled) the
   window's 93% ticket contribution and its 2% binary fees;
2. if settled, awake and some tickets win: 80% of the pot is split equally into fixed per-winner
   liabilities (`jackpotShare`) and the remaining 20% (plus split dust) carries;
3. otherwise everything carries. A timeout refunds tickets and leaves the seed unchanged.

`feedHamster(amount)` sends 90% to the jackpot and 10% to the Squeektoshi tip jar and emits
`Fed(from, amount)`. `depositJackpot(amount)` (donations, a future token hook) sends 100%. Both go
to the pending bucket of the earliest not-started window, so they cannot change a prize already
fixed. The jackpot is never read from the token balance; stray transfers are ignored.

## Oracle

The attestation is the IMD v2 EIP-712 type (`OracleAttestation.sol`), domain
`{"IdentityMD Oracle", "2", chainId 1, verifyingContract = HamsterHour}`. `settle(k, a, sig)` requires:
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
once per window, after the window ends) moves 0.5 IMD from `oracleReserve`, approves the Intake and
calls `request("oracle.request@oracle-1", requestBody(k), (this, onOracleResult), IMD, 0.5e18)`.
The control plane runs the panel and calls `onOracleResult(intakeRequestId, a, sig)`, accepted only
from the Intake and only for a request this contract paid for; it then goes through the same checks
as `settle`. The body was checked against the free `POST /requests/check` on 2026-10-19 with no
blockers (the "not answerable" advisory was for rounds in the future). Anyone may also pay IMD
off-chain and submit the public attestation through `settle`. An empty reserve only makes
`requestOracle` revert; settlement, timeouts and claims never depend on it. `fundOracleReserve`
is open to anyone, and 1% of fee-paying volume refills it.

## Staking, tip jar and TEAM

The 5% staking share accrues to `pendingStakingFees` until TEAM sets the staking recipient (the
future MiningVault) once; the held amount moves to that recipient's pull balance on execution and
later fees accrue there directly. The 10% feed tip accrues the same way until the tip jar recipient
is set once. TEAM's 1% accrues to `balances[TEAM]`. Every recipient pulls with `withdraw()`.

## Mining history

`lossOf(k, account) = max(0, binary paid - refund entitlement - payout entitlement)`, netted across
OVER/UNDER and SNOOZE, EXACT excluded, computed from entitlements so it is identical before and
after claims; zero while a window is open and zero after a timeout. At chronological finalization
the contract stores `totalEligibleLoss[k]`, `cumulativeLossBefore[k]` and `cumulativeLossAfter[k]`
and emits `LossHistory`.

Deviation to note: the brief asks for no loops over users, but the sum of a netted `max(0, ·)`
rule cannot be derived from pool totals (the design review says the same). The contract therefore
caps distinct binary bettors at 256 per window and iterates that bounded list once at
finalization, the same bound the brief sets for EXACT tickets. The fuzz test checks the stored
total equals the sum of the per-account rule.

## Claims and conservation

`claim(k)` pays the caller's winnings, refunds and jackpot share for window `k`, never expires and
can be called again after the window's jackpot is finalized. Every incoming unit is assigned to a
bucket: `windowFunds[k]` (pools until paid or allocated), pull balances, `pendingStakingFees`,
`pendingTips`, `jackpotSeed`, `pendingJackpotDeposits`, `jackpotOutstanding` and `oracleReserve`.
Pro-rata floor division leaves at most one unit per payout in `windowFunds[k]` forever; the invariant
"IMD held >= all liabilities" is fuzzed in `test/Conservation.t.sol`. Reentrancy is guarded.

## After launch

| Setting | Calls (TEAM only, 12 h between schedule and execute) | Value |
| --- | --- | --- |
| Line | `scheduleLine(v)` then `executeLine(v)` | new OVER/UNDER line for later windows |
| Staking recipient, once | `scheduleStakingRecipient(a)` then `executeStakingRecipient(a)` | the deployed MiningVault (or an interim recipient) from its own deployment record |
| Tip jar, once | `scheduleTipRecipient(a)` then `executeTipRecipient(a)` | Squeektoshi's wallet |

Operational responsibilities: keep `oracleReserve` funded (24 settlements/day cost 12 IMD/day at
the current 0.5 IMD price), call `requestOracle(k)` after each window ends and `finalize(n)`
regularly, and watch `SettingScheduled` events. Nobody has to run a keeper for users to recover
timeout refunds. Tests are not an audit; an independent adversarial review is still required.

## Chosen values not fixed by the brief

`OPEN_AHEAD` 24 h, `ISSUED_AT_TOLERANCE` 300 s, `MAX_GUESS` `2^64 - 1`, `MAX_BINARY_BETTORS` 256,
source `https://sepolia.squeekchain.com` (as v1 and the live site), Intake body
`{"window":{"hours":24},"panelSize":5,"quorum":4,"validForSeconds":86400}`, pool cap `uint128`.

## Trust assumptions

- The attester key and panel are trusted for truth; a valid false answer is final. The timeout only
  covers absence. The attester is immutable: if IMD rotates it, a new deployment is needed and open
  windows refund at their timeout.
- The Intake address is immutable; if IMD moves it, requests can still be paid off-chain and
  settled through `settle`.
- TEAM's one-time staking recipient choice decides where the 5% share goes.

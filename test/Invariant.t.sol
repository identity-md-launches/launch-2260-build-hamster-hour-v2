// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIMD, MockIntake} from "./helpers/Mocks.sol";
import {HamsterHourConstants} from "./helpers/GameTest.sol";

/// @dev Drives HamsterHour with bounded random calls from several actors. Every call it makes is
/// meant to succeed (fail-on-revert is on), and the payouts it observes are checked inline.
contract HamsterHandler is Test {
    uint256 internal constant ATTESTER_KEY = 0xA11CE;
    uint64 internal constant GENESIS = 1791847200;

    HamsterHour public game;
    MockIMD public imd;
    MockIntake public intake;
    address public team;
    address public stakingTo = makeAddr("miningVault");
    address public tipTo = makeAddr("squeektoshi");
    address[4] public actors;

    uint256[] public windows; // every window index ever created
    mapping(uint256 => bool) public known;
    uint256 internal nextReq = 1;

    // ghosts
    uint256 public ghostIn; // IMD that entered the game through its functions
    uint256 public ghostOut; // IMD that left it (claims, withdrawals, oracle requests)
    uint256 public lastNextFinalize;
    bool public finalizeWentBackwards;
    bool public lossChangedOnClaim;
    bool public claimPaidWrong;
    bool public settledWindowReopened;
    mapping(uint256 => uint8) public lastStatus;
    uint256 public calls;
    uint256 public settles;
    uint256 public claims;
    uint256 public timeouts;

    constructor(HamsterHour game_, MockIMD imd_, MockIntake intake_, address team_) {
        game = game_;
        imd = imd_;
        intake = intake_;
        team = team_;
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        for (uint256 i; i < 4; ++i) {
            imd.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            imd.approve(address(game), type(uint256).max);
        }
    }

    function windowCount() external view returns (uint256) {
        return windows.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % 4];
    }

    function _track(uint256 k) internal {
        if (!known[k]) {
            known[k] = true;
            windows.push(k);
        }
    }

    /// @dev A window currently open for betting, 1..4 ahead of the earliest not started one.
    function _bettable(uint256 s) internal view returns (uint256) {
        return game.earliestNotStartedWindow() + (s % 4);
    }

    // ------------------------------------------------------------------ actions
    function bet(uint256 actorSeed, uint256 kSeed, bool snooze, bool side, uint256 amount) external {
        ++calls;
        uint256 k = _bettable(kSeed);
        amount = bound(amount, 0.5 ether, 200 ether);
        address a = _actor(actorSeed);
        vm.prank(a);
        if (snooze) game.betSnooze(k, side, amount);
        else game.betOverUnder(k, side, amount);
        ghostIn += amount;
        _track(k);
    }

    function ticket(uint256 actorSeed, uint256 kSeed, uint256 guess) external {
        ++calls;
        uint256 k = _bettable(kSeed);
        address a = _actor(actorSeed);
        if (game.position(k, a).hasTicket) return;
        // Cluster guesses near the results the settle action uses so jackpots are actually won.
        guess = bound(guess, 1980, 2130);
        vm.prank(a);
        game.buyTicket(k, guess);
        ghostIn += 5 ether;
        _track(k);
    }

    function settle(uint256 idxSeed, uint256 resultSeed) external {
        ++calls;
        if (windows.length == 0) return;
        (bool found, uint256 k) = _findSettleable(idxSeed);
        if (!found) return;
        HamsterHour.WindowView memory v = game.windowInfo(k);
        uint256[8] memory results = [uint256(0), 99, 100, v.line, v.line + 1, 2000, 2010, 1990];
        uint256 result = resultSeed % 3 == 0 ? bound(resultSeed, 0, 5000) : results[resultSeed % 8];
        (OracleAttestation.Attestation memory a, bytes memory sig) = _signed(k, result);
        game.settle(k, a, sig);
        ++settles;
    }

    function requestAndDeliver(uint256 idxSeed, uint256 resultSeed) external {
        ++calls;
        if (windows.length == 0) return;
        (bool found, uint256 k) = _findSettleable(idxSeed);
        if (!found || game.windowInfo(k).oracleRequested) return;
        if (game.oracleReserve() < 0.5 ether) return;
        bytes32 id = game.requestOracle(k);
        ghostOut += 0.5 ether;
        if (resultSeed % 4 == 0) return; // the panel never answers: the window will time out
        (OracleAttestation.Attestation memory a, bytes memory sig) = _signed(k, bound(resultSeed, 0, 4000));
        intake.deliver(id, a, sig);
        ++settles;
    }

    function timeout(uint256 idxSeed) external {
        ++calls;
        if (windows.length == 0) return;
        uint256 n = windows.length;
        for (uint256 i; i < n; ++i) {
            uint256 k = windows[(idxSeed % n + i) % n];
            HamsterHour.WindowView memory v = game.windowInfo(k);
            if (v.status != HamsterHour.Status.Open || block.timestamp < v.timeoutAt) continue;
            game.timeout(k);
            ++timeouts;
            return;
        }
    }

    function _findSettleable(uint256 seed) internal view returns (bool, uint256) {
        uint256 n = windows.length;
        for (uint256 i; i < n; ++i) {
            uint256 k = windows[(seed % n + i) % n];
            HamsterHour.WindowView memory v = game.windowInfo(k);
            if (v.status != HamsterHour.Status.Open) continue;
            if (block.timestamp < v.endsAt || block.timestamp >= v.timeoutAt) continue;
            return (true, k);
        }
        return (false, 0);
    }

    function finalize(uint256 n) external {
        ++calls;
        game.finalize(bound(n, 0, 64));
        uint256 next = game.nextFinalizeWindow();
        if (next < lastNextFinalize) finalizeWentBackwards = true;
        lastNextFinalize = next;
    }

    function claim(uint256 actorSeed, uint256 idxSeed) external {
        ++calls;
        if (windows.length == 0) return;
        address a = _actor(actorSeed);
        uint256 n = windows.length;
        uint256 k;
        uint256 due;
        for (uint256 i; i < n && due == 0; ++i) {
            k = windows[(idxSeed % n + i) % n];
            due = game.claimable(k, a);
        }
        if (due == 0) return;
        uint256 lossBefore = game.lossOf(k, a);
        uint256 balBefore = imd.balanceOf(a);
        vm.prank(a);
        game.claim(k);
        ++claims;
        uint256 got = imd.balanceOf(a) - balBefore;
        ghostOut += got;
        if (got != due) claimPaidWrong = true;
        if (game.claimable(k, a) != 0) claimPaidWrong = true;
        if (game.lossOf(k, a) != lossBefore) lossChangedOnClaim = true;
    }

    function withdraw(uint256 who) external {
        ++calls;
        address a = [team, stakingTo, tipTo][who % 3];
        uint256 due = game.balances(a);
        if (due == 0) return;
        vm.prank(a);
        game.withdraw();
        ghostOut += due;
    }

    function feed(uint256 actorSeed, uint256 amount) external {
        ++calls;
        amount = bound(amount, 1, 100 ether);
        vm.prank(_actor(actorSeed));
        game.feedHamster(amount);
        ghostIn += amount;
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        ++calls;
        amount = bound(amount, 1, 100 ether);
        vm.prank(_actor(actorSeed));
        game.depositJackpot(amount);
        ghostIn += amount;
    }

    function fundOracle(uint256 actorSeed, uint256 amount) external {
        ++calls;
        amount = bound(amount, 1, 3 ether);
        vm.prank(_actor(actorSeed));
        game.fundOracleReserve(amount);
        ghostIn += amount;
    }

    function setRecipients(bool staking) external {
        ++calls;
        if (staking) {
            if (game.stakingRecipient() != address(0)) return;
            (, uint64 readyAt) = game.pendingSetting(game.SETTING_STAKING());
            if (readyAt != 0 && block.timestamp < readyAt) return;
            vm.prank(team);
            if (readyAt == 0) game.scheduleStakingRecipient(stakingTo);
            else game.executeStakingRecipient(stakingTo);
        } else {
            if (game.tipRecipient() != address(0)) return;
            (, uint64 readyAt) = game.pendingSetting(game.SETTING_TIP());
            if (readyAt != 0 && block.timestamp < readyAt) return;
            vm.prank(team);
            if (readyAt == 0) game.scheduleTipRecipient(tipTo);
            else game.executeTipRecipient(tipTo);
        }
    }

    function warp(uint256 dt) external {
        ++calls;
        vm.warp(block.timestamp + bound(dt, 1, 12 hours));
        _recordStatuses();
    }

    /// @dev Jumps to the next interesting instant of some open window: its end, or its timeout.
    function jump(uint256 idxSeed, bool toTimeout) external {
        ++calls;
        uint256 n = windows.length;
        for (uint256 i; i < n; ++i) {
            HamsterHour.WindowView memory v = game.windowInfo(windows[(idxSeed % n + i) % n]);
            if (v.status != HamsterHour.Status.Open) continue;
            uint256 t = toTimeout ? v.timeoutAt : v.endsAt;
            if (t > block.timestamp) {
                vm.warp(t);
                _recordStatuses();
                return;
            }
        }
    }

    function _recordStatuses() internal {
        for (uint256 i; i < windows.length; ++i) {
            uint256 k = windows[i];
            uint8 s = uint8(game.windowInfo(k).status);
            if (lastStatus[k] >= 2 && s != lastStatus[k]) settledWindowReopened = true;
            lastStatus[k] = s;
        }
    }

    // ------------------------------------------------------------------ oracle
    function _signed(uint256 k, uint256 result)
        internal
        returns (OracleAttestation.Attestation memory a, bytes memory sig)
    {
        a.requestId = bytes32(uint256(keccak256(abi.encode("inv", nextReq++))));
        a.chainId = block.chainid;
        a.fromBlock = 10;
        a.toBlock = 20;
        a.questionHash = game.questionHash(k, a.fromBlock, a.toBlock);
        a.answerType = 3;
        a.answer = abi.encode(result);
        a.figure = result;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp) + 1 days;
        bytes32 domain = keccak256(
            abi.encode(
                OracleAttestation.DOMAIN_TYPEHASH,
                OracleAttestation.NAME_HASH,
                OracleAttestation.VERSION_HASH,
                block.chainid,
                address(game)
            )
        );
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    OracleAttestation.TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ATTESTER_KEY, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
        sig = abi.encodePacked(r, s, v);
    }
}

/// @dev Conservation and ordering invariants over random call sequences.
contract HamsterInvariantTest is Test {
    uint64 internal constant GENESIS = 1791847200;
    HamsterHour internal game;
    MockIMD internal imd;
    HamsterHandler internal handler;

    function setUp() public {
        vm.chainId(1);
        MockIMD impl = new MockIMD();
        vm.etch(HamsterHourConstants.IMD, address(impl).code);
        imd = MockIMD(HamsterHourConstants.IMD);
        MockIntake intake = new MockIntake(address(imd), 0.5 ether);
        address team = makeAddr("team");
        game = new HamsterHour(team, vm.addr(0xA11CE), address(intake));
        vm.warp(GENESIS - 2 hours);
        handler = new HamsterHandler(game, imd, intake, team);
        targetContract(address(handler));
    }

    /// @dev Window funds still held for a settled window's jackpot until its finalization:
    /// its 93% ticket contribution plus 2% of each fee-paying binary pool.
    function _inFlight(uint256 k) internal view returns (uint256) {
        HamsterHour.WindowView memory v = game.windowInfo(k);
        if (v.status != HamsterHour.Status.Settled || v.jackpotFinalized) return 0;
        uint256 x = v.tickets * 5 ether * 93 / 100;
        if (!v.ouVoid) x += (v.over + v.under) * 2 / 100;
        if (!v.snVoid) x += (v.yes + v.no) * 2 / 100;
        return x;
    }

    function _accounted() internal view returns (uint256 total) {
        total = game.trackedLiabilities();
        uint256 n = handler.windowCount();
        for (uint256 i; i < n; ++i) {
            uint256 k = handler.windows(i);
            total += game.windowFunds(k) + _inFlight(k);
        }
        // Pending deposits can sit on windows nobody bet on.
        uint256 e = game.earliestNotStartedWindow();
        uint256 from = game.nextFinalizeWindow();
        for (uint256 k = from; k <= e; ++k) {
            total += game.pendingJackpotDeposits(k);
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balanceEqualsEveryBucket() public view {
        uint256 held = imd.balanceOf(address(game));
        assertEq(held, handler.ghostIn() - handler.ghostOut(), "token flow");
        assertEq(held, _accounted(), "IMD held == sum of all buckets");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_heldCoversEveryClaim() public view {
        uint256 owed = game.trackedLiabilities() - game.jackpotOutstanding();
        uint256 n = handler.windowCount();
        uint256 outstandingShares;
        for (uint256 i; i < n; ++i) {
            uint256 k = handler.windows(i);
            uint256 windowOwed;
            for (uint256 j; j < 4; ++j) {
                address a = handler.actors(j);
                uint256 c = game.claimable(k, a);
                HamsterHour.Position memory p = game.position(k, a);
                HamsterHour.WindowView memory v = game.windowInfo(k);
                uint256 share;
                if (
                    p.hasTicket && !p.jackpotPaid && v.jackpotFinalized && v.jackpotShare > 0
                        && game.isWinningGuess(p.guess, v.result)
                ) share = v.jackpotShare;
                outstandingShares += share;
                windowOwed += c - share;
            }
            assertLe(windowOwed, game.windowFunds(k), "window pays out at most what it holds");
            owed += windowOwed;
        }
        assertEq(game.jackpotOutstanding(), outstandingShares, "jackpot liabilities == unpaid winning shares");
        assertGe(imd.balanceOf(address(game)), owed + outstandingShares, "IMD held >= all liabilities");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_historyAndOrdering() public view {
        assertFalse(handler.finalizeWentBackwards(), "finalize cursor only moves forward");
        assertFalse(handler.lossChangedOnClaim(), "lossOf stable across claims");
        assertFalse(handler.claimPaidWrong(), "claim pays exactly claimable once");
        assertFalse(handler.settledWindowReopened(), "terminal status never changes");
        uint256 next = game.nextFinalizeWindow();
        uint256 n = handler.windowCount();
        for (uint256 i; i < n; ++i) {
            uint256 k = handler.windows(i);
            HamsterHour.WindowView memory v = game.windowInfo(k);
            assertEq(v.jackpotFinalized, k < next, "exactly the windows below the cursor are finalized");
            if (k < next) {
                assertTrue(v.status != HamsterHour.Status.Open, "finalized windows are terminal");
                assertEq(
                    game.cumulativeLossAfter(k),
                    game.cumulativeLossBefore(k) + game.totalEligibleLoss(k),
                    "after = before + eligible"
                );
                uint256 sum;
                for (uint256 j; j < 4; ++j) {
                    sum += game.lossOf(k, handler.actors(j));
                }
                assertEq(game.totalEligibleLoss(k), sum, "stored loss == sum of lossOf");
                if (v.status == HamsterHour.Status.TimedOut) assertEq(game.totalEligibleLoss(k), 0);
            }
        }
        if (next > 0) assertEq(game.cumulativeLoss(), game.cumulativeLossAfter(next - 1));
        for (uint256 k = 1; k < next; ++k) {
            assertEq(game.cumulativeLossBefore(k), game.cumulativeLossAfter(k - 1), "chronological chain");
        }
    }
}

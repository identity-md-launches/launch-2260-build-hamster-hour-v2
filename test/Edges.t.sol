// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev Boundaries and failure paths the other suites do not reach: exact time edges, results
/// 0/99/100/line on both binary markets at once, malformed attestations, double claims, callers
/// who are not who the code assumes, and the property-level edges of the EXACT band.
contract EdgesTest is GameTest {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _clone(OracleAttestation.Attestation memory a)
        internal
        pure
        returns (OracleAttestation.Attestation memory b)
    {
        b = abi.decode(abi.encode(a), (OracleAttestation.Attestation));
    }

    function _fourWay(uint256 k) internal {
        _ou(alice, k, true, 10 ether);
        _ou(bob, k, false, 30 ether);
        _sn(alice, k, true, 20 ether);
        _sn(bob, k, false, 20 ether);
    }

    // ------------------------------------------------------------------ time edges
    function test_settleWindowIsHalfOpen() public {
        _fourWay(0);
        uint64 end = game.windowEnd(0);
        // Last second of the settle window still settles.
        vm.warp(end + 48 hours - 1);
        OracleAttestation.Attestation memory a = _attestation(0, 2500, end);
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.timeout(0);
        vm.warp(end + 48 hours);
        // At end + 48h only a timeout is possible, even with a perfectly valid attestation.
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.requestOracle(0);
        game.timeout(0);
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.timeout(0);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        assertEq(_claim(alice, 0), 30 ether);
        assertEq(_claim(bob, 0), 50 ether);
        assertEq(game.balances(team), 0, "timeout takes no fees");
        assertEq(game.oracleReserve(), 0);
        assertEq(game.pendingStakingFees(), 0);
    }

    function test_settleAtLastSecondSucceeds() public {
        _fourWay(0);
        uint64 end = game.windowEnd(0);
        vm.warp(end + 48 hours - 1);
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        game.settle(0, a, _sign(a, ATTESTER_KEY, address(game)));
        assertEq(uint8(game.windowInfo(0).status), uint8(HamsterHour.Status.Settled));
        vm.warp(end + 48 hours);
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.timeout(0);
    }

    function test_cannotSettleOrTimeoutUncreatedWindow() public {
        vm.warp(game.windowEnd(0) + 48 hours);
        OracleAttestation.Attestation memory a = _attestation(0, 2500, game.windowEnd(0));
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.timeout(0);
        vm.expectRevert(HamsterHour.NotFinal.selector);
        vm.prank(alice);
        game.claim(0);
        assertEq(game.claimable(0, alice), 0);
    }

    function test_bettingHorizonExactlyTwentyFourHours() public {
        uint64 start5 = game.windowStart(30);
        vm.warp(start5 - 24 hours - 1);
        assertFalse(game.isBettingOpen(30));
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ticket(alice, 30, 2000);
        vm.warp(start5 - 24 hours);
        _ticket(alice, 30, 2000);
        _sn(alice, 30, true, 0.5 ether);
        vm.warp(start5);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ticket(bob, 30, 2000);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _sn(bob, 30, true, 1 ether);
    }

    function test_cannotBetOnPastOrRunningWindow() public {
        vm.warp(GENESIS + 30 minutes); // window 0 running
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ou(alice, 0, true, 1 ether);
        assertEq(game.currentWindow(), 0);
        assertEq(game.earliestNotStartedWindow(), 1);
        _ou(alice, 1, true, 1 ether);
    }

    // ------------------------------------------------------------------ results 0/99/100/line
    function test_resultZeroBothMarkets() public {
        _fourWay(0);
        _ticket(carol, 0, 0);
        _settle(0, 0);
        HamsterHour.WindowView memory v = game.windowInfo(0);
        assertTrue(v.ouVoid, "asleep voids OVER/UNDER");
        assertFalse(v.snVoid);
        // Alice: OU 10 refunded + YES wins the whole SNOOZE pool less fees.
        assertEq(game.claimable(0, alice), 10 ether + 40 ether * 91 / 100);
        assertEq(game.claimable(0, bob), 30 ether);
        assertEq(game.lossOf(0, bob), 20 ether);
        assertEq(game.lossOf(0, alice), 0);
        // Fees only on SNOOZE.
        assertEq(game.balances(team), 40 ether / 100 + TICKET / 100);
        game.finalize(1);
        assertEq(game.windowInfo(0).jackpotWinners, 0, "guess 0 never wins an asleep window");
    }

    function test_result99And100Boundary() public {
        _fourWay(0);
        _fourWay(1);
        _settle(0, 99);
        _settle(1, 100);
        assertTrue(game.windowInfo(0).ouVoid);
        assertFalse(game.windowInfo(1).ouVoid, "100 is awake");
        // 99: YES wins.
        assertEq(game.claimable(0, alice), 10 ether + 40 ether * 91 / 100);
        // 100 <= line: UNDER and NO win.
        assertEq(game.claimable(1, alice), 0);
        assertEq(game.claimable(1, bob), 40 ether * 91 / 100 + 40 ether * 91 / 100);
        assertEq(game.lossOf(1, alice), 30 ether);
        assertEq(game.lossOf(1, bob), 0);
    }

    function test_resultAtLineAndAfterLineChangeUsesSnapshot() public {
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        vm.prank(team);
        game.scheduleLine(3000);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        game.executeLine(3000);
        // Window 0 keeps 2100: 2101 is OVER even though the live line is now 3000.
        _settle(0, 2101);
        assertEq(game.windowInfo(0).line, 2100);
        assertEq(game.claimable(0, alice), 20 ether * 91 / 100);
        assertEq(game.claimable(0, bob), 0);
        // A window created later uses 3000: exactly 3000 is UNDER.
        uint256 k = game.earliestNotStartedWindow();
        _ou(alice, k, true, 10 ether);
        _ou(bob, k, false, 10 ether);
        _settle(k, 3000);
        assertEq(game.windowInfo(k).line, 3000);
        assertEq(game.claimable(k, bob), 20 ether * 91 / 100);
        assertEq(game.claimable(k, alice), 0);
    }

    // ------------------------------------------------------------------ claims
    function test_claimTwiceAndClaimByStranger() public {
        _fourWay(0);
        _settle(0, 2500);
        uint256 got = _claim(alice, 0);
        assertEq(got, 40 ether * 91 / 100);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(carol);
        game.claim(0);
        vm.expectRevert(HamsterHour.NotFinal.selector);
        vm.prank(alice);
        game.claim(1);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(carol);
        game.withdraw();
    }

    function test_jackpotClaimAfterBaseClaim() public {
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        _ticket(alice, 0, 2500);
        _settle(0, 2500);
        // Base claim before finalization, jackpot claim after.
        assertEq(_claim(alice, 0), 20 ether * 91 / 100);
        assertEq(game.claimable(0, alice), 0);
        game.finalize(1);
        uint256 pot = TICKET * 93 / 100 + 20 ether * 2 / 100;
        assertEq(game.windowInfo(0).jackpotPot, pot);
        assertEq(_claim(alice, 0), pot * 80 / 100);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0);
        assertEq(game.jackpotOutstanding(), 0);
    }

    function test_jackpotSplitDustCarries() public {
        // Three winners: share is floored, the dust stays in the seed.
        _ticket(alice, 0, 2000);
        _ticket(bob, 0, 2001);
        _ticket(carol, 0, 1999);
        vm.prank(keeper);
        game.depositJackpot(1 ether + 1);
        _settle(0, 2000);
        game.finalize(1);
        uint256 pot = 1 ether + 1 + 3 * TICKET * 93 / 100;
        uint256 share = pot * 80 / 100 / 3;
        assertEq(game.windowInfo(0).jackpotShare, share);
        assertEq(game.jackpotSeed(), pot - 3 * share);
        assertEq(game.jackpotOutstanding(), 3 * share);
    }

    // ------------------------------------------------------------------ oracle failure paths
    function test_attestationEdgeRejections() public {
        _fourWay(0);
        uint64 end = game.windowEnd(0);
        vm.warp(end + 1 hours);
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        bytes memory good = _sign(a, ATTESTER_KEY, address(game));

        // A 64-byte answer is not a typed uint256.
        OracleAttestation.Attestation memory bad = _clone(a);
        bad.answer = abi.encode(uint256(2500), uint256(1));
        vm.expectRevert(HamsterHour.InvalidAnswer.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        // agreed greater than the panel.
        bad = _clone(a);
        bad.panelSize = 5;
        bad.agreed = 6;
        vm.expectRevert(HamsterHour.WeakPanel.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        // quorum zero.
        bad = _clone(a);
        bad.quorum = 0;
        vm.expectRevert(HamsterHour.WeakPanel.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        // issued in the future beyond tolerance.
        bad = _clone(a);
        bad.issuedAt = uint64(block.timestamp) + 5 minutes + 1;
        bad.expiresAt = bad.issuedAt + 1 days;
        vm.expectRevert(HamsterHour.InvalidValidity.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        // expired.
        bad = _clone(a);
        bad.expiresAt = uint64(block.timestamp) - 1;
        bad.issuedAt = end;
        vm.expectRevert(HamsterHour.InvalidValidity.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        // A field tampered after signing.
        bad = _clone(a);
        bad.answer = abi.encode(uint256(50));
        bad.figure = 50;
        vm.expectRevert(HamsterHour.BadSignature.selector);
        game.settle(0, bad, good);

        // Malleated high-s twin of the good signature.
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(good, 32))
            s := mload(add(good, 64))
            v := byte(0, mload(add(good, 96)))
        }
        bytes memory twin = abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(HamsterHour.BadSignature.selector);
        game.settle(0, a, twin);

        // Same request signed for another chain id in the domain.
        vm.chainId(11155111);
        bytes memory otherChain = _sign(a, ATTESTER_KEY, address(game));
        vm.chainId(1);
        vm.expectRevert(HamsterHour.BadSignature.selector);
        game.settle(0, a, otherChain);

        // expiresAt == now still accepted.
        OracleAttestation.Attestation memory edge = _clone(a);
        edge.expiresAt = uint64(block.timestamp);
        game.settle(0, edge, _sign(edge, ATTESTER_KEY, address(game)));
        assertEq(game.windowInfo(0).result, 2500);
    }

    function test_attestationForOtherConsumerIsRefused() public {
        _fourWay(0);
        HamsterHour twin = new HamsterHour(team, attester, address(intake));
        _settle(0, 2500);
        // The identical attestation signed for this game cannot settle a second deployment.
        vm.prank(alice);
        imd.approve(address(twin), type(uint256).max);
        vm.warp(GENESIS - 1 hours);
        vm.prank(alice);
        twin.betOverUnder(0, true, 1 ether);
        vm.warp(game.windowEnd(0));
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        vm.expectRevert(HamsterHour.BadSignature.selector);
        twin.settle(0, a, _sign(a, ATTESTER_KEY, address(game)));
    }

    function test_callbackAfterManualSettleOrTimeoutReverts() public {
        _fourWay(0);
        vm.warp(game.windowEnd(0));
        vm.prank(carol);
        game.fundOracleReserve(1 ether);
        bytes32 id = game.requestOracle(0);
        // Someone settles directly first; the late callback is refused, no double settle.
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        game.settle(0, a, _sign(a, ATTESTER_KEY, address(game)));
        OracleAttestation.Attestation memory b = _attestation(0, 50, uint64(block.timestamp));
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        intake.deliver(id, b, _sign(b, ATTESTER_KEY, address(game)));
        assertEq(game.windowInfo(0).result, 2500);

        // A callback that arrives after the timeout is refused too.
        _ou(alice, 20, true, 1 ether);
        vm.warp(game.windowEnd(20));
        bytes32 id20 = game.requestOracle(20);
        vm.warp(game.windowEnd(20) + 48 hours);
        OracleAttestation.Attestation memory c = _attestation(20, 2500, game.windowEnd(20));
        c.expiresAt = uint64(block.timestamp) + 1;
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        intake.deliver(id20, c, _sign(c, ATTESTER_KEY, address(game)));
        game.timeout(20);
        assertEq(_claim(alice, 20), 1 ether);
    }

    function test_callbackForOneWindowCannotSettleAnother() public {
        _fourWay(0);
        _fourWay(1);
        vm.warp(game.windowEnd(1));
        vm.prank(carol);
        game.fundOracleReserve(1 ether);
        bytes32 id0 = game.requestOracle(0);
        // A result for window 1's question delivered on window 0's request id is the wrong question.
        OracleAttestation.Attestation memory a = _attestation(1, 50, uint64(block.timestamp));
        vm.expectRevert(HamsterHour.WrongQuestion.selector);
        intake.deliver(id0, a, _sign(a, ATTESTER_KEY, address(game)));
    }

    // ------------------------------------------------------------------ TEAM powers
    function test_teamPowersAreOnlyTimelockedSettings() public {
        address[3] memory others = [alice, attester, address(intake)];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(HamsterHour.NotTeam.selector);
            game.executeLine(2100);
            vm.expectRevert(HamsterHour.NotTeam.selector);
            game.scheduleStakingRecipient(alice);
            vm.expectRevert(HamsterHour.NotTeam.selector);
            game.executeStakingRecipient(alice);
            vm.expectRevert(HamsterHour.NotTeam.selector);
            game.scheduleTipRecipient(alice);
            vm.expectRevert(HamsterHour.NotTeam.selector);
            game.executeTipRecipient(alice);
            vm.stopPrank();
        }
        // Executing without a schedule, or a different value than scheduled, fails.
        vm.startPrank(team);
        vm.expectRevert(HamsterHour.NothingScheduled.selector);
        game.executeTipRecipient(carol);
        game.scheduleTipRecipient(carol);
        vm.warp(block.timestamp + 12 hours);
        vm.expectRevert(HamsterHour.NothingScheduled.selector);
        game.executeTipRecipient(bob);
        // Re-scheduling restarts the 12h clock.
        game.scheduleTipRecipient(bob);
        vm.expectRevert(HamsterHour.NothingScheduled.selector);
        game.executeTipRecipient(carol);
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.executeTipRecipient(bob);
        vm.warp(block.timestamp + 12 hours);
        game.executeTipRecipient(bob);
        vm.expectRevert(HamsterHour.AlreadySet.selector);
        game.scheduleTipRecipient(carol);
        vm.expectRevert(HamsterHour.AlreadySet.selector);
        game.executeTipRecipient(bob);
        vm.stopPrank();
        assertEq(game.tipRecipient(), bob);
        // TEAM cannot pull anything beyond its own accrued 1%.
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(team);
        game.withdraw();
    }

    function test_stakingFeesHeldUntilRecipientThenForwarded() public {
        _fourWay(0);
        _ticket(carol, 0, 1);
        _settle(0, 2500);
        uint256 held = 80 ether * 5 / 100 + TICKET * 5 / 100;
        assertEq(game.pendingStakingFees(), held);
        vm.prank(team);
        game.scheduleStakingRecipient(keeper);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        game.executeStakingRecipient(keeper);
        uint256 before = imd.balanceOf(keeper);
        vm.prank(keeper);
        game.withdraw();
        assertEq(imd.balanceOf(keeper) - before, held);
    }

    // ------------------------------------------------------------------ deposits
    function test_depositsGoToEarliestNotStartedWindowAtBoundaries() public {
        vm.warp(GENESIS - 1);
        vm.prank(alice);
        game.depositJackpot(1 ether);
        assertEq(game.pendingJackpotDeposits(0), 1 ether);
        vm.warp(GENESIS);
        vm.prank(alice);
        game.depositJackpot(2 ether);
        assertEq(game.pendingJackpotDeposits(1), 2 ether, "window 0 started at GENESIS");
        vm.warp(GENESIS + HOUR - 1);
        vm.prank(alice);
        game.feedHamster(10);
        assertEq(game.pendingJackpotDeposits(1), 2 ether + 9);
        assertEq(game.pendingTips(), 1);
        // A 9-wei feed has a zero tip: everything goes to the jackpot.
        vm.prank(alice);
        game.feedHamster(9);
        assertEq(game.pendingJackpotDeposits(1), 2 ether + 18);
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        vm.prank(alice);
        game.depositJackpot(0);
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        vm.prank(alice);
        game.fundOracleReserve(0);
    }

    function test_depositCannotChangeAFixedPrize() public {
        _ticket(alice, 0, 2000);
        _settle(0, 2000);
        // After settlement, a donation goes to a later window, never into window 0's pot.
        vm.prank(bob);
        game.depositJackpot(1000 ether);
        game.finalize(1);
        assertEq(game.windowInfo(0).jackpotPot, TICKET * 93 / 100);
    }

    function test_finalizeZeroIsNoop() public {
        _ticket(alice, 0, 2000);
        _settle(0, 2000);
        game.finalize(0);
        assertEq(game.nextFinalizeWindow(), 0);
        game.finalize(type(uint256).max);
        assertEq(game.nextFinalizeWindow(), 1, "unbounded request still stops at the first open window");
    }

    // ------------------------------------------------------------------ fuzz
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactBandFullRange(uint256 guess, uint256 result) public view {
        bool expected;
        uint256 diff = guess > result ? guess - result : result - guess;
        // |g - r| * 1000 <= r * 5 in 512-bit terms: compare diff * 200 <= r without overflow.
        expected = diff <= result / 200;
        assertEq(game.isWinningGuess(guess, result), expected);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_binaryPayoutsNeverExceedPool(uint96 o, uint96 u, uint96 y, uint96 n, uint256 result) public {
        uint256 over_ = bound(o, 0.5 ether, 1e27);
        uint256 under_ = bound(u, 0.5 ether, 1e27);
        uint256 yes_ = bound(y, 0.5 ether, 1e27);
        uint256 no_ = bound(n, 0.5 ether, 1e27);
        result = bound(result, 0, 5000);
        imd.mint(alice, 4e27);
        imd.mint(bob, 4e27);
        _ou(alice, 0, true, over_);
        _ou(bob, 0, false, under_);
        _sn(alice, 0, true, yes_);
        _sn(bob, 0, false, no_);
        _settle(0, result);
        uint256 paidOut = game.claimable(0, alice) + game.claimable(0, bob);
        uint256 lost = game.lossOf(0, alice) + game.lossOf(0, bob);
        uint256 total = over_ + under_ + yes_ + no_;
        assertLe(paidOut, game.windowFunds(0));
        // Fees taken never exceed 9% of the fee-paying pools, and claims + fees + dust == stakes.
        uint256 fees = game.balances(team) + game.pendingStakingFees() + game.oracleReserve();
        uint256 feePools = (result < 100 ? 0 : over_ + under_) + yes_ + no_;
        assertLe(fees, feePools * 7 / 100);
        assertLe(game.windowFunds(0) - paidOut, 4, "at most one unit of dust per pro-rata payout");
        // Net loss across both wallets equals what left the two of them (fees + jackpot share + dust).
        assertLe(lost, total);
        assertGe(lost + paidOut, total);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract MarketsTest is GameTest {
    function test_windowTimesAndBettingHorizon() public {
        assertEq(game.windowStart(0), GENESIS);
        assertEq(game.windowEnd(0), GENESIS + HOUR);
        assertEq(game.windowStart(7), GENESIS + 7 * HOUR);
        // One hour before genesis: windows 0..23 open (start <= now + 24h), 24 is too far.
        assertTrue(game.isBettingOpen(0));
        assertTrue(game.isBettingOpen(23));
        assertFalse(game.isBettingOpen(24));
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ou(alice, 24, true, 1 ether);
        // Betting closes strictly at window start.
        vm.warp(GENESIS - 1);
        _ou(alice, 0, true, 1 ether);
        vm.warp(GENESIS);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ou(bob, 0, false, 1 ether);
        assertFalse(game.isBettingOpen(0));
        vm.expectRevert(HamsterHour.BelowMinimum.selector);
        _ou(bob, 1, false, 0.5 ether - 1);
        _ou(bob, 1, false, 0.5 ether);
    }

    function test_windowSnapshotsLineAtCreation() public {
        _ou(alice, 0, true, 1 ether);
        vm.prank(team);
        game.scheduleLine(2500);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        game.executeLine(2500);
        _ou(alice, 13, true, 1 ether);
        assertEq(game.windowInfo(0).line, 2100);
        assertEq(game.windowInfo(13).line, 2500);
    }

    function test_overUnderOutcomesAtLine() public {
        // Result exactly at the line is UNDER; above is OVER.
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 30 ether);
        _ou(alice, 1, true, 10 ether);
        _ou(bob, 1, false, 30 ether);
        _settle(0, 2100);
        assertEq(game.windowInfo(0).result, 2100);
        assertEq(game.claimable(0, alice), 0);
        assertEq(game.claimable(0, bob), 40 ether * 91 / 100);
        assertEq(game.lossOf(0, alice), 10 ether);
        assertEq(game.lossOf(0, bob), 0);

        _settle(1, 2101);
        assertEq(game.claimable(1, alice), 40 ether * 91 / 100);
        assertEq(game.claimable(1, bob), 0);
        assertEq(game.lossOf(1, bob), 30 ether);
    }

    function test_snoozeAt0_99_100() public {
        uint256[3] memory results = [uint256(0), 99, 100];
        for (uint256 k; k < 3; ++k) {
            _sn(alice, k, true, 10 ether);
            _sn(bob, k, false, 10 ether);
            _ou(carol, k, true, 1 ether);
            _ou(keeper, k, false, 1 ether);
        }
        for (uint256 k; k < 3; ++k) {
            _settle(k, results[k]);
        }
        // 0 and 99 are asleep: YES wins, OVER/UNDER refunded fully with no fees.
        for (uint256 k; k < 2; ++k) {
            assertEq(game.claimable(k, alice), 20 ether * 91 / 100, "yes wins");
            assertEq(game.claimable(k, bob), 0);
            assertTrue(game.windowInfo(k).ouVoid);
            assertEq(game.claimable(k, carol), 1 ether);
            assertEq(game.claimable(k, keeper), 1 ether);
            assertEq(game.lossOf(k, carol), 0, "refund is not a loss");
            assertEq(game.lossOf(k, bob), 10 ether);
        }
        // 100 is awake: NO wins, OVER/UNDER settles (100 <= 2100 so UNDER).
        assertEq(game.claimable(2, bob), 20 ether * 91 / 100);
        assertEq(game.claimable(2, alice), 0);
        assertFalse(game.windowInfo(2).ouVoid);
        assertEq(game.claimable(2, keeper), 2 ether * 91 / 100);
        assertEq(game.claimable(2, carol), 0);
    }

    function test_feeSplitBinary() public {
        _ou(alice, 0, true, 100 ether);
        _ou(bob, 0, false, 100 ether);
        _settle(0, 3000);
        assertEq(game.pendingStakingFees(), 10 ether);
        assertEq(game.windowInfo(0).jackpotFinalized, false);
        assertEq(game.oracleReserve(), 2 ether);
        assertEq(game.balances(team), 2 ether);
        assertEq(game.claimable(0, alice), 182 ether);
        game.finalize(1);
        assertEq(game.jackpotSeed(), 4 ether, "2% of the binary pool carries when nobody wins");
        uint256 before = imd.balanceOf(team);
        vm.prank(team);
        game.withdraw();
        assertEq(imd.balanceOf(team) - before, 2 ether);
    }

    function test_oneSidedPoolsRefundFully() public {
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, true, 5 ether);
        _sn(carol, 0, false, 3 ether);
        _settle(0, 2500);
        assertTrue(game.windowInfo(0).ouVoid);
        assertTrue(game.windowInfo(0).snVoid);
        assertEq(_claim(alice, 0), 10 ether);
        assertEq(_claim(bob, 0), 5 ether);
        assertEq(_claim(carol, 0), 3 ether);
        assertEq(game.balances(team), 0);
        assertEq(game.lossOf(0, alice), 0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0);
    }

    function test_timeoutRefundsEverythingWithoutFees() public {
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        _sn(bob, 0, true, 4 ether);
        _ticket(carol, 0, 2000);
        uint64 end = game.windowEnd(0);
        vm.warp(end + 48 hours - 1);
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.timeout(0);
        vm.expectRevert(HamsterHour.NotFinal.selector);
        vm.prank(alice);
        game.claim(0);
        vm.warp(end + 48 hours);
        // At exactly end + 48h settlement is closed and the timeout is open.
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        game.timeout(0);
        assertEq(_claim(alice, 0), 10 ether);
        assertEq(_claim(bob, 0), 14 ether);
        assertEq(_claim(carol, 0), TICKET);
        assertEq(game.lossOf(0, alice), 0);
        assertEq(game.balances(team), 0);
        assertEq(game.oracleReserve(), 0);
        assertEq(game.windowFunds(0), 0);
    }

    function test_twoWalletHedgeAndLossNetting() public {
        // Alice hedges across both markets: loses 10 on UNDER, wins on NO.
        _ou(alice, 0, false, 10 ether);
        _ou(bob, 0, true, 10 ether);
        _sn(alice, 0, false, 10 ether);
        _sn(carol, 0, true, 10 ether);
        // A wallet that bets both sides of one market (window 1) reports only the fee as loss.
        _ou(alice, 1, true, 10 ether);
        _ou(alice, 1, false, 10 ether);
        _settle(0, 2500);
        // Alice: paid 20, gets 18.2 from NO; net loss 1.8 (the fee), not 10.
        uint256 noPayout = 20 ether * 91 / 100;
        assertEq(game.claimable(0, alice), noPayout);
        assertEq(game.lossOf(0, alice), 20 ether - noPayout);
        assertEq(game.lossOf(0, carol), 10 ether);
        assertEq(game.lossOf(0, bob), 0);
        // Stable across claims.
        _claim(0 == 0 ? alice : bob, 0);
        assertEq(game.lossOf(0, alice), 20 ether - noPayout);
        game.finalize(1);
        assertEq(game.totalEligibleLoss(0), 20 ether - noPayout + 10 ether);
        assertEq(game.cumulativeLossBefore(0), 0);
        assertEq(game.cumulativeLossAfter(0), 20 ether - noPayout + 10 ether);
        assertEq(game.lossOf(0, alice), 20 ether - noPayout, "stable after finalization");
        _settle(1, 2500);
        assertEq(game.lossOf(1, alice), 20 ether - 20 ether * 91 / 100);
        game.finalize(1);
        assertEq(game.totalEligibleLoss(1), 20 ether - 20 ether * 91 / 100);
        assertEq(game.cumulativeLossBefore(1), game.cumulativeLossAfter(0));
    }

    function test_exactTicketRules() public {
        vm.expectRevert(HamsterHour.InvalidGuess.selector);
        _ticket(alice, 0, uint256(type(uint64).max) + 1);
        _ticket(alice, 0, 2000);
        vm.expectRevert(HamsterHour.DuplicateTicket.selector);
        _ticket(alice, 0, 2001);
        assertEq(game.windowInfo(0).tickets, 1);
        assertEq(game.windowFunds(0), TICKET);
        for (uint256 i = 1; i < 256; ++i) {
            address who = address(uint160(0x10000 + i));
            imd.mint(who, TICKET);
            vm.prank(who);
            imd.approve(address(game), TICKET);
            _ticket(who, 0, 2000 + i);
        }
        imd.mint(bob, TICKET);
        vm.expectRevert(HamsterHour.TicketsFull.selector);
        _ticket(bob, 0, 1);
    }

    function test_exactToleranceEdges() public view {
        // |g - r| * 1000 <= r * 5  <=>  |g - r| * 200 <= r
        assertTrue(game.isWinningGuess(1990, 2000));
        assertFalse(game.isWinningGuess(1989, 2000));
        assertTrue(game.isWinningGuess(2010, 2000));
        assertFalse(game.isWinningGuess(2011, 2000));
        assertTrue(game.isWinningGuess(2110, 2100));
        assertFalse(game.isWinningGuess(2111, 2100));
        assertTrue(game.isWinningGuess(2090, 2100));
        assertFalse(game.isWinningGuess(2089, 2100));
        assertTrue(game.isWinningGuess(0, 0));
        assertFalse(game.isWinningGuess(1, 0));
        assertFalse(game.isWinningGuess(0, type(uint256).max));
        assertTrue(game.isWinningGuess(type(uint256).max, type(uint256).max));
    }

    function test_exactPaysOnlyWithinBandAndNeverWhenAsleep() public {
        _ticket(alice, 0, 2100); // in band for 2100 (diff 0)
        _ticket(bob, 0, 2111); // out of band (diff 11)
        _ticket(carol, 0, 2090); // in band (diff 10)
        _ticket(alice, 1, 50);
        _settle(0, 2100);
        game.finalize(1);
        uint256 pot = 3 * TICKET * 93 / 100;
        uint256 share = pot * 80 / 100 / 2;
        assertEq(game.windowInfo(0).jackpotWinners, 2);
        assertEq(game.windowInfo(0).jackpotShare, share);
        assertEq(game.claimable(0, alice), share);
        assertEq(game.claimable(0, bob), 0);
        assertEq(_claim(carol, 0), share);
        assertEq(game.jackpotSeed(), pot - 2 * share);
        assertEq(game.jackpotOutstanding(), share);

        _settle(1, 50);
        game.finalize(1);
        assertEq(game.windowInfo(1).jackpotWinners, 0, "no winners when asleep");
        assertEq(game.claimable(1, alice), 0);
        assertEq(game.jackpotSeed(), pot - 2 * share + TICKET * 93 / 100);
    }

    function test_bettorCapAndViews() public {
        for (uint256 i; i < 256; ++i) {
            address who = address(uint160(0x20000 + i));
            imd.mint(who, 1 ether);
            vm.prank(who);
            imd.approve(address(game), 1 ether);
            _ou(who, 0, i % 2 == 0, 1 ether);
        }
        vm.expectRevert(HamsterHour.TooManyBettors.selector);
        _ou(alice, 0, true, 1 ether);
        HamsterHour.WindowView memory v = game.windowInfo(0);
        assertEq(v.over, 128 ether);
        assertEq(v.under, 128 ether);
        assertEq(uint8(v.status), uint8(HamsterHour.Status.Open));
        assertEq(v.closesAt, GENESIS);
        assertEq(v.timeoutAt, GENESIS + HOUR + 48 hours);
        assertEq(game.bettorCount(0), 256);
    }
}

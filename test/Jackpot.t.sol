// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";

contract JackpotTest is GameTest {
    event Fed(address indexed from, uint256 amount);

    function test_finalizeStrictlyInOrderAcrossBacklog() public {
        // Windows 0, 1, 2 each get one ticket; settlement arrives out of order within the 48h.
        _ticket(alice, 0, 2000);
        _ticket(bob, 1, 3000);
        _ticket(carol, 2, 4000);
        vm.prank(keeper);
        game.depositJackpot(100 ether); // pending for window 0 (earliest not started)
        assertEq(game.pendingJackpotDeposits(0), 100 ether);

        vm.warp(game.windowEnd(2));
        _settle(2, 4000); // carol would win window 2
        _settle(1, 1); // asleep: no winner
        // Window 0 is still open: finalize must stop there, even though 1 and 2 are settled.
        game.finalize(10);
        assertEq(game.nextFinalizeWindow(), 0);
        assertFalse(game.windowInfo(2).jackpotFinalized);
        assertEq(game.claimable(2, carol), 0, "jackpot not claimable before finalization");

        _settle(0, 2000); // alice wins window 0
        game.finalize(1);
        assertEq(game.nextFinalizeWindow(), 1);
        uint256 c = TICKET * 93 / 100;
        uint256 pot0 = 100 ether + c;
        uint256 share0 = pot0 * 80 / 100;
        assertEq(game.windowInfo(0).jackpotPot, pot0);
        assertEq(game.windowInfo(0).jackpotShare, share0);
        assertEq(game.jackpotSeed(), pot0 - share0, "20% carries");
        game.finalize(10);
        // Window 3 (never created) has started by now, so it passes too; window 4 has not.
        assertEq(game.nextFinalizeWindow(), 4);
        assertEq(game.windowInfo(3).jackpotPot, game.jackpotSeed(), "an empty window carries the seed");
        // Window 1 asleep: everything carries. Window 2: carol takes 80% of the carried pot.
        uint256 pot1 = pot0 - share0 + c;
        assertEq(game.windowInfo(1).jackpotPot, pot1);
        assertEq(game.windowInfo(1).jackpotWinners, 0);
        uint256 pot2 = pot1 + c;
        assertEq(game.windowInfo(2).jackpotPot, pot2);
        assertEq(game.windowInfo(2).jackpotShare, pot2 * 80 / 100);
        assertEq(_claim(alice, 0), share0);
        assertEq(_claim(carol, 2), pot2 * 80 / 100);
        assertEq(game.jackpotOutstanding(), 0);
        assertEq(game.jackpotSeed(), pot2 - pot2 * 80 / 100);
        // Claims never expire and the base claim does not block a later jackpot claim.
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0);
    }

    function test_finalizeTimesOutAndSkipsEmptyWindows() public {
        _ticket(alice, 1, 2000);
        vm.prank(keeper);
        game.depositJackpot(10 ether); // pending for window 0, never created
        assertEq(game.totalPendingJackpotDeposits(), 10 ether);
        assertEq(game.trackedLiabilities(), 10 ether, "pending deposits are a tracked liability");
        vm.warp(GENESIS - 1);
        game.finalize(10);
        assertEq(game.nextFinalizeWindow(), 0, "window 0 can still be created before it starts");
        vm.warp(GENESIS);
        game.finalize(10);
        assertEq(game.nextFinalizeWindow(), 1, "empty window 0 passes as soon as it has started");
        assertEq(game.jackpotSeed(), 10 ether, "deposits for an empty window carry");
        assertEq(game.totalPendingJackpotDeposits(), 0);
        vm.warp(game.windowEnd(1) + 48 hours - 1);
        game.finalize(10);
        assertEq(game.nextFinalizeWindow(), 1, "an open window waits for settle or timeout");
        vm.warp(game.windowEnd(1) + 48 hours);
        game.finalize(10);
        assertEq(uint8(game.windowInfo(1).status), uint8(HamsterHour.Status.TimedOut));
        assertEq(game.nextFinalizeWindow(), 11, "bounded catch-up: window 1 and nine started empty windows");
        assertEq(game.jackpotSeed(), 10 ether, "timeout leaves the seed unchanged");
        assertEq(_claim(alice, 1), TICKET, "timeout refunds the ticket in full");
        assertEq(game.totalEligibleLoss(1), 0);
    }

    function test_emptyWindowDoesNotStallLaterJackpots() public {
        // Nobody bets on window 0; window 1 has a jackpot winner.
        _ticket(alice, 1, 2000);
        _ou(alice, 1, true, 1 ether);
        _ou(bob, 1, false, 1 ether);
        _settle(1, 2000);
        game.finalize(10);
        assertEq(game.nextFinalizeWindow(), 3, "window 1 is finalized right after its settlement (2 has started)");
        assertEq(game.windowInfo(1).jackpotWinners, 1);
        // 2000 <= 2100 is UNDER: alice's OVER loses and she holds the only winning ticket.
        assertEq(game.claimable(1, alice), (TICKET * 93 / 100 + 2 ether * 2 / 100) * 80 / 100);
        assertEq(game.claimable(1, bob), 2 ether * 91 / 100);
        assertEq(game.totalEligibleLoss(1), 1 ether);
    }

    function test_jackpotInFlightIsTrackedBetweenSettleAndFinalize() public {
        _ticket(alice, 0, 2000);
        _settle(0, 2000);
        uint256 contribution = TICKET * 93 / 100;
        assertEq(game.jackpotInFlight(), contribution);
        assertEq(game.windowFunds(0), 0);
        assertEq(game.trackedLiabilities(), imd.balanceOf(address(game)), "every unit is in a view");
        game.finalize(1);
        assertEq(game.jackpotInFlight(), 0);
        assertEq(game.jackpotOutstanding() + game.jackpotSeed(), contribution);
    }

    function test_jackpotIsNeverRawBalance() public {
        _ticket(alice, 0, 2000);
        imd.mint(address(game), 1_000 ether); // stray tokens
        _settle(0, 2000);
        game.finalize(1);
        assertEq(game.windowInfo(0).jackpotPot, TICKET * 93 / 100);
    }

    function test_feedHamsterSplitsAndAccruesTips() public {
        vm.expectEmit(true, false, false, true);
        emit Fed(alice, 100 ether);
        vm.prank(alice);
        game.feedHamster(100 ether);
        assertEq(game.pendingJackpotDeposits(0), 90 ether);
        assertEq(game.pendingTips(), 10 ether);
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        vm.prank(alice);
        game.feedHamster(0);
        // Once the tip jar is set, held tips move to it and new tips accrue directly.
        vm.prank(team);
        game.scheduleTipRecipient(carol);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        game.executeTipRecipient(carol);
        assertEq(game.balances(carol), 10 ether);
        assertEq(game.pendingTips(), 0);
        vm.prank(alice);
        game.feedHamster(10 ether);
        assertEq(game.balances(carol), 11 ether);
        uint256 before = imd.balanceOf(carol);
        vm.prank(carol);
        game.withdraw();
        assertEq(imd.balanceOf(carol) - before, 11 ether);
        // Deposits after genesis go to the earliest not-started window.
        vm.warp(GENESIS + 5 * HOUR + 10);
        vm.prank(alice);
        game.depositJackpot(1 ether);
        assertEq(game.pendingJackpotDeposits(6), 1 ether);
    }

    function test_lineTimelockNeverChangesABettableWindow() public {
        vm.expectRevert(HamsterHour.NotTeam.selector);
        vm.prank(alice);
        game.scheduleLine(2500);
        vm.expectRevert(HamsterHour.InvalidLine.selector);
        vm.prank(team);
        game.scheduleLine(0);
        // Now GENESIS - 1h: ready at GENESIS + 11h; the first window that cannot be bet on before
        // then starts after GENESIS + 35h, i.e. window 36.
        vm.prank(team);
        game.scheduleLine(2500);
        assertEq(game.nextLine(), 2500);
        assertEq(game.nextLineReadyAt(), GENESIS + 11 * HOUR);
        assertEq(game.nextLineFrom(), 36);
        assertEq(game.lineFor(35), 2100);
        assertEq(game.lineFor(36), 2500);
        assertEq(game.windowInfo(36).line, 2500, "announced from scheduling");
        assertEq(game.line(), 2100, "nothing bettable changes");
        // An unready schedule may be overwritten: no bettable window is affected.
        vm.prank(team);
        game.scheduleLine(2400);
        assertEq(game.lineFor(36), 2400);
        // Windows created before and after the change keep the line they showed.
        _ou(alice, 0, true, 1 ether);
        vm.warp(GENESIS + 12 * HOUR);
        _ou(alice, 35, true, 1 ether);
        _ou(alice, 36, true, 1 ether);
        assertEq(game.windowInfo(0).line, 2100);
        assertEq(game.windowInfo(35).line, 2100);
        assertEq(game.windowInfo(36).line, 2400);
        // While windows below 36 can still be bet on, another change must wait.
        vm.expectRevert(HamsterHour.LineChangeInProgress.selector);
        vm.prank(team);
        game.scheduleLine(2600);
        assertEq(game.line(), 2100, "window 12 is the next to start and keeps 2100");
        // Once every window below 36 has closed the new line is the only line, and a new change
        // can be scheduled (ready at +12h, from the first window starting after +36h).
        vm.warp(GENESIS + 35 * HOUR);
        assertEq(game.line(), 2400);
        vm.prank(team);
        game.scheduleLine(2600);
        assertEq(game.nextLineFrom(), 72);
        assertEq(game.lineFor(71), 2400);
        assertEq(game.lineFor(72), 2600);
        assertEq(game.nextLine(), 2600);
    }

    function test_recipientTimelocks() public {
        // Staking recipient: once only; held fees move on set.
        _ou(alice, 12, true, 100 ether);
        _ou(bob, 12, false, 100 ether);
        _ou(alice, 13, true, 10 ether);
        _ou(bob, 13, false, 10 ether);
        _settle(12, 3000);
        assertEq(game.pendingStakingFees(), 10 ether);
        vm.prank(team);
        game.scheduleStakingRecipient(carol);
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        vm.prank(team);
        game.executeStakingRecipient(carol);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(team);
        game.executeStakingRecipient(carol);
        assertEq(game.stakingRecipient(), carol);
        assertEq(game.balances(carol), 10 ether);
        assertEq(game.pendingStakingFees(), 0);
        vm.expectRevert(HamsterHour.AlreadySet.selector);
        vm.prank(team);
        game.scheduleStakingRecipient(bob);
        _settle(13, 3000);
        assertEq(game.balances(carol), 11 ether);
        vm.expectRevert(HamsterHour.ZeroAddress.selector);
        vm.prank(team);
        game.scheduleTipRecipient(address(0));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(HamsterHour.ZeroAddress.selector);
        new HamsterHour(address(0), attester, address(intake));
        vm.expectRevert(HamsterHour.ZeroAddress.selector);
        new HamsterHour(team, address(0), address(intake));
        vm.expectRevert(HamsterHour.ZeroAddress.selector);
        new HamsterHour(team, attester, address(0));
    }
}

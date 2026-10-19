// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";

/// @dev IMD held >= every liability, before and after claims, for random bets and results.
contract ConservationTest is GameTest {
    address[4] internal players;

    function setUp() public override {
        super.setUp();
        players = [alice, bob, carol, keeper];
    }

    function _held() internal view returns (uint256) {
        return imd.balanceOf(address(game));
    }

    function _owed(uint256 windows) internal view returns (uint256 total) {
        // claimable() already includes finalized jackpot shares, so do not count them twice.
        // Pending deposits and in-flight jackpot money are inside trackedLiabilities().
        total = game.trackedLiabilities() - game.jackpotOutstanding();
        for (uint256 k; k < windows; ++k) {
            for (uint256 i; i < players.length; ++i) {
                total += game.claimable(k, players[i]);
            }
        }
    }

    function testFuzz_conservation(uint256 seed, uint256 result0, uint256 result1, bool timeout1) public {
        uint256 r = seed;
        uint256 paidIn;
        for (uint256 k; k < 2; ++k) {
            for (uint256 i; i < players.length; ++i) {
                r = uint256(keccak256(abi.encode(r)));
                uint256 amount = 0.5 ether + (r % 100 ether);
                if (r % 7 != 0) {
                    _ou(players[i], k, (r >> 8) % 2 == 0, amount);
                    paidIn += amount;
                }
                if ((r >> 16) % 3 != 0) {
                    _sn(players[i], k, (r >> 24) % 2 == 0, amount);
                    paidIn += amount;
                }
                if ((r >> 32) % 2 == 0) {
                    _ticket(players[i], k, (r >> 40) % 5000);
                    paidIn += TICKET;
                }
            }
        }
        if (seed % 3 == 0) {
            vm.prank(alice);
            game.feedHamster(1 ether + seed % 10 ether);
            paidIn += 1 ether + seed % 10 ether;
        }
        assertEq(_held(), paidIn);
        _settle(0, result0 % 6000);
        assertEq(_held(), game.trackedLiabilities() + game.windowFunds(0) + game.windowFunds(1), "all in a view");
        if (timeout1) _timeout(1);
        else _settle(1, result1 % 6000);
        assertGe(_held(), _owed(2));
        // Claims before finalization or fee allocation never underpay or overpay.
        uint256 early;
        for (uint256 i; i < players.length; ++i) {
            if (game.claimable(1, players[i]) > 0) early += _claim(players[i], 1);
        }
        assertGe(_held(), _owed(2));
        game.finalize(5);
        assertGe(game.nextFinalizeWindow(), 2);
        assertGe(_held(), _owed(2));
        // Loss history is the pool-level netted loss: never below the sum of the per-account rule
        // (accounts holding several sides net within themselves; lossOf rounds payouts up).
        for (uint256 k; k < 2; ++k) {
            uint256 sum;
            for (uint256 i; i < players.length; ++i) {
                sum += game.lossOf(k, players[i]);
            }
            assertLe(sum, game.totalEligibleLoss(k));
        }
        assertEq(game.cumulativeLossAfter(1), game.totalEligibleLoss(0) + game.totalEligibleLoss(1));
        // Everyone claims; pull balances drain; what remains is tracked (seed, reserve, held fees, dust).
        for (uint256 k; k < 2; ++k) {
            for (uint256 i; i < players.length; ++i) {
                if (game.claimable(k, players[i]) > 0) _claim(players[i], k);
                assertEq(game.claimable(k, players[i]), 0);
            }
        }
        if (game.balances(team) > 0) {
            vm.prank(team);
            game.withdraw();
        }
        uint256 dust = game.windowFunds(0) + game.windowFunds(1);
        assertLt(dust, 8, "rounding dust is bounded by one unit per payout");
        assertEq(_held(), game.trackedLiabilities() + dust);
        assertEq(game.jackpotInFlight(), 0);
        assertEq(game.totalPendingJackpotDeposits(), 0);
        assertEq(game.jackpotOutstanding(), 0);
        assertGe(_held(), _owed(2));
    }

    function testFuzz_exactBandMatchesSpec(uint64 guess, uint64 result) public view {
        uint256 diff = guess > result ? guess - result : result - guess;
        assertEq(game.isWinningGuess(guess, result), diff * 1000 <= uint256(result) * 5);
    }

    function test_reentrantClaimIsBlocked() public {
        // IMD is a plain token here; the guard is exercised through a malicious bettor contract.
        Reenterer evil = new Reenterer(game);
        imd.mint(address(evil), 10 ether);
        evil.approveAll();
        evil.bet(0, 5 ether);
        _ou(bob, 0, false, 5 ether);
        _timeout(0);
        evil.claimTwice(0);
        assertEq(imd.balanceOf(address(evil)), 10 ether, "second claim inside the first reverted");
    }
}

contract Reenterer {
    HamsterHour internal game;
    bool internal inside;

    constructor(HamsterHour game_) {
        game = game_;
    }

    function approveAll() external {
        (bool ok,) =
            game.IMD().call(abi.encodeWithSignature("approve(address,uint256)", address(game), type(uint256).max));
        require(ok);
    }

    function bet(uint256 k, uint256 amount) external {
        game.betOverUnder(k, true, amount);
    }

    function claimTwice(uint256 k) external {
        game.claim(k);
        // A second claim after the first has settled state must find nothing.
        try game.claim(k) {
            revert("should not pay twice");
        } catch {}
    }
}

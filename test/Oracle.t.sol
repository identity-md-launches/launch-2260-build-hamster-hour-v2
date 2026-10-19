// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIntake} from "./helpers/Mocks.sol";

contract OracleTest is GameTest {
    /// @dev The production attester, read from GET https://api.imd.fun/oracle/requests ("attester")
    /// on 2026-10-19 and from the real signed Squeekchain result below. Never guessed.
    address internal constant REAL_ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    /// @dev Real signed result: https://api.imd.fun/oracle/requests/753b4996-34e7-420a-8768-d784231195da/attestation
    /// (1470 passes for rounds 468-470, signed for the zero consumer on chain 1). Proves the hash
    /// library, domain name/version and the attester key against a live signature, and that the same
    /// signature is refused for HamsterHour's own domain.
    function test_realAttestationRecoversProductionAttester() public {
        OracleAttestation.Attestation memory a;
        a.requestId = 0x753b499634e7420a8768d784231195da00000000000000000000000000000000;
        a.chainId = 1;
        a.questionHash = 0x5dc1af7336e9a05027d84f9e4682b92b36e8df019aaf6fedbbc1f2914396d412;
        a.answerType = 3;
        a.answer = abi.encode(uint256(1470));
        a.figure = 1470;
        a.fromBlock = 26196534;
        a.toBlock = 26203713;
        a.blockHash = 0x131b644f711ff28bdb1054d8d8ab71bdc27a6baecc1b98868ec78ee87bddf766;
        a.panelJobId = 0x354a39ee97cf4e9284a1eaa3b55c90e200000000000000000000000000000000;
        a.panelSize = 20;
        a.quorum = 14;
        a.agreed = 14;
        a.issuedAt = 1792137438;
        a.expiresAt = 1792223838;
        bytes memory sig =
            hex"f47514dae00f795150c1620b7773f44b94e61df978cdfe3ad753d767eedd35822e0900c6c55e64c0e0e2f085b97f6a5ea677d116296c0c63f301dd3887da8e3a1c";
        assertEq(_recover(this.digestFor(a, address(0)), sig), REAL_ATTESTER);
        assertTrue(_recover(this.digestFor(a, address(game)), sig) != REAL_ATTESTER, "other domain");
        // The canonical document format reproduces the real question hash.
        string memory text =
            "What is the total number of wheel passes recorded by Squeekchain for rounds 468, 469 and 470 combined, as published on the public console at https://sepolia.squeekchain.com/status in the CORE SETTLED events (field PASSES for each round)? Answer as a single uint256 equal to the sum of the three values.";
        string memory doc = string.concat(
            '{"answerType":"uint256","chainId":1,"evidence":"panel","question":"',
            text,
            '","v":1,"window":{"fromBlock":26196534,"toBlock":26203713}}'
        );
        assertEq(keccak256(bytes(doc)), a.questionHash);
    }

    function digestFor(OracleAttestation.Attestation calldata a, address consumer) external view returns (bytes32) {
        return OracleAttestation.digest(a, block.chainid, consumer);
    }

    function _clone(OracleAttestation.Attestation memory a)
        internal
        pure
        returns (OracleAttestation.Attestation memory b)
    {
        b = abi.decode(abi.encode(a), (OracleAttestation.Attestation));
    }

    function _recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        return ecrecover(digest, v, r, s);
    }

    function test_questionBindsSixRoundsGenesisAndSource() public view {
        assertEq(
            game.question(167),
            "What is the total number of wheel passes recorded by Squeekchain for rounds 1002, 1003, 1004, 1005, 1006 and 1007 (each round lasts 600 seconds and round 0 began at Unix time 1791847200), as published at https://sepolia.squeekchain.com? Answer as a single uint256 equal to the sum of the six published PASSES values. If any of the six rounds has not been published as settled, the question is unanswerable; never answer 0 for missing data."
        );
        assertEq(
            game.questionDocument(0, 5, 6),
            string.concat(
                '{"answerType":"uint256","chainId":1,"evidence":"panel","question":"',
                game.question(0),
                '","v":1,"window":{"fromBlock":5,"toBlock":6}}'
            )
        );
        assertEq(
            game.requestBody(0),
            string.concat(
                '{"v":1,"question":"',
                game.question(0),
                '","chainId":1,"window":{"hours":24},"answerType":"uint256","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":86400}'
            )
        );
    }

    function test_settleRejectsBadAttestations() public {
        _ou(alice, 0, true, 1 ether);
        _ou(bob, 0, false, 1 ether);
        uint64 end = game.windowEnd(0);
        vm.warp(end - 1);
        OracleAttestation.Attestation memory a = _attestation(0, 2500, end);
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        vm.warp(end);

        OracleAttestation.Attestation memory bad = _clone(a);
        bad.issuedAt = end - 1;
        vm.expectRevert(HamsterHour.AttestationPredatesEnd.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        bad = _clone(a);
        bad.questionHash = game.questionHash(1, a.fromBlock, a.toBlock);
        vm.expectRevert(HamsterHour.WrongQuestion.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        bad = _clone(a);
        bad.chainId = 11155111;
        vm.expectRevert(HamsterHour.WrongChain.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        bad = _clone(a);
        bad.answerType = 0;
        vm.expectRevert(HamsterHour.InvalidAnswer.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        bad = _clone(a);
        bad.panelSize = 4;
        bad.agreed = 4;
        vm.expectRevert(HamsterHour.WeakPanel.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        bad = _clone(a);
        bad.agreed = 3;
        bad.quorum = 3;
        vm.expectRevert(HamsterHour.WeakPanel.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        bad = _clone(a);
        bad.quorum = 5;
        bad.agreed = 4;
        vm.expectRevert(HamsterHour.WeakPanel.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        bad = _clone(a);
        bad.expiresAt = end - 1;
        vm.expectRevert(HamsterHour.InvalidValidity.selector);
        game.settle(0, bad, _sign(bad, ATTESTER_KEY, address(game)));

        // Wrong signer, wrong domain, malformed signature.
        vm.expectRevert(HamsterHour.BadSignature.selector);
        game.settle(0, a, _sign(a, 0xB0B, address(game)));
        vm.expectRevert(HamsterHour.BadSignature.selector);
        game.settle(0, a, _sign(a, ATTESTER_KEY, address(0)));
        vm.expectRevert(HamsterHour.BadSignature.selector);
        game.settle(0, a, hex"deadbeef");

        // The good one settles, and nothing moved before it.
        assertEq(game.balances(team), 0);
        game.settle(0, a, sig);
        assertEq(game.windowInfo(0).result, 2500);
        assertEq(game.windowInfo(0).requestId, a.requestId);
    }

    function test_replayedAttestationIsRefused() public {
        _ou(alice, 0, true, 1 ether);
        _ou(alice, 1, true, 1 ether);
        vm.warp(game.windowEnd(1));
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        game.settle(0, a, sig);
        // Same request id with another window's question: refused as consumed, even if re-signed.
        OracleAttestation.Attestation memory b = a;
        b.questionHash = game.questionHash(1, a.fromBlock, a.toBlock);
        vm.expectRevert(HamsterHour.AlreadyConsumed.selector);
        game.settle(1, b, _sign(b, ATTESTER_KEY, address(game)));
        // The window itself cannot be settled twice with a fresh id either.
        OracleAttestation.Attestation memory c = _attestation(0, 2600, uint64(block.timestamp));
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, c, _sign(c, ATTESTER_KEY, address(game)));
        assertTrue(game.consumedRequest(a.requestId));
    }

    function test_intakeRequestAndCallbackSettle() public {
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        vm.warp(game.windowEnd(0) - 1);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.requestOracle(0);
        vm.warp(game.windowEnd(0));
        // Empty reserve: the request reverts but nothing else is blocked.
        vm.expectRevert(HamsterHour.ReserveTooLow.selector);
        game.requestOracle(0);
        vm.prank(carol);
        game.fundOracleReserve(0.5 ether);
        bytes32 id = game.requestOracle(0);
        assertEq(game.oracleReserve(), 0);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(string(intake.lastBody()), game.requestBody(0));
        (address target, bytes4 selector) = intake.lastCallback();
        assertEq(target, address(game));
        assertEq(selector, HamsterHour.onOracleResult.selector);
        assertEq(intake.lastFailureSelector(), HamsterHour.onOracleFailure.selector);
        assertTrue(game.windowInfo(0).oracleRequested);
        assertTrue(game.windowInfo(0).oracleRequestPending);
        assertEq(game.windowInfo(0).intakeRequestId, id);
        vm.expectRevert(HamsterHour.AlreadyRequested.selector);
        game.requestOracle(0);

        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        // Only the Intake may deliver through the callback, and only for a known request id.
        vm.expectRevert(HamsterHour.NotIntake.selector);
        game.onOracleResult(id, a, sig);
        vm.expectRevert(HamsterHour.UnknownRequest.selector);
        intake.deliverStrict(bytes32(uint256(1)), a, sig);
        // The paid answer settles through the documented 200,000 gas stipend.
        assertTrue(intake.deliver(id, a, sig), "callback within the stipend");
        assertLe(intake.lastGasUsed(), 200_000);
        assertEq(game.windowInfo(0).result, 2500);
        assertFalse(game.windowInfo(0).oracleRequestPending);
        assertEq(game.windowInfo(0).intakeRequestId, bytes32(0));
        // Claims never wait for fee allocation; the reserve refill lands when fees are allocated.
        assertEq(game.claimable(0, alice), 20 ether * 91 / 100);
        assertEq(game.oracleReserve(), 0);
        assertFalse(game.windowInfo(0).feesAllocated);
        game.allocate(0);
        assertTrue(game.windowInfo(0).feesAllocated);
        assertEq(game.oracleReserve(), 0.2 ether, "1% of the 20 IMD pool refills the reserve");
        assertEq(game.balances(team), 0.2 ether);
        game.allocate(0); // idempotent
        assertEq(game.balances(team), 0.2 ether);
        assertEq(_claim(alice, 0), 20 ether * 91 / 100);
        // A second delivery for the consumed id is unknown; the window cannot settle twice.
        vm.expectRevert(HamsterHour.UnknownRequest.selector);
        intake.deliverStrict(id, a, sig);
    }

    function test_callbackStaysUnderStipendOnTheHeaviestWindow() public {
        // Both binary markets two-sided, a ticket, 256 tickets: the callback cost does not grow.
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        _sn(alice, 0, true, 3 ether);
        _sn(carol, 0, false, 3 ether);
        for (uint256 i; i < 256; ++i) {
            address who = address(uint160(0x30000 + i));
            imd.mint(who, TICKET);
            vm.prank(who);
            imd.approve(address(game), TICKET);
            _ticket(who, 0, 2000 + i);
        }
        vm.prank(carol);
        game.fundOracleReserve(0.5 ether);
        vm.warp(game.windowEnd(0));
        bytes32 id = game.requestOracle(0);
        OracleAttestation.Attestation memory a = _attestation(0, 2100, uint64(block.timestamp));
        assertTrue(intake.deliver(id, a, _sign(a, ATTESTER_KEY, address(game))));
        assertLe(intake.lastGasUsed(), 200_000);
        assertEq(game.windowInfo(0).result, 2100);
        game.finalize(1);
        assertEq(game.windowInfo(0).jackpotWinners, 21, "guesses 2090..2110 are within 0.5% of 2100");
    }

    function test_callbackFitsStipendForLargeWindowIndex() public {
        vm.warp(game.windowStart(1_000_000) - 1 hours);
        _ou(alice, 1_000_000, true, 10 ether);
        _ou(bob, 1_000_000, false, 10 ether);
        vm.prank(carol);
        game.fundOracleReserve(0.5 ether);
        vm.warp(game.windowEnd(1_000_000));
        bytes32 id = game.requestOracle(1_000_000);
        OracleAttestation.Attestation memory a = _attestation(1_000_000, 2500, uint64(block.timestamp));
        assertTrue(intake.deliver(id, a, _sign(a, ATTESTER_KEY, address(game))));
        assertLe(intake.lastGasUsed(), 200_000);
        assertEq(game.windowInfo(1_000_000).result, 2500);
    }

    function test_failureHookReleasesWindowForRetryAndPublicSettle() public {
        _ou(alice, 0, true, 100 ether);
        _ou(bob, 0, false, 100 ether);
        vm.prank(carol);
        game.fundOracleReserve(10 ether);
        vm.warp(game.windowEnd(0));
        bytes32 id = game.requestOracle(0);
        assertEq(game.oracleReserve(), 9.5 ether);

        // While the paid request is outstanding, a public settle must not pre-empt it.
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        vm.expectRevert(HamsterHour.PaidRequestPending.selector);
        game.settle(0, a, sig);

        // Only the Intake may report a failure, and only for a known id.
        vm.expectRevert(HamsterHour.NotIntake.selector);
        game.onOracleFailure(id, 2, "disagreed", 0, 0, "");
        assertFalse(intake.fail(bytes32(uint256(5)), 2, "disagreed"), "unknown id is refused");
        assertTrue(intake.fail(id, 2, "disagreed"), "failure hook within the stipend");
        assertFalse(game.windowInfo(0).oracleRequestPending);
        assertTrue(game.windowInfo(0).oracleRequested);
        assertEq(game.oracleReserve(), 9.5 ether, "a failure moves no value");
        assertFalse(intake.fail(id, 2, "disagreed"), "a failure is heard once");

        // A new reserve-paid request is possible, and the late answer to it settles.
        vm.warp(block.timestamp + 30 hours);
        bytes32 id2 = game.requestOracle(0);
        assertTrue(id2 != id);
        assertEq(game.oracleReserve(), 9 ether);
        OracleAttestation.Attestation memory b = _attestation(0, 2500, uint64(block.timestamp));
        assertTrue(intake.deliver(id2, b, _sign(b, ATTESTER_KEY, address(game))));
        assertEq(game.windowInfo(0).result, 2500);
    }

    function test_lapsedRequestAllowsRetryAndPublicSettle() public {
        _ou(alice, 0, true, 100 ether);
        _ou(bob, 0, false, 100 ether);
        _ou(alice, 1, true, 100 ether);
        _ou(bob, 1, false, 100 ether);
        vm.prank(carol);
        game.fundOracleReserve(10 ether);
        vm.warp(game.windowEnd(1));
        bytes32 id0 = game.requestOracle(0);
        game.requestOracle(1);
        // Nothing comes back (request() without a hook, or a plane that never writes).
        vm.warp(game.windowEnd(1) + 86400 - 1);
        vm.expectRevert(HamsterHour.AlreadyRequested.selector);
        game.requestOracle(0);
        vm.warp(game.windowEnd(1) + 86400);
        assertFalse(game.oracleRequestPending(0));
        // Window 0: someone fetched the attestation and settles publicly once the validity lapsed.
        _settle(0, 2500);
        assertEq(game.windowInfo(0).result, 2500);
        // A very late delivery of the lapsed request finds the window settled and reverts harmlessly.
        OracleAttestation.Attestation memory a = _attestation(0, 2600, uint64(block.timestamp));
        assertFalse(intake.deliver(id0, a, _sign(a, ATTESTER_KEY, address(game))));
        // Window 1: a second reserve-paid request replaces the lapsed one (window 0's public
        // settle just refilled the reserve with 1% of its 200 IMD pool).
        bytes32 id1b = game.requestOracle(1);
        assertEq(game.oracleReserve(), 9 ether + 2 ether - 0.5 ether);
        OracleAttestation.Attestation memory b = _attestation(1, 50, uint64(block.timestamp));
        assertTrue(intake.deliver(id1b, b, _sign(b, ATTESTER_KEY, address(game))));
        assertEq(game.windowInfo(1).result, 50);
        assertTrue(game.windowInfo(1).ouVoid);
    }

    function test_renewedReserveRequestsCannotHoldPublicSettlePastTheGrace() public {
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        vm.prank(carol);
        game.fundOracleReserve(1 ether);
        uint64 end = game.windowEnd(0);
        vm.warp(end);
        bytes32 id1 = game.requestOracle(0);
        assertTrue(game.publicSettleHeld(0));
        assertTrue(game.windowInfo(0).publicSettleHeld);
        // First 24 h after the end: the paid request has priority over the public path.
        vm.warp(end + 24 hours - 1);
        OracleAttestation.Attestation memory early = _attestation(0, 2500, uint64(block.timestamp));
        vm.expectRevert(HamsterHour.PaidRequestPending.selector);
        game.settle(0, early, _sign(early, ATTESTER_KEY, address(game)));
        // The Intake never calls back; the keeper renews as soon as the first request lapses.
        vm.warp(end + 1 days);
        bytes32 id2 = game.requestOracle(0);
        assertTrue(id2 != id1);
        assertEq(game.oracleReserve(), 0);
        assertTrue(game.oracleRequestPending(0), "the renewed request is outstanding");
        assertFalse(game.publicSettleHeld(0), "but it no longer holds the public path");
        assertFalse(game.windowInfo(0).publicSettleHeld);
        vm.expectRevert(HamsterHour.AlreadyRequested.selector);
        game.requestOracle(0);
        // A correctly signed attestation settles at the very end of the 48 h despite the renewal.
        vm.warp(end + 48 hours - 1);
        _settle(0, 2500);
        assertEq(uint8(game.windowInfo(0).status), uint8(HamsterHour.Status.Settled));
        assertEq(_claim(alice, 0), 20 ether * 91 / 100, "winners are paid, not refunded by a timeout");
        assertEq(game.balances(team), 0.2 ether, "fees were allocated");
        // The late paid delivery finds the window settled and is refused harmlessly.
        OracleAttestation.Attestation memory late = _attestation(0, 2600, uint64(block.timestamp));
        assertFalse(intake.deliver(id2, late, _sign(late, ATTESTER_KEY, address(game))));
        assertEq(game.windowInfo(0).result, 2500);
    }

    function test_publicSettleHoldIsMeasuredFromWindowEndNotRequestTime() public {
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        vm.prank(carol);
        game.fundOracleReserve(1 ether);
        uint64 end = game.windowEnd(0);
        // A late first request holds the public path for one hour only, not for its 24 h validity.
        vm.warp(end + 23 hours);
        bytes32 id = game.requestOracle(0);
        assertTrue(game.publicSettleHeld(0));
        vm.warp(end + 24 hours - 1);
        assertTrue(game.publicSettleHeld(0));
        vm.warp(end + 24 hours);
        assertTrue(game.oracleRequestPending(0));
        assertFalse(game.publicSettleHeld(0));
        // The paid request can still deliver after the hold has ended.
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        assertTrue(intake.deliver(id, a, _sign(a, ATTESTER_KEY, address(game))));
        assertEq(game.windowInfo(0).result, 2500);
        assertFalse(game.oracleRequestPending(0));
        assertFalse(game.publicSettleHeld(0));
    }

    function test_reserveOnlyPaysForFeePayingWindows() public {
        vm.prank(carol);
        game.fundOracleReserve(10 ether);
        _ou(alice, 0, true, 0.5 ether); // one-sided: refunded in full, no fees
        _sn(alice, 1, true, 0.5 ether);
        _sn(bob, 2, true, 1 ether);
        _sn(bob, 2, false, 1 ether);
        _ticket(alice, 3, 2000);
        vm.warp(game.windowEnd(3));
        vm.expectRevert(HamsterHour.NoFeePayingActivity.selector);
        game.requestOracle(0);
        vm.expectRevert(HamsterHour.NoFeePayingActivity.selector);
        game.requestOracle(1);
        assertFalse(game.hasFeePayingActivity(0));
        assertTrue(game.hasFeePayingActivity(2));
        assertTrue(game.hasFeePayingActivity(3));
        game.requestOracle(2);
        game.requestOracle(3);
        assertEq(game.oracleReserve(), 9 ether);
        // The fee-less window still settles and refunds through the public path.
        _settle(0, 2500);
        assertEq(_claim(alice, 0), 0.5 ether);
    }

    function test_fallsBackToPlainRequestWhenIntakeLacksFailureHook() public {
        intake.setOffersFailureHook(false);
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        vm.prank(carol);
        game.fundOracleReserve(0.5 ether);
        vm.warp(game.windowEnd(0));
        vm.expectEmit(true, false, false, true);
        emit HamsterHour.OracleRequested(0, bytes32(0), 0.5 ether, false);
        bytes32 id = game.requestOracle(0);
        assertEq(intake.lastFailureSelector(), bytes4(0));
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        assertTrue(intake.deliver(id, a, _sign(a, ATTESTER_KEY, address(game))));
        assertEq(game.windowInfo(0).result, 2500);
    }

    function test_callbackRejectsBadAttestationsAndKeepsRequestPending() public {
        _ou(alice, 0, true, 10 ether);
        _ou(bob, 0, false, 10 ether);
        vm.prank(carol);
        game.fundOracleReserve(0.5 ether);
        vm.warp(game.windowEnd(0));
        bytes32 id = game.requestOracle(0);
        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        a.agreed = 3;
        a.quorum = 3;
        vm.expectRevert(HamsterHour.WeakPanel.selector);
        intake.deliverStrict(id, a, _sign(a, ATTESTER_KEY, address(game)));
        assertTrue(game.oracleRequestPending(0), "a reverted delivery leaves the request outstanding");
        OracleAttestation.Attestation memory b = _attestation(0, 2500, uint64(block.timestamp));
        vm.expectRevert(HamsterHour.BadSignature.selector);
        intake.deliverStrict(id, b, _sign(b, 0xB0B, address(game)));
        assertTrue(intake.deliver(id, b, _sign(b, ATTESTER_KEY, address(game))));
        assertEq(game.windowInfo(0).result, 2500);
    }

    function test_emptyReserveNeverBlocksSettleTimeoutOrClaims() public {
        assertEq(game.oracleReserve(), 0);
        _ou(alice, 0, true, 1 ether);
        _ou(bob, 0, false, 1 ether);
        _ou(alice, 1, true, 1 ether);
        _settle(0, 2500);
        assertEq(_claim(alice, 0), 2 ether * 91 / 100);
        _timeout(1);
        assertEq(_claim(alice, 1), 1 ether);
    }
}

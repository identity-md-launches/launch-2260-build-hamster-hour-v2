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
        assertTrue(game.windowInfo(0).oracleRequested);
        vm.expectRevert(HamsterHour.AlreadyRequested.selector);
        game.requestOracle(0);

        OracleAttestation.Attestation memory a = _attestation(0, 2500, uint64(block.timestamp));
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        // Only the Intake may deliver through the callback, and only for a known request id.
        vm.expectRevert(HamsterHour.NotIntake.selector);
        game.onOracleResult(id, a, sig);
        vm.expectRevert(HamsterHour.UnknownRequest.selector);
        intake.deliver(bytes32(uint256(1)), a, sig);
        intake.deliver(id, a, sig);
        assertEq(game.windowInfo(0).result, 2500);
        assertEq(game.oracleReserve(), 0.2 ether, "1% of the 20 IMD pool refills the reserve");
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

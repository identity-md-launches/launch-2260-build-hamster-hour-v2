// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterHour} from "../../src/HamsterHour.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {MockIMD, MockIntake} from "./Mocks.sol";

/// @dev Shared fixture: IMD etched at its mainnet address, a test attester key, a mock Intake.
abstract contract GameTest is Test {
    uint256 internal constant ATTESTER_KEY = 0xA11CE;
    uint64 internal constant GENESIS = 1791847200;
    uint64 internal constant HOUR = 3600;
    uint256 internal constant TICKET = 5 ether;

    address internal team = 0x6CBA4751742F6989fA224B2dC5d5d52fCef98a34;
    address internal attester = vm.addr(ATTESTER_KEY);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");

    MockIMD internal imd;
    MockIntake internal intake;
    HamsterHour internal game;
    uint256 internal nextRequest = 1;

    function setUp() public virtual {
        vm.chainId(1);
        MockIMD impl = new MockIMD();
        vm.etch(HamsterHourConstants.IMD, address(impl).code);
        imd = MockIMD(HamsterHourConstants.IMD);
        intake = new MockIntake(address(imd), 0.5 ether);
        game = new HamsterHour(team, attester, address(intake));
        address[5] memory users = [alice, bob, carol, keeper, team];
        for (uint256 i; i < users.length; ++i) {
            imd.mint(users[i], 1_000_000 ether);
            vm.prank(users[i]);
            imd.approve(address(game), type(uint256).max);
        }
        vm.warp(GENESIS - 1 hours);
    }

    // ------------------------------------------------------------ betting helpers
    function _ou(address who, uint256 k, bool over, uint256 amount) internal {
        vm.prank(who);
        game.betOverUnder(k, over, amount);
    }

    function _sn(address who, uint256 k, bool yes, uint256 amount) internal {
        vm.prank(who);
        game.betSnooze(k, yes, amount);
    }

    function _ticket(address who, uint256 k, uint256 guess) internal {
        vm.prank(who);
        game.buyTicket(k, guess);
    }

    function _claim(address who, uint256 k) internal returns (uint256 got) {
        uint256 before = imd.balanceOf(who);
        vm.prank(who);
        game.claim(k);
        got = imd.balanceOf(who) - before;
    }

    // ------------------------------------------------------------ oracle helpers
    function _attestation(uint256 k, uint256 result, uint64 issuedAt)
        internal
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = bytes32(nextRequest++ << 128);
        a.chainId = block.chainid;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.questionHash = game.questionHash(k, a.fromBlock, a.toBlock);
        a.answerType = 3;
        a.answer = abi.encode(result);
        a.figure = result;
        a.blockHash = bytes32(uint256(7));
        a.panelJobId = bytes32(uint256(9) << 128);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = issuedAt;
        a.expiresAt = issuedAt + 1 days;
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 key, address consumer)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                OracleAttestation.DOMAIN_TYPEHASH,
                OracleAttestation.NAME_HASH,
                OracleAttestation.VERSION_HASH,
                block.chainid,
                consumer
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
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Warps to just after the window's end (if needed) and settles it with `result`.
    function _settle(uint256 k, uint256 result) internal {
        uint64 end = game.windowEnd(k);
        if (block.timestamp < end) vm.warp(end);
        OracleAttestation.Attestation memory a = _attestation(k, result, uint64(block.timestamp));
        bytes memory sig = _sign(a, ATTESTER_KEY, address(game));
        vm.prank(keeper);
        game.settle(k, a, sig);
    }

    function _timeout(uint256 k) internal {
        uint64 end = game.windowEnd(k);
        if (block.timestamp < end + 48 hours) vm.warp(end + 48 hours);
        game.timeout(k);
    }
}

library HamsterHourConstants {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
}

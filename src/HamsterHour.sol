// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleAttestation} from "./OracleAttestation.sol";
import {IIntake, IERC20} from "./interfaces/IIntake.sol";

/// @title Hamster Hour v2
/// @notice Pari-mutuel IMD betting on the Squeekchain hamster wheel. No owner, pause, upgrade or
/// withdrawal power exists. TEAM (the launch wallet) holds only three 12-hour timelocked settings:
/// the OVER/UNDER line for future windows, the one-shot staking recipient and the one-shot tip jar
/// recipient. Every IMD unit that enters is assigned to a bucket (window funds, pull balances,
/// jackpot seed, jackpot liabilities, oracle reserve) so the contract always holds at least what
/// it owes. Results come only from IMD oracle v2 attestations signed for this contract's domain.
contract HamsterHour {
    using OracleAttestation for OracleAttestation.Attestation;

    // ----------------------------------------------------------------- constants
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint64 public constant GENESIS = 1791847200;
    uint64 public constant ROUND_DURATION = 600;
    uint64 public constant WINDOW_ROUNDS = 6;
    uint64 public constant WINDOW_DURATION = ROUND_DURATION * WINDOW_ROUNDS;
    uint64 public constant TIMEOUT = 48 hours;
    uint64 public constant OPEN_AHEAD = 24 hours;
    uint64 public constant TIMELOCK = 12 hours;
    uint256 public constant MIN_BET = 0.5 ether;
    uint256 public constant TICKET_PRICE = 5 ether;
    uint256 public constant MAX_TICKETS = 256;
    uint256 public constant MAX_BINARY_BETTORS = 256;
    uint256 public constant MAX_GUESS = type(uint64).max;
    uint256 public constant SNOOZE_THRESHOLD = 100;
    uint256 public constant INITIAL_LINE = 2100;
    uint256 public constant ORACLE_PRICE = 0.5 ether;
    uint16 public constant MIN_PANEL = 5;
    uint16 public constant MIN_AGREED = 4;
    uint64 public constant ISSUED_AT_TOLERANCE = 5 minutes;
    bytes32 public constant ORACLE_ACTION = "oracle.request@oracle-1";
    string public constant SOURCE = "https://sepolia.squeekchain.com";

    // Binary fee split, in percent of the market pool.
    uint256 public constant BINARY_STAKERS_PCT = 5;
    uint256 public constant BINARY_JACKPOT_PCT = 2;
    uint256 public constant BINARY_ORACLE_PCT = 1;
    uint256 public constant BINARY_TEAM_PCT = 1;
    // EXACT ticket split; the remaining 93% is that window's jackpot contribution.
    uint256 public constant TICKET_STAKERS_PCT = 5;
    uint256 public constant TICKET_ORACLE_PCT = 1;
    uint256 public constant TICKET_TEAM_PCT = 1;
    uint256 public constant JACKPOT_PAYOUT_PCT = 80;
    uint256 public constant FEED_TIP_PCT = 10;

    bytes32 public constant SETTING_LINE = keccak256("line");
    bytes32 public constant SETTING_STAKING = keccak256("stakingRecipient");
    bytes32 public constant SETTING_TIP = keccak256("tipRecipient");

    // ----------------------------------------------------------------- immutables
    address public immutable TEAM;
    address public immutable ATTESTER;
    address public immutable INTAKE;

    // ----------------------------------------------------------------- types
    enum Status {
        None,
        Open,
        Settled,
        TimedOut
    }

    struct Window {
        Status status;
        bool ouVoid;
        bool snVoid;
        bool finalized;
        uint32 tickets;
        uint32 jackpotWinners;
        uint64 startsAt;
        uint64 endsAt;
        uint128 over;
        uint128 under;
        uint128 yes;
        uint128 no;
        uint256 line;
        uint256 result;
        uint256 ouWinnerPool;
        uint256 snWinnerPool;
        uint256 jackpotFees;
        uint256 jackpotContribution;
        uint256 jackpotShare;
        uint256 jackpotPot;
        bytes32 requestId;
    }

    struct Position {
        uint128 over;
        uint128 under;
        uint128 yes;
        uint128 no;
        uint64 guess;
        bool hasTicket;
        bool registered;
        bool jackpotPaid;
        uint256 paid;
    }

    struct WindowView {
        uint256 index;
        Status status;
        uint64 startsAt;
        uint64 endsAt;
        uint64 closesAt;
        uint64 timeoutAt;
        uint256 line;
        uint256 result;
        uint256 over;
        uint256 under;
        uint256 yes;
        uint256 no;
        uint256 tickets;
        bool ouVoid;
        bool snVoid;
        bool jackpotFinalized;
        uint256 jackpotPot;
        uint256 jackpotWinners;
        uint256 jackpotShare;
        uint256 pendingJackpotDeposits;
        bool oracleRequested;
        bytes32 requestId;
    }

    struct Pending {
        bytes32 valueHash;
        uint64 readyAt;
    }

    // ----------------------------------------------------------------- storage
    mapping(uint256 => Window) internal _windows;
    mapping(uint256 => mapping(address => Position)) internal _positions;
    mapping(uint256 => address[]) internal _bettors;
    mapping(uint256 => uint64[]) internal _guesses;
    mapping(uint256 => uint256) public windowFunds;
    mapping(uint256 => uint256) public pendingJackpotDeposits;
    mapping(uint256 => bool) public oracleRequested;
    mapping(bytes32 => uint256) internal _intakeWindow;
    mapping(bytes32 => bool) public consumedRequest;
    mapping(bytes32 => Pending) public pendingSetting;
    mapping(address => uint256) public balances;

    uint256 public line = INITIAL_LINE;
    address public stakingRecipient;
    address public tipRecipient;
    uint256 public pendingStakingFees;
    uint256 public pendingTips;
    uint256 public oracleReserve;
    uint256 public jackpotSeed;
    uint256 public jackpotOutstanding;
    uint256 public nextFinalizeWindow;
    uint256 public cumulativeLoss;
    mapping(uint256 => uint256) public totalEligibleLoss;
    mapping(uint256 => uint256) public cumulativeLossBefore;
    mapping(uint256 => uint256) public cumulativeLossAfter;

    uint256 private _lock = 1;

    // ----------------------------------------------------------------- errors
    error ZeroAddress();
    error NotTeam();
    error Reentrancy();
    error TransferFailed();
    error WindowTooFar();
    error BettingClosed();
    error BelowMinimum();
    error PoolLimit();
    error InvalidGuess();
    error DuplicateTicket();
    error TicketsFull();
    error TooManyBettors();
    error NotSettleable();
    error NotTimedOut();
    error NotFinal();
    error NothingToClaim();
    error WrongQuestion();
    error WrongChain();
    error InvalidAnswer();
    error WeakPanel();
    error InvalidValidity();
    error AttestationPredatesEnd();
    error AlreadyConsumed();
    error BadSignature();
    error NotIntake();
    error UnknownRequest();
    error AlreadyRequested();
    error ReserveTooLow();
    error InvalidAmount();
    error InvalidLine();
    error AlreadySet();
    error TimelockNotReady();
    error NothingScheduled();

    // ----------------------------------------------------------------- events
    event WindowCreated(uint256 indexed k, uint64 startsAt, uint64 endsAt, uint256 line);
    event BinaryBet(uint256 indexed k, address indexed bettor, uint8 indexed market, bool side, uint256 amount);
    event TicketBought(uint256 indexed k, address indexed bettor, uint256 guess);
    event Settled(uint256 indexed k, uint256 result, bytes32 indexed requestId, address indexed settler);
    event MarketVoided(uint256 indexed k, uint8 indexed market);
    event TimedOut(uint256 indexed k);
    event FeesAllocated(uint256 indexed k, uint256 stakers, uint256 jackpot, uint256 oracle, uint256 team);
    event JackpotFinalized(uint256 indexed k, uint256 pot, uint256 winners, uint256 share, uint256 carried);
    event LossHistory(uint256 indexed k, uint256 totalEligibleLoss, uint256 cumulativeBefore, uint256 cumulativeAfter);
    event Claimed(uint256 indexed k, address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Fed(address indexed from, uint256 amount);
    event JackpotDeposited(address indexed from, uint256 indexed k, uint256 amount);
    event OracleFunded(address indexed from, uint256 amount);
    event OracleRequested(uint256 indexed k, bytes32 indexed intakeRequestId, uint256 price);
    event SettingScheduled(bytes32 indexed setting, bytes value, uint64 readyAt);
    event SettingExecuted(bytes32 indexed setting, bytes value);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyTeam() {
        if (msg.sender != TEAM) revert NotTeam();
        _;
    }

    /// @param team_ The launch wallet. Receives the 1% TEAM share and holds the timelocked settings.
    /// @param attester_ IMD's oracle attester key, read from a real attestation (see README).
    /// @param intake_ IMD's on-chain Intake, which sells oracle requests for IMD.
    constructor(address team_, address attester_, address intake_) {
        if (team_ == address(0) || attester_ == address(0) || intake_ == address(0)) revert ZeroAddress();
        TEAM = team_;
        ATTESTER = attester_;
        INTAKE = intake_;
    }

    // ----------------------------------------------------------------- time
    function windowStart(uint256 k) public pure returns (uint64) {
        if (k > (type(uint64).max - GENESIS - TIMEOUT) / WINDOW_DURATION - 1) revert WindowTooFar();
        return GENESIS + uint64(k) * WINDOW_DURATION;
    }

    function windowEnd(uint256 k) public pure returns (uint64) {
        return windowStart(k) + WINDOW_DURATION;
    }

    /// @notice The window whose rounds contain `block.timestamp`; zero before genesis.
    function currentWindow() public view returns (uint256) {
        return block.timestamp < GENESIS ? 0 : (block.timestamp - GENESIS) / WINDOW_DURATION;
    }

    /// @notice The earliest window that has not started: where external jackpot deposits go.
    function earliestNotStartedWindow() public view returns (uint256) {
        return block.timestamp < GENESIS ? 0 : currentWindow() + 1;
    }

    function isBettingOpen(uint256 k) public view returns (bool) {
        uint64 startsAt = windowStart(k);
        return block.timestamp < startsAt && startsAt <= block.timestamp + OPEN_AHEAD;
    }

    // ----------------------------------------------------------------- betting
    /// @notice OVER (side = true) or UNDER (side = false) the window's line. Market id 0.
    function betOverUnder(uint256 k, bool over, uint256 amount) external nonReentrant {
        Window storage w = _openForBet(k, amount);
        Position storage p = _register(k, w);
        if (over) {
            w.over = _add(w.over, amount);
            p.over = _add(p.over, amount);
        } else {
            w.under = _add(w.under, amount);
            p.under = _add(p.under, amount);
        }
        windowFunds[k] += amount;
        _pull(msg.sender, amount);
        emit BinaryBet(k, msg.sender, 0, over, amount);
    }

    /// @notice SNOOZE YES (side = true: result below 100) or NO. Market id 1.
    function betSnooze(uint256 k, bool yes, uint256 amount) external nonReentrant {
        Window storage w = _openForBet(k, amount);
        Position storage p = _register(k, w);
        if (yes) {
            w.yes = _add(w.yes, amount);
            p.yes = _add(p.yes, amount);
        } else {
            w.no = _add(w.no, amount);
            p.no = _add(p.no, amount);
        }
        windowFunds[k] += amount;
        _pull(msg.sender, amount);
        emit BinaryBet(k, msg.sender, 1, yes, amount);
    }

    /// @notice One 5 IMD EXACT ticket per address per window; wins if within 0.5% of the result.
    function buyTicket(uint256 k, uint256 guess) external nonReentrant {
        Window storage w = _openForBet(k, TICKET_PRICE);
        if (guess > MAX_GUESS) revert InvalidGuess();
        Position storage p = _positions[k][msg.sender];
        if (p.hasTicket) revert DuplicateTicket();
        if (w.tickets >= MAX_TICKETS) revert TicketsFull();
        p.hasTicket = true;
        p.guess = uint64(guess);
        w.tickets += 1;
        _guesses[k].push(uint64(guess));
        windowFunds[k] += TICKET_PRICE;
        _pull(msg.sender, TICKET_PRICE);
        emit TicketBought(k, msg.sender, guess);
    }

    function _openForBet(uint256 k, uint256 amount) private returns (Window storage w) {
        if (amount < MIN_BET) revert BelowMinimum();
        if (!isBettingOpen(k)) revert BettingClosed();
        w = _windows[k];
        if (w.status == Status.None) {
            w.status = Status.Open;
            w.startsAt = windowStart(k);
            w.endsAt = windowEnd(k);
            w.line = line;
            emit WindowCreated(k, w.startsAt, w.endsAt, w.line);
        }
    }

    function _register(uint256 k, Window storage) private returns (Position storage p) {
        p = _positions[k][msg.sender];
        if (!p.registered) {
            if (_bettors[k].length >= MAX_BINARY_BETTORS) revert TooManyBettors();
            p.registered = true;
            _bettors[k].push(msg.sender);
        }
    }

    function _add(uint128 a, uint256 b) private pure returns (uint128) {
        uint256 c = uint256(a) + b;
        if (c > type(uint128).max) revert PoolLimit();
        return uint128(c);
    }

    // ----------------------------------------------------------------- oracle
    /// @notice The exact question text bound to window `k`'s six round ids, genesis and source.
    function question(uint256 k) public pure returns (string memory) {
        uint256 r = k * WINDOW_ROUNDS;
        return string.concat(
            "What is the total number of wheel passes recorded by Squeekchain for rounds ",
            _str(r),
            ", ",
            _str(r + 1),
            ", ",
            _str(r + 2),
            ", ",
            _str(r + 3),
            ", ",
            _str(r + 4),
            " and ",
            _str(r + 5),
            " (each round lasts 600 seconds and round 0 began at Unix time ",
            _str(GENESIS),
            "), as published at ",
            SOURCE,
            "? Answer as a single uint256 equal to the sum of the six published PASSES values. If any of the six rounds has not been published as settled, the question is unanswerable; never answer 0 for missing data."
        );
    }

    /// @notice Canonical IMD question document (sorted keys) whose keccak-256 the attestation carries.
    function questionDocument(uint256 k, uint64 fromBlock, uint64 toBlock) public view returns (string memory) {
        return string.concat(
            '{"answerType":"uint256","chainId":',
            _str(block.chainid),
            ',"evidence":"panel","question":"',
            question(k),
            '","v":1,"window":{"fromBlock":',
            _str(fromBlock),
            ',"toBlock":',
            _str(toBlock),
            "}}"
        );
    }

    function questionHash(uint256 k, uint64 fromBlock, uint64 toBlock) public view returns (bytes32) {
        return keccak256(bytes(questionDocument(k, fromBlock, toBlock)));
    }

    /// @notice The oracle.request body the contract sends to the Intake for window `k`.
    function requestBody(uint256 k) public view returns (string memory) {
        return string.concat(
            '{"v":1,"question":"',
            question(k),
            '","chainId":',
            _str(block.chainid),
            ',"window":{"hours":24},"answerType":"uint256","evidence":"panel","panelSize":5,"quorum":4,"validForSeconds":86400}'
        );
    }

    function attestationDigest(OracleAttestation.Attestation calldata a) public view returns (bytes32) {
        return a.digest(block.chainid, address(this));
    }

    /// @notice Pays 0.5 IMD from the oracle reserve to the Intake for window `k`'s question, once.
    /// The signed answer comes back through `onOracleResult`. Anyone may call after the window ends.
    function requestOracle(uint256 k) external nonReentrant returns (bytes32 intakeRequestId) {
        Window storage w = _windows[k];
        if (w.status != Status.Open || block.timestamp < w.endsAt || block.timestamp >= w.endsAt + TIMEOUT) {
            revert NotSettleable();
        }
        if (oracleRequested[k]) revert AlreadyRequested();
        if (oracleReserve < ORACLE_PRICE) revert ReserveTooLow();
        oracleRequested[k] = true;
        oracleReserve -= ORACLE_PRICE;
        if (!IERC20(IMD).approve(INTAKE, ORACLE_PRICE)) revert TransferFailed();
        intakeRequestId = IIntake(INTAKE)
            .request(
                ORACLE_ACTION,
                bytes(requestBody(k)),
                IIntake.Callback(address(this), this.onOracleResult.selector),
                IMD,
                ORACLE_PRICE
            );
        _intakeWindow[intakeRequestId] = k + 1;
        emit OracleRequested(k, intakeRequestId, ORACLE_PRICE);
    }

    /// @notice Intake callback with the signed answer to a request this contract paid for.
    function onOracleResult(bytes32 intakeRequestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        if (msg.sender != INTAKE) revert NotIntake();
        uint256 k1 = _intakeWindow[intakeRequestId];
        if (k1 == 0) revert UnknownRequest();
        _settle(k1 - 1, a, signature);
    }

    /// @notice Settles window `k` from an attestation anyone fetched from the IMD API.
    function settle(uint256 k, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        _settle(k, a, signature);
    }

    function _settle(uint256 k, OracleAttestation.Attestation calldata a, bytes calldata signature) private {
        Window storage w = _windows[k];
        if (w.status != Status.Open || block.timestamp < w.endsAt || block.timestamp >= w.endsAt + TIMEOUT) {
            revert NotSettleable();
        }
        if (a.questionHash != questionHash(k, a.fromBlock, a.toBlock)) revert WrongQuestion();
        if (a.chainId != block.chainid) revert WrongChain();
        if (a.answerType != OracleAttestation.ANSWER_UINT256 || a.answer.length != 32) revert InvalidAnswer();
        if (
            a.panelSize < MIN_PANEL || a.agreed < MIN_AGREED || a.agreed < a.quorum || a.agreed > a.panelSize
                || a.quorum == 0
        ) revert WeakPanel();
        if (a.issuedAt < w.endsAt) revert AttestationPredatesEnd();
        if (a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE || a.issuedAt > a.expiresAt) revert InvalidValidity();
        if (block.timestamp > a.expiresAt) revert InvalidValidity();
        if (consumedRequest[a.requestId]) revert AlreadyConsumed();
        if (OracleAttestation.recover(attestationDigest(a), signature) != ATTESTER) revert BadSignature();
        consumedRequest[a.requestId] = true;

        uint256 result = abi.decode(a.answer, (uint256));
        w.status = Status.Settled;
        w.result = result;
        w.requestId = a.requestId;
        emit Settled(k, result, a.requestId, msg.sender);

        uint256 stakers;
        uint256 jackpot;
        uint256 oracle;
        uint256 team;

        // OVER/UNDER: refunded fully when asleep or one-sided.
        if (result < SNOOZE_THRESHOLD || w.over == 0 || w.under == 0) {
            w.ouVoid = true;
            emit MarketVoided(k, 0);
        } else {
            uint256 pool = uint256(w.over) + w.under;
            uint256 s = pool * BINARY_STAKERS_PCT / 100;
            uint256 j = pool * BINARY_JACKPOT_PCT / 100;
            uint256 o = pool * BINARY_ORACLE_PCT / 100;
            uint256 t = pool * BINARY_TEAM_PCT / 100;
            w.ouWinnerPool = pool - s - j - o - t;
            stakers += s;
            jackpot += j;
            oracle += o;
            team += t;
        }
        // SNOOZE: refunded fully when one-sided.
        if (w.yes == 0 || w.no == 0) {
            w.snVoid = true;
            emit MarketVoided(k, 1);
        } else {
            uint256 pool = uint256(w.yes) + w.no;
            uint256 s = pool * BINARY_STAKERS_PCT / 100;
            uint256 j = pool * BINARY_JACKPOT_PCT / 100;
            uint256 o = pool * BINARY_ORACLE_PCT / 100;
            uint256 t = pool * BINARY_TEAM_PCT / 100;
            w.snWinnerPool = pool - s - j - o - t;
            stakers += s;
            jackpot += j;
            oracle += o;
            team += t;
        }
        // EXACT tickets: 93% to this window's jackpot contribution, fees on the rest.
        if (w.tickets > 0) {
            uint256 pool = uint256(w.tickets) * TICKET_PRICE;
            uint256 s = pool * TICKET_STAKERS_PCT / 100;
            uint256 o = pool * TICKET_ORACLE_PCT / 100;
            uint256 t = pool * TICKET_TEAM_PCT / 100;
            w.jackpotContribution = pool - s - o - t;
            stakers += s;
            oracle += o;
            team += t;
        }
        w.jackpotFees = jackpot;
        windowFunds[k] -= stakers + jackpot + oracle + team + w.jackpotContribution;
        _creditStakers(stakers);
        oracleReserve += oracle;
        balances[TEAM] += team;
        emit FeesAllocated(k, stakers, jackpot, oracle, team);
    }

    /// @notice Permissionless terminal transition for a window nobody settled within 48 hours.
    function timeout(uint256 k) external {
        _timeout(k);
    }

    function _timeout(uint256 k) private {
        Window storage w = _windows[k];
        if (w.status != Status.Open) revert NotTimedOut();
        if (block.timestamp < w.endsAt + TIMEOUT) revert NotTimedOut();
        w.status = Status.TimedOut;
        emit TimedOut(k);
    }

    // ----------------------------------------------------------------- jackpot
    /// @notice Finalizes jackpot accounting and loss history strictly in window order, up to
    /// `maxWindows` windows. Stops at a window that is still open and not yet timed out.
    function finalize(uint256 maxWindows) external {
        uint256 k = nextFinalizeWindow;
        for (uint256 i; i < maxWindows; ++i) {
            Window storage w = _windows[k];
            if (w.status == Status.Open) {
                if (block.timestamp < w.endsAt + TIMEOUT) break;
                _timeout(k);
            } else if (w.status == Status.None) {
                if (block.timestamp < windowEnd(k) + TIMEOUT) break;
            }
            _finalizeOne(k, w);
            unchecked {
                ++k;
            }
        }
        nextFinalizeWindow = k;
    }

    function _finalizeOne(uint256 k, Window storage w) private {
        uint256 pot = jackpotSeed + pendingJackpotDeposits[k];
        pendingJackpotDeposits[k] = 0;
        uint256 winners;
        uint256 share;
        uint256 eligibleLoss;
        if (w.status == Status.Settled) {
            pot += w.jackpotContribution + w.jackpotFees;
            if (w.result >= SNOOZE_THRESHOLD) {
                uint64[] storage guesses = _guesses[k];
                uint256 n = guesses.length;
                for (uint256 i; i < n; ++i) {
                    if (isWinningGuess(guesses[i], w.result)) ++winners;
                }
            }
            if (winners > 0) {
                share = pot * JACKPOT_PAYOUT_PCT / 100 / winners;
                w.jackpotWinners = uint32(winners);
                w.jackpotShare = share;
                jackpotOutstanding += share * winners;
            }
            eligibleLoss = _sumEligibleLoss(k, w);
        }
        w.jackpotPot = pot;
        w.finalized = true;
        jackpotSeed = pot - share * winners;
        totalEligibleLoss[k] = eligibleLoss;
        cumulativeLossBefore[k] = cumulativeLoss;
        cumulativeLoss += eligibleLoss;
        cumulativeLossAfter[k] = cumulativeLoss;
        emit JackpotFinalized(k, pot, winners, share, jackpotSeed);
        emit LossHistory(k, eligibleLoss, cumulativeLossBefore[k], cumulativeLoss);
    }

    function _sumEligibleLoss(uint256 k, Window storage w) private view returns (uint256 total) {
        address[] storage bettors = _bettors[k];
        uint256 n = bettors.length;
        for (uint256 i; i < n; ++i) {
            total += _loss(w, _positions[k][bettors[i]]);
        }
    }

    /// @notice Wins iff |guess - result| * 1000 <= result * 5, evaluated without overflow.
    function isWinningGuess(uint256 guess, uint256 result) public pure returns (bool) {
        uint256 diff = guess > result ? guess - result : result - guess;
        if (diff > type(uint256).max / 200) return false;
        return diff * 200 <= result;
    }

    // ----------------------------------------------------------------- deposits
    /// @notice 90% to the jackpot (earliest not-started window), 10% to the Squeektoshi tip jar.
    function feedHamster(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 tip = amount * FEED_TIP_PCT / 100;
        _depositJackpot(amount - tip);
        if (tipRecipient == address(0)) pendingTips += tip;
        else balances[tipRecipient] += tip;
        _pull(msg.sender, amount);
        emit Fed(msg.sender, amount);
    }

    /// @notice External jackpot deposit (donations, a future token hook): all to the pending bucket.
    function depositJackpot(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _depositJackpot(amount);
        _pull(msg.sender, amount);
    }

    function _depositJackpot(uint256 amount) private {
        uint256 k = earliestNotStartedWindow();
        pendingJackpotDeposits[k] += amount;
        emit JackpotDeposited(msg.sender, k, amount);
    }

    /// @notice Anyone may top up the reserve that pays Intake oracle requests.
    function fundOracleReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        oracleReserve += amount;
        _pull(msg.sender, amount);
        emit OracleFunded(msg.sender, amount);
    }

    // ----------------------------------------------------------------- claims
    /// @notice Pays everything window `k` owes the caller that has not been paid yet. Never expires;
    /// may be called again once the jackpot for `k` is finalized.
    function claim(uint256 k) external nonReentrant {
        Window storage w = _windows[k];
        if (w.status != Status.Settled && w.status != Status.TimedOut) revert NotFinal();
        Position storage p = _positions[k][msg.sender];
        (uint256 binary, uint256 ticket, uint256 jackpot) = _entitlements(w, p);
        // Window entitlements are fixed once terminal; the jackpot share appears at finalization.
        uint256 base = binary + ticket;
        uint256 dueBase = base - p.paid;
        uint256 dueJackpot = jackpot > 0 && !p.jackpotPaid ? jackpot : 0;
        uint256 due = dueBase + dueJackpot;
        if (due == 0) revert NothingToClaim();
        p.paid = base;
        if (dueJackpot > 0) p.jackpotPaid = true;
        windowFunds[k] -= dueBase;
        jackpotOutstanding -= dueJackpot;
        _push(msg.sender, due);
        emit Claimed(k, msg.sender, due);
    }

    /// @notice Pulls an accrued TEAM, tip jar, or staking recipient balance.
    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingToClaim();
        balances[msg.sender] = 0;
        _push(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _entitlements(Window storage w, Position storage p)
        private
        view
        returns (uint256 binary, uint256 ticket, uint256 jackpot)
    {
        if (w.status == Status.TimedOut) {
            binary = uint256(p.over) + p.under + p.yes + p.no;
            ticket = p.hasTicket ? TICKET_PRICE : 0;
        } else if (w.status == Status.Settled) {
            binary = _binaryEntitlement(w, p);
            if (p.hasTicket && w.finalized && w.jackpotShare > 0 && isWinningGuess(p.guess, w.result)) {
                jackpot = w.jackpotShare;
            }
        }
    }

    function _binaryEntitlement(Window storage w, Position storage p) private view returns (uint256 amount) {
        if (w.ouVoid) {
            amount = uint256(p.over) + p.under;
        } else if (w.result > w.line) {
            amount = uint256(p.over) * w.ouWinnerPool / w.over;
        } else {
            amount = uint256(p.under) * w.ouWinnerPool / w.under;
        }
        if (w.snVoid) {
            amount += uint256(p.yes) + p.no;
        } else if (w.result < SNOOZE_THRESHOLD) {
            amount += uint256(p.yes) * w.snWinnerPool / w.yes;
        } else {
            amount += uint256(p.no) * w.snWinnerPool / w.no;
        }
    }

    function _loss(Window storage w, Position storage p) private view returns (uint256) {
        uint256 paid = uint256(p.over) + p.under + p.yes + p.no;
        uint256 back = _binaryEntitlement(w, p);
        return paid > back ? paid - back : 0;
    }

    // ----------------------------------------------------------------- views
    /// @notice Net binary principal lost by `account` in window `k`: max(0, paid - refunds - payouts),
    /// netted across OVER/UNDER and SNOOZE, EXACT excluded. Zero until settled; zero after a timeout.
    function lossOf(uint256 k, address account) external view returns (uint256) {
        Window storage w = _windows[k];
        if (w.status != Status.Settled) return 0;
        return _loss(w, _positions[k][account]);
    }

    /// @notice What `account` can still claim from window `k` right now.
    function claimable(uint256 k, address account) external view returns (uint256) {
        Window storage w = _windows[k];
        if (w.status != Status.Settled && w.status != Status.TimedOut) return 0;
        Position storage p = _positions[k][account];
        (uint256 b, uint256 t, uint256 j) = _entitlements(w, p);
        return b + t - p.paid + (p.jackpotPaid ? 0 : j);
    }

    function position(uint256 k, address account) external view returns (Position memory) {
        return _positions[k][account];
    }

    function bettorCount(uint256 k) external view returns (uint256) {
        return _bettors[k].length;
    }

    function guessAt(uint256 k, uint256 i) external view returns (uint256) {
        return _guesses[k][i];
    }

    /// @notice One view per window for the site and agents.
    function windowInfo(uint256 k) external view returns (WindowView memory v) {
        Window storage w = _windows[k];
        v.index = k;
        v.status = w.status;
        v.startsAt = windowStart(k);
        v.endsAt = windowEnd(k);
        v.closesAt = v.startsAt;
        v.timeoutAt = v.endsAt + TIMEOUT;
        v.line = w.status == Status.None ? line : w.line;
        v.result = w.result;
        v.over = w.over;
        v.under = w.under;
        v.yes = w.yes;
        v.no = w.no;
        v.tickets = w.tickets;
        v.ouVoid = w.ouVoid;
        v.snVoid = w.snVoid;
        v.jackpotFinalized = w.finalized;
        v.jackpotPot = w.jackpotPot;
        v.jackpotWinners = w.jackpotWinners;
        v.jackpotShare = w.jackpotShare;
        v.pendingJackpotDeposits = pendingJackpotDeposits[k];
        v.oracleRequested = oracleRequested[k];
        v.requestId = w.requestId;
    }

    /// @notice Sum of every IMD liability the contract tracks, excluding per-window funds, which are
    /// read with `windowFunds(k)`.
    function trackedLiabilities() external view returns (uint256) {
        return _sumBalancesLess() + jackpotSeed + jackpotOutstanding + oracleReserve + pendingStakingFees + pendingTips;
    }

    function _sumBalancesLess() private view returns (uint256 total) {
        total = balances[TEAM];
        if (stakingRecipient != address(0) && stakingRecipient != TEAM) total += balances[stakingRecipient];
        if (tipRecipient != address(0) && tipRecipient != TEAM && tipRecipient != stakingRecipient) {
            total += balances[tipRecipient];
        }
    }

    // ----------------------------------------------------------------- TEAM settings (12h timelock)
    function scheduleLine(uint256 newLine) external onlyTeam {
        if (newLine == 0) revert InvalidLine();
        _schedule(SETTING_LINE, abi.encode(newLine));
    }

    /// @notice Applies only to windows created after execution; existing windows keep their snapshot.
    function executeLine(uint256 newLine) external onlyTeam {
        _execute(SETTING_LINE, abi.encode(newLine));
        line = newLine;
    }

    function scheduleStakingRecipient(address recipient) external onlyTeam {
        if (recipient == address(0)) revert ZeroAddress();
        if (stakingRecipient != address(0)) revert AlreadySet();
        _schedule(SETTING_STAKING, abi.encode(recipient));
    }

    function executeStakingRecipient(address recipient) external onlyTeam {
        if (stakingRecipient != address(0)) revert AlreadySet();
        _execute(SETTING_STAKING, abi.encode(recipient));
        stakingRecipient = recipient;
        balances[recipient] += pendingStakingFees;
        pendingStakingFees = 0;
    }

    function scheduleTipRecipient(address recipient) external onlyTeam {
        if (recipient == address(0)) revert ZeroAddress();
        if (tipRecipient != address(0)) revert AlreadySet();
        _schedule(SETTING_TIP, abi.encode(recipient));
    }

    function executeTipRecipient(address recipient) external onlyTeam {
        if (tipRecipient != address(0)) revert AlreadySet();
        _execute(SETTING_TIP, abi.encode(recipient));
        tipRecipient = recipient;
        balances[recipient] += pendingTips;
        pendingTips = 0;
    }

    function _schedule(bytes32 setting, bytes memory value) private {
        uint64 readyAt = uint64(block.timestamp) + TIMELOCK;
        pendingSetting[setting] = Pending(keccak256(value), readyAt);
        emit SettingScheduled(setting, value, readyAt);
    }

    function _execute(bytes32 setting, bytes memory value) private {
        Pending memory p = pendingSetting[setting];
        if (p.readyAt == 0 || p.valueHash != keccak256(value)) revert NothingScheduled();
        if (block.timestamp < p.readyAt) revert TimelockNotReady();
        delete pendingSetting[setting];
        emit SettingExecuted(setting, value);
    }

    // ----------------------------------------------------------------- internals
    function _creditStakers(uint256 amount) private {
        if (amount == 0) return;
        if (stakingRecipient == address(0)) pendingStakingFees += amount;
        else balances[stakingRecipient] += amount;
    }

    function _pull(address from, uint256 amount) private {
        uint256 before = IERC20(IMD).balanceOf(address(this));
        if (!IERC20(IMD).transferFrom(from, address(this), amount)) revert TransferFailed();
        if (IERC20(IMD).balanceOf(address(this)) - before != amount) revert TransferFailed();
    }

    function _push(address to, uint256 amount) private {
        if (!IERC20(IMD).transfer(to, amount)) revert TransferFailed();
    }

    function _str(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            ++digits;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            --digits;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}

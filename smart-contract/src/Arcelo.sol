// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Arcelo is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant ARC_PER_CHECKPOINT = 10;
    uint256 public constant WEEK = 7 days;
    uint256 public constant MONDAY_UTC_OFFSET = 4 days;
    uint256 public constant MAX_REASONABLE_SESSION_DURATION = 7 days;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRIZE_BPS = 8_000;
    bytes32 public constant EXIT_TYPEHASH = keccak256(
        "ExitGame(address player,bytes32 sessionId,uint8 gameId,uint256 weekId,uint256 checkpointsReached,uint256 deadline)"
    );

    struct TokenConfig {
        bool supported;
        uint256 minBet;
        uint256 maxBet;
    }

    struct GameSession {
        address player;
        address token;
        uint256 bet;
        uint8 gameId;
        uint256 weekId;
        uint256 startedAt;
        bool active;
        bool settled;
    }

    struct LeaderboardEntry {
        address player;
        uint256 score;
    }

    mapping(address => TokenConfig) public tokenConfig;
    mapping(address => mapping(address => uint256)) public playerBalance;
    mapping(address => mapping(uint256 => uint256)) public prizePoolByWeek;
    mapping(address => uint256) public platformRevenue;
    mapping(uint256 => mapping(address => uint256)) public arcBalanceByWeek;
    mapping(bytes32 => GameSession) public sessions;
    mapping(address => bytes32) public activeSessionOf;
    mapping(address => uint256) public sessionNonceOf;
    mapping(address => mapping(uint256 => bool)) public prizeDistributed;

    mapping(uint256 => LeaderboardEntry[10]) private _leaderboardByWeek;
    mapping(uint256 => uint256) private _leaderboardSizeByWeek;

    uint256 public genesisWeekStart;
    uint256 public maxSessionDuration;
    address public backendSigner;
    bool public exitSignatureRequired;
    mapping(address => mapping(address => uint256)) public claimablePrize;
    address public gameToken;

    error ZeroAddress();
    error InvalidGenesisWeekStart();
    error InvalidSessionDuration();
    error InvalidBetRange();
    error UnsupportedToken();
    error InvalidAmount();
    error InvalidNativeValue();
    error InsufficientBalance();
    error InvalidGameId();
    error ActiveSessionExists();
    error NoActiveSession();
    error InvalidSession();
    error NotSessionPlayer();
    error ZeroCheckpoints();
    error SignatureExpired();
    error BackendSignerRequired();
    error InvalidExitSignature();
    error WeekNotEnded();
    error PrizeDistributionPendingSessionWindow();
    error PrizeAlreadyDistributed();
    error PastWeek();
    error RevenueExceeded();
    error NativeTransferFailed();
    error DirectNativeTransferUnsupported();
    error ExitSignatureCannotBeDisabled();
    error ClaimablePrizeExceeded();

    event TokenSupportUpdated(address indexed token, bool supported, uint256 minBet, uint256 maxBet);
    event Deposited(address indexed player, address indexed token, uint256 amount);
    event Withdrawn(address indexed player, address indexed token, uint256 amount);
    event GameStarted(
        address indexed player,
        bytes32 indexed sessionId,
        address indexed token,
        uint256 bet,
        uint8 gameId,
        uint256 weekId
    );
    event GameExited(
        address indexed player,
        bytes32 indexed sessionId,
        uint8 gameId,
        uint256 weekId,
        uint256 checkpointsReached,
        uint256 arcAwarded,
        uint256 totalArc
    );
    event GameForfeited(address indexed player, bytes32 indexed sessionId, uint8 gameId, uint256 weekId);
    event GameExpired(address indexed player, bytes32 indexed sessionId, uint8 gameId, uint256 weekId);
    event PrizePoolSeeded(address indexed funder, address indexed token, uint256 indexed weekId, uint256 amount);
    event WeeklyPrizeDistributed(
        address indexed token, uint256 indexed weekId, uint256 totalPool, uint256 paidAmount, uint256 rolloverAmount
    );
    event PrizePaid(
        address indexed token, uint256 indexed weekId, address indexed winner, uint256 rank, uint256 amount
    );
    event PrizeClaimed(address indexed winner, address indexed token, uint256 amount);
    event PrizeRollover(address indexed token, uint256 indexed fromWeekId, uint256 indexed toWeekId, uint256 amount);
    event RevenueWithdrawn(address indexed token, address indexed to, uint256 amount);
    event BackendSignerUpdated(address indexed signer);
    event ExitSignatureRequiredUpdated(bool required);
    event MaxSessionDurationUpdated(uint256 duration);

    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        revert DirectNativeTransferUnsupported();
    }

    function initialize(
        address initialOwner,
        uint256 genesisWeekStart_,
        address backendSigner_,
        uint256 maxSessionDuration_,
        address gameToken_,
        uint256 minBet_,
        uint256 maxBet_
    ) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (backendSigner_ == address(0)) revert BackendSignerRequired();
        if (gameToken_ == address(0)) revert ZeroAddress();
        if (genesisWeekStart_ > block.timestamp || genesisWeekStart_ % WEEK != MONDAY_UTC_OFFSET) {
            revert InvalidGenesisWeekStart();
        }
        _validateSessionDuration(maxSessionDuration_);
        if (minBet_ == 0 || maxBet_ < minBet_) revert InvalidBetRange();

        __Ownable_init(initialOwner);
        __Pausable_init();
        __EIP712_init("Arcelo", "1");

        genesisWeekStart = genesisWeekStart_;
        backendSigner = backendSigner_;
        maxSessionDuration = maxSessionDuration_;
        exitSignatureRequired = true;
        gameToken = gameToken_;
        tokenConfig[gameToken_] = TokenConfig({supported: true, minBet: minBet_, maxBet: maxBet_});
        emit TokenSupportUpdated(gameToken_, true, minBet_, maxBet_);
    }

    function setSupportedToken(address token, bool supported, uint256 minBet, uint256 maxBet) external onlyOwner {
        if (token != gameToken) revert UnsupportedToken();
        if (minBet == 0 || maxBet < minBet) revert InvalidBetRange();
        tokenConfig[token] = TokenConfig({supported: supported, minBet: minBet, maxBet: maxBet});
        emit TokenSupportUpdated(token, supported, minBet, maxBet);
    }

    function deposit(address token, uint256 amount) external payable nonReentrant whenNotPaused {
        _requireSupportedToken(token);
        if (amount == 0) revert InvalidAmount();
        uint256 received = _receiveIn(token, amount);

        playerBalance[msg.sender][token] += received;
        emit Deposited(msg.sender, token, received);
    }

    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        uint256 balance = playerBalance[msg.sender][token];
        if (balance < amount) revert InsufficientBalance();

        playerBalance[msg.sender][token] = balance - amount;
        _transferOut(token, payable(msg.sender), amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    function playerBalanceOf(address player, address token) external view returns (uint256) {
        return playerBalance[player][token];
    }

    function startGame(address token, uint256 bet, uint8 gameId)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 sessionId)
    {
        TokenConfig memory config = _requireSupportedToken(token);
        if (gameId < 1 || gameId > 5) revert InvalidGameId();
        if (bet < config.minBet || bet > config.maxBet) revert InvalidBetRange();
        if (activeSessionOf[msg.sender] != bytes32(0)) revert ActiveSessionExists();
        if (playerBalance[msg.sender][token] < bet) revert InsufficientBalance();

        uint256 weekId = currentWeekId();
        uint256 nonce = ++sessionNonceOf[msg.sender];
        sessionId =
            keccak256(abi.encode(block.chainid, address(this), msg.sender, nonce, gameId, weekId, block.timestamp));

        playerBalance[msg.sender][token] -= bet;
        uint256 revenue = (bet * (BPS_DENOMINATOR - PRIZE_BPS)) / BPS_DENOMINATOR;
        uint256 prize = bet - revenue;
        prizePoolByWeek[token][weekId] += prize;
        platformRevenue[token] += revenue;

        sessions[sessionId] = GameSession({
            player: msg.sender,
            token: token,
            bet: bet,
            gameId: gameId,
            weekId: weekId,
            startedAt: block.timestamp,
            active: true,
            settled: false
        });
        activeSessionOf[msg.sender] = sessionId;

        emit GameStarted(msg.sender, sessionId, token, bet, gameId, weekId);
    }

    function exitGame(bytes32 sessionId, uint256 checkpointsReached, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        GameSession storage session = sessions[sessionId];
        _validateActiveSession(sessionId, session);
        if (session.player != msg.sender) revert NotSessionPlayer();
        if (checkpointsReached == 0) revert ZeroCheckpoints();

        if (block.timestamp > deadline) revert SignatureExpired();
        if (backendSigner == address(0)) revert BackendSignerRequired();
        bytes32 digest =
            hashExit(session.player, sessionId, session.gameId, session.weekId, checkpointsReached, deadline);
        if (ECDSA.recoverCalldata(digest, signature) != backendSigner) revert InvalidExitSignature();

        session.active = false;
        session.settled = true;
        activeSessionOf[msg.sender] = bytes32(0);

        uint256 arcAwarded = checkpointsReached * ARC_PER_CHECKPOINT;
        uint256 totalArc = arcBalanceByWeek[session.weekId][msg.sender] + arcAwarded;
        arcBalanceByWeek[session.weekId][msg.sender] = totalArc;
        _updateLeaderboard(session.weekId, msg.sender, totalArc);

        emit GameExited(msg.sender, sessionId, session.gameId, session.weekId, checkpointsReached, arcAwarded, totalArc);
    }

    function forfeitGame(bytes32 sessionId) external nonReentrant whenNotPaused {
        GameSession storage session = sessions[sessionId];
        _validateActiveSession(sessionId, session);
        if (session.player != msg.sender) revert NotSessionPlayer();

        session.active = false;
        session.settled = true;
        activeSessionOf[msg.sender] = bytes32(0);

        emit GameForfeited(msg.sender, sessionId, session.gameId, session.weekId);
    }

    function expireSession(bytes32 sessionId) external nonReentrant {
        GameSession storage session = sessions[sessionId];
        _validateActiveSession(sessionId, session);
        if (block.timestamp < session.startedAt + maxSessionDuration) revert InvalidSession();

        session.active = false;
        session.settled = true;
        activeSessionOf[session.player] = bytes32(0);

        emit GameExpired(session.player, sessionId, session.gameId, session.weekId);
    }

    function arcBalanceOf(uint256 weekId, address player) external view returns (uint256) {
        return arcBalanceByWeek[weekId][player];
    }

    function currentArcBalanceOf(address player) external view returns (uint256) {
        return arcBalanceByWeek[currentWeekId()][player];
    }

    function getTopPlayers(uint256 weekId) public view returns (address[] memory players, uint256[] memory scores) {
        uint256 size = _leaderboardSizeByWeek[weekId];
        players = new address[](size);
        scores = new uint256[](size);
        LeaderboardEntry[10] storage board = _leaderboardByWeek[weekId];
        for (uint256 i; i < size; ++i) {
            players[i] = board[i].player;
            scores[i] = board[i].score;
        }
    }

    function getCurrentTopPlayers() external view returns (address[] memory players, uint256[] memory scores) {
        return getTopPlayers(currentWeekId());
    }

    function rankOf(uint256 weekId, address player) external view returns (uint256 rank) {
        uint256 size = _leaderboardSizeByWeek[weekId];
        LeaderboardEntry[10] storage board = _leaderboardByWeek[weekId];
        for (uint256 i; i < size; ++i) {
            if (board[i].player == player) return i + 1;
        }
        return 0;
    }

    function seedPrizePool(address token, uint256 amount, uint256 weekId) public payable nonReentrant whenNotPaused {
        _seedPrizePool(token, amount, weekId);
    }

    function seedCurrentPrizePool(address token, uint256 amount) external payable nonReentrant whenNotPaused {
        _seedPrizePool(token, amount, currentWeekId());
    }

    function _seedPrizePool(address token, uint256 amount, uint256 weekId) internal {
        _requireSupportedToken(token);
        if (amount == 0) revert InvalidAmount();
        if (weekId < currentWeekId()) revert PastWeek();
        if (prizeDistributed[token][weekId]) revert PrizeAlreadyDistributed();

        uint256 received = _receiveIn(token, amount);

        prizePoolByWeek[token][weekId] += received;
        emit PrizePoolSeeded(msg.sender, token, weekId, received);
    }

    function distributeWeeklyPrize(address token, uint256 weekId) external nonReentrant onlyOwner {
        if (token != gameToken) revert UnsupportedToken();
        uint256 totalPool = prizePoolByWeek[token][weekId];
        if (!tokenConfig[token].supported && totalPool == 0) revert UnsupportedToken();
        if (weekId >= currentWeekId()) revert WeekNotEnded();
        if (block.timestamp < _weekStart(weekId + 1) + maxSessionDuration) {
            revert PrizeDistributionPendingSessionWindow();
        }
        if (prizeDistributed[token][weekId]) revert PrizeAlreadyDistributed();

        prizePoolByWeek[token][weekId] = 0;
        prizeDistributed[token][weekId] = true;

        uint256 size = _leaderboardSizeByWeek[weekId];
        address[] memory winners = new address[](size);
        uint256[] memory amounts = new uint256[](size);
        uint256 paidAmount;

        for (uint256 i; i < size; ++i) {
            uint256 amount = (totalPool * _prizeBps(i)) / BPS_DENOMINATOR;
            winners[i] = _leaderboardByWeek[weekId][i].player;
            amounts[i] = amount;
            paidAmount += amount;
        }

        uint256 rolloverAmount = totalPool - paidAmount;
        uint256 targetWeek = currentWeekId();
        if (rolloverAmount > 0) {
            prizePoolByWeek[token][targetWeek] += rolloverAmount;
            emit PrizeRollover(token, weekId, targetWeek, rolloverAmount);
        }

        for (uint256 i; i < size; ++i) {
            if (amounts[i] == 0) continue;
            claimablePrize[winners[i]][token] += amounts[i];
            emit PrizePaid(token, weekId, winners[i], i + 1, amounts[i]);
        }

        emit WeeklyPrizeDistributed(token, weekId, totalPool, paidAmount, rolloverAmount);
    }

    function claimPrize(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 claimable = claimablePrize[msg.sender][token];
        if (claimable < amount) revert ClaimablePrizeExceeded();

        claimablePrize[msg.sender][token] = claimable - amount;
        _transferOut(token, payable(msg.sender), amount);
        emit PrizeClaimed(msg.sender, token, amount);
    }

    function withdrawRevenue(address token, address payable to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (platformRevenue[token] < amount) revert RevenueExceeded();

        platformRevenue[token] -= amount;
        _transferOut(token, to, amount);
        emit RevenueWithdrawn(token, to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setBackendSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert BackendSignerRequired();
        backendSigner = signer;
        emit BackendSignerUpdated(signer);
    }

    function setExitSignatureRequired(bool required) external onlyOwner {
        if (!required) revert ExitSignatureCannotBeDisabled();
        if (required && backendSigner == address(0)) revert BackendSignerRequired();
        exitSignatureRequired = required;
        emit ExitSignatureRequiredUpdated(required);
    }

    function setMaxSessionDuration(uint256 duration) external onlyOwner {
        _validateSessionDuration(duration);
        maxSessionDuration = duration;
        emit MaxSessionDurationUpdated(duration);
    }

    function getWeekId(uint256 timestamp) public view returns (uint256) {
        if (timestamp < genesisWeekStart) revert InvalidGenesisWeekStart();
        return (timestamp - genesisWeekStart) / WEEK;
    }

    function currentWeekId() public view returns (uint256) {
        return getWeekId(block.timestamp);
    }

    function weekStart(uint256 weekId) external view returns (uint256) {
        return _weekStart(weekId);
    }

    function hashExit(
        address player,
        bytes32 sessionId,
        uint8 gameId,
        uint256 weekId,
        uint256 checkpointsReached,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(EXIT_TYPEHASH, player, sessionId, gameId, weekId, checkpointsReached, deadline))
        );
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _requireSupportedToken(address token) internal view returns (TokenConfig memory config) {
        if (token != gameToken) revert UnsupportedToken();
        config = tokenConfig[token];
        if (!config.supported) revert UnsupportedToken();
    }

    function _validateSessionDuration(uint256 duration) internal pure {
        if (duration == 0 || duration > MAX_REASONABLE_SESSION_DURATION) revert InvalidSessionDuration();
    }

    function _validateActiveSession(bytes32 sessionId, GameSession storage session) internal view {
        if (session.player == address(0) || !session.active || session.settled) revert InvalidSession();
        if (activeSessionOf[session.player] != sessionId) revert NoActiveSession();
    }

    function _weekStart(uint256 weekId) internal view returns (uint256) {
        return genesisWeekStart + (weekId * WEEK);
    }

    function _updateLeaderboard(uint256 weekId, address player, uint256 score) internal {
        LeaderboardEntry[10] storage board = _leaderboardByWeek[weekId];
        uint256 size = _leaderboardSizeByWeek[weekId];
        uint256 index = type(uint256).max;

        for (uint256 i; i < size; ++i) {
            if (board[i].player == player) {
                index = i;
                break;
            }
        }

        if (index != type(uint256).max) {
            board[index].score = score;
        } else if (size < 10) {
            board[size] = LeaderboardEntry({player: player, score: score});
            _leaderboardSizeByWeek[weekId] = size + 1;
            size += 1;
        } else if (_isBetter(player, score, board[9].player, board[9].score)) {
            board[9] = LeaderboardEntry({player: player, score: score});
        } else {
            return;
        }

        for (uint256 i = 1; i < size; ++i) {
            LeaderboardEntry memory key = board[i];
            uint256 j = i;
            while (j > 0 && _isBetter(key.player, key.score, board[j - 1].player, board[j - 1].score)) {
                board[j] = board[j - 1];
                --j;
            }
            board[j] = key;
        }
    }

    function _isBetter(address player, uint256 score, address otherPlayer, uint256 otherScore)
        internal
        pure
        returns (bool)
    {
        if (score != otherScore) return score > otherScore;
        return uint160(player) < uint160(otherPlayer);
    }

    function _transferOut(address token, address payable to, uint256 amount) internal {
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _receiveIn(address token, uint256 amount) internal returns (uint256 received) {
        if (token == address(0)) {
            if (msg.value != amount) revert InvalidNativeValue();
            return amount;
        }

        if (msg.value != 0) revert InvalidNativeValue();
        IERC20 erc20 = IERC20(token);
        uint256 beforeBalance = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(msg.sender, address(this), amount);
        received = erc20.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InvalidAmount();
    }

    function _prizeBps(uint256 index) internal pure returns (uint256) {
        if (index == 0) return 3500;
        if (index == 1) return 2000;
        if (index == 2) return 1500;
        if (index == 3 || index == 4) return 1000;
        return 200;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/INeuronToken.sol";

/**
 * @title AxonArena
 * @notice On-chain AI Agent Quiz Arena on Monad
 * @dev Match lifecycle: Queue -> QuestionRevealed -> AnswerPeriod -> Settled/Refunded
 *
 * Economic model:
 * - Entry: MON deposit to join queue
 * - Answers: $NEURON burn per attempt (doubles each attempt per match)
 * - Settlement: 90% to winner, 5% to treasury, 5% accumulated for winner's NEURON buyback
 */
contract AxonArena is Ownable, ReentrancyGuard {
    // ============ Type Definitions ============

    /**
     * @notice Match lifecycle phases
     * @dev Queue: Accepting players, waiting for minPlayers or timeout
     *      QuestionRevealed: Question posted, waiting for answer period to start
     *      AnswerPeriod: Active answering, NEURON burned per attempt
     *      Settled: Winner determined, prizes distributed
     *      Refunded: Match cancelled, entry fees returned
     */
    enum MatchPhase {
        Queue,
        QuestionRevealed,
        AnswerPeriod,
        Settled,
        Refunded
    }

    /**
     * @notice Match configuration (set at creation, immutable during match)
     * @dev Packed for gas efficiency:
     *      - Slot 1: entryFee (uint256)
     *      - Slot 2: baseAnswerFee (uint256)
     *      - Slot 3: queueDeadline (uint64) | answerDuration (uint64) | minPlayers (uint8) | maxPlayers (uint8)
     */
    struct MatchConfig {
        uint256 entryFee;        // MON required to join queue
        uint256 baseAnswerFee;   // Base NEURON burned per answer (doubles each attempt)
        uint64 queueDeadline;    // When queue phase times out
        uint64 answerDuration;   // Duration of answer period in seconds
        uint8 minPlayers;        // Minimum players to start (typically 2)
        uint8 maxPlayers;        // Maximum players allowed (typically 8)
    }

    /**
     * @notice Match dynamic state (changes during match lifecycle)
     * @dev Packed for gas efficiency:
     *      - Slot 1: pool (uint256)
     *      - Slot 2: answerDeadline (uint64) | phase (uint8) | difficulty (uint8) + padding
     *      - Slot 3: winner (address)
     *      - Slot 4: answerHash (bytes32)
     */
    struct MatchState {
        uint256 pool;            // Total MON collected from entries
        uint64 answerDeadline;   // When answer period ends (0 until answer period starts)
        MatchPhase phase;
        uint8 difficulty;        // 1-5 scale
        address winner;
        bytes32 answerHash;      // keccak256(answer + salt), committed before answers
    }

    /**
     * @notice Match question data (set when question is posted)
     * @dev Stored separately to avoid stack-too-deep in functions
     */
    struct MatchQuestion {
        string questionText;
        string category;
        string formatHint;       // Expected answer format (number, hex, text, etc.)
    }

    // ============ Storage ============

    /// @notice The $NEURON token contract for answer fee burns
    INeuronToken public immutable neuronToken;

    /// @notice Treasury address for protocol fees (5% of pool)
    address public treasury;

    /// @notice Authorized operators (can manage matches) - multiple addresses supported
    /// @dev Owner can add/remove operators. Agent Chief wallets should be operators.
    mapping(address => bool) public operators;

    /// @notice Counter for generating unique match IDs
    uint256 public nextMatchId;

    /// @notice Match configuration by ID
    mapping(uint256 => MatchConfig) public matchConfigs;

    /// @notice Match state by ID
    mapping(uint256 => MatchState) public matchStates;

    /// @notice Match question data by ID
    mapping(uint256 => MatchQuestion) public matchQuestions;

    /// @notice Players in each match's queue
    /// @dev matchId => array of player addresses
    mapping(uint256 => address[]) public matchPlayers;

    /// @notice Track if an address is in a specific match
    /// @dev matchId => player => isInMatch
    mapping(uint256 => mapping(address => bool)) public isPlayerInMatch;

    /// @notice Number of answer attempts per agent per match
    /// @dev matchId => agent => attemptCount (used for doubling fee calculation)
    mapping(uint256 => mapping(address => uint256)) public answerAttempts;

    /// @notice Total NEURON burned per match (for stats/events)
    mapping(uint256 => uint256) public matchBurnTotal;

    /// @notice Accumulated NEURON buyback allocation per winner
    /// @dev winner => accumulated MON for NEURON buyback
    mapping(address => uint256) public burnAllocation;

    /// @notice Pending refunds for pull-pattern withdrawal
    /// @dev player => pending MON refund amount
    mapping(address => uint256) public pendingRefunds;

    /// @notice Revealed answer storage (post-settlement)
    /// @dev matchId => revealed answer string
    mapping(uint256 => string) public revealedAnswers;

    // ============ Events ============

    /// @notice Emitted when a new match is created
    event MatchCreated(
        uint256 indexed matchId,
        uint256 entryFee,
        uint256 baseAnswerFee,
        uint64 queueDeadline,
        uint8 minPlayers,
        uint8 maxPlayers
    );

    /// @notice Emitted when an agent joins the match queue
    event AgentJoinedQueue(
        uint256 indexed matchId,
        address indexed agent,
        uint256 playerCount,
        uint256 poolTotal
    );

    /// @notice Emitted when match transitions from Queue to QuestionRevealed
    event MatchStarted(
        uint256 indexed matchId,
        uint256 playerCount,
        uint256 pool
    );

    /// @notice Emitted when question and answer hash are posted
    event QuestionRevealed(
        uint256 indexed matchId,
        string question,
        string category,
        uint8 difficulty,
        string formatHint,
        bytes32 answerHash
    );

    /// @notice Emitted when answer period begins
    event AnswerPeriodStarted(
        uint256 indexed matchId,
        uint256 startTime,
        uint256 deadline
    );

    /// @notice Emitted for each answer submission (regardless of correctness)
    event AnswerSubmitted(
        uint256 indexed matchId,
        address indexed agent,
        string answer,
        uint256 attemptNumber,
        uint256 neuronBurned
    );

    /// @notice Emitted when match is settled with a winner
    event MatchSettled(
        uint256 indexed matchId,
        address indexed winner,
        uint256 winnerPrize,
        uint256 treasuryFee,
        uint256 burnAllocationAmount
    );

    /// @notice Emitted when the correct answer is revealed post-settlement
    event AnswerRevealed(
        uint256 indexed matchId,
        string answer,
        bytes32 salt
    );

    /// @notice Emitted when match is cancelled and refunded
    event MatchRefunded(
        uint256 indexed matchId,
        uint256 playerCount,
        uint256 refundPerPlayer
    );

    /// @notice Emitted when match is cancelled (no players)
    event MatchCancelled(uint256 indexed matchId);

    /// @notice Emitted each time NEURON is burned for an answer
    event NeuronBurned(
        uint256 indexed matchId,
        address indexed agent,
        uint256 amount
    );

    /// @notice Emitted when burn allocation is withdrawn
    event BurnAllocationWithdrawn(
        address indexed winner,
        uint256 amount
    );

    /// @notice Emitted when burn allocation is claimed by operator for swap
    event BurnAllocationClaimed(
        address indexed operator,
        address indexed winner,
        uint256 amount
    );

    /// @notice Emitted when refund is credited (pull pattern)
    event RefundCredited(
        uint256 indexed matchId,
        address indexed player,
        uint256 amount
    );

    /// @notice Emitted when pending refund is withdrawn
    event RefundWithdrawn(
        address indexed player,
        uint256 amount
    );

    /// @notice Emitted when an operator is added
    event OperatorAdded(address indexed operator);

    /// @notice Emitted when an operator is removed
    event OperatorRemoved(address indexed operator);

    /// @notice Emitted when treasury is changed
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============ Errors ============

    error NotOperator();
    error MatchNotFound(uint256 matchId);
    error InvalidPhase(MatchPhase expected, MatchPhase actual);
    error AlreadyInMatch(uint256 matchId, address player);
    error NotInMatch(uint256 matchId, address player);
    error MatchFull(uint256 matchId);
    error InsufficientEntryFee(uint256 required, uint256 provided);
    error QueueDeadlinePassed(uint256 matchId);
    error QueueDeadlineNotPassed(uint256 matchId);
    error NotEnoughPlayers(uint256 required, uint256 actual);
    error AnswerDeadlinePassed(uint256 matchId);
    error AnswerDeadlineNotPassed(uint256 matchId);
    error InvalidAnswerHash();
    error ZeroAddress();
    error NoBurnAllocation();
    error NoPendingRefund();
    error InvalidParameters();

    // ============ Modifiers ============

    /**
     * @notice Restricts function to authorized operators only
     */
    modifier onlyOperator() {
        if (!operators[msg.sender]) revert NotOperator();
        _;
    }

    /**
     * @notice Ensures match exists
     */
    modifier matchExists(uint256 matchId) {
        if (matchId == 0 || matchId >= nextMatchId) revert MatchNotFound(matchId);
        _;
    }

    /**
     * @notice Ensures match is in the expected phase
     */
    modifier onlyPhase(uint256 matchId, MatchPhase expectedPhase) {
        MatchPhase currentPhase = matchStates[matchId].phase;
        if (currentPhase != expectedPhase) revert InvalidPhase(expectedPhase, currentPhase);
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Deploy the AxonArena contract
     * @param _neuronToken Address of the $NEURON token contract
     * @param _treasury Address to receive protocol fees
     * @param _initialOperator Initial operator address (Agent Chief)
     */
    constructor(
        address _neuronToken,
        address _treasury,
        address _initialOperator
    ) Ownable(msg.sender) {
        if (_neuronToken == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_initialOperator == address(0)) revert ZeroAddress();

        neuronToken = INeuronToken(_neuronToken);
        treasury = _treasury;
        operators[_initialOperator] = true;
        nextMatchId = 1; // Start from 1, 0 reserved for "no match"

        emit OperatorAdded(_initialOperator);
    }

    // ============ Admin Functions ============

    /**
     * @notice Add an operator address (can manage matches)
     * @param _operator Address to add as operator
     * @dev Only owner can add operators. Agent Chief wallets should be operators.
     */
    function addOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert ZeroAddress();
        if (operators[_operator]) revert InvalidParameters(); // Already an operator
        operators[_operator] = true;
        emit OperatorAdded(_operator);
    }

    /**
     * @notice Remove an operator address
     * @param _operator Address to remove as operator
     * @dev Only owner can remove operators
     */
    function removeOperator(address _operator) external onlyOwner {
        if (!operators[_operator]) revert InvalidParameters(); // Not an operator
        operators[_operator] = false;
        emit OperatorRemoved(_operator);
    }

    /**
     * @notice Check if an address is an operator
     * @param _operator Address to check
     * @return True if the address is an operator
     */
    function isOperator(address _operator) external view returns (bool) {
        return operators[_operator];
    }

    /**
     * @notice Update the treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    // ============ View Functions ============

    /**
     * @notice Get all players in a match
     * @param matchId The match ID
     * @return Array of player addresses
     */
    function getMatchPlayers(uint256 matchId) external view returns (address[] memory) {
        return matchPlayers[matchId];
    }

    /**
     * @notice Get player count for a match
     * @param matchId The match ID
     * @return Number of players in the match
     */
    function getPlayerCount(uint256 matchId) external view returns (uint256) {
        return matchPlayers[matchId].length;
    }

    /**
     * @notice Calculate the current answer fee for an agent in a match
     * @dev Fee doubles with each attempt: base * 2^attempts
     * @param matchId The match ID
     * @param agent The agent address
     * @return The NEURON amount required for next answer
     */
    function getCurrentAnswerFee(uint256 matchId, address agent) public view returns (uint256) {
        uint256 attempts = answerAttempts[matchId][agent];
        return matchConfigs[matchId].baseAnswerFee * (2 ** attempts);
    }

    /**
     * @notice Get full match config
     * @param matchId The match ID
     * @return config The match configuration
     */
    function getMatchConfig(uint256 matchId) external view returns (MatchConfig memory config) {
        return matchConfigs[matchId];
    }

    /**
     * @notice Get full match state
     * @param matchId The match ID
     * @return state The match state
     */
    function getMatchState(uint256 matchId) external view returns (MatchState memory state) {
        return matchStates[matchId];
    }

    /**
     * @notice Get full match question data
     * @param matchId The match ID
     * @return question The match question
     */
    function getMatchQuestion(uint256 matchId) external view returns (MatchQuestion memory question) {
        return matchQuestions[matchId];
    }

    // ============ Queue Functions (ax-1.3b) ============

    /**
     * @notice Create a new match with specified parameters
     * @param entryFee MON required to join queue
     * @param baseAnswerFee Base NEURON burned per answer (doubles each attempt)
     * @param queueDuration Duration of queue phase in seconds
     * @param answerDuration Duration of answer period in seconds
     * @param minPlayers Minimum players to start match
     * @param maxPlayers Maximum players allowed
     * @return matchId The newly created match ID
     */
    function createMatch(
        uint256 entryFee,
        uint256 baseAnswerFee,
        uint64 queueDuration,
        uint64 answerDuration,
        uint8 minPlayers,
        uint8 maxPlayers
    ) external onlyOperator returns (uint256 matchId) {
        if (entryFee == 0) revert InvalidParameters();
        if (baseAnswerFee == 0) revert InvalidParameters();
        if (queueDuration == 0) revert InvalidParameters();
        if (answerDuration == 0) revert InvalidParameters();
        if (minPlayers < 2) revert InvalidParameters();
        if (maxPlayers < minPlayers) revert InvalidParameters();

        matchId = nextMatchId++;

        matchConfigs[matchId] = MatchConfig({
            entryFee: entryFee,
            baseAnswerFee: baseAnswerFee,
            queueDeadline: uint64(block.timestamp) + queueDuration,
            answerDuration: answerDuration,
            minPlayers: minPlayers,
            maxPlayers: maxPlayers
        });

        matchStates[matchId] = MatchState({
            pool: 0,
            answerDeadline: 0,
            phase: MatchPhase.Queue,
            difficulty: 0,
            winner: address(0),
            answerHash: bytes32(0)
        });

        emit MatchCreated(
            matchId,
            entryFee,
            baseAnswerFee,
            matchConfigs[matchId].queueDeadline,
            minPlayers,
            maxPlayers
        );
    }

    /**
     * @notice Join a match queue by paying the entry fee
     * @param matchId The match to join
     */
    function joinQueue(uint256 matchId)
        external
        payable
        matchExists(matchId)
        onlyPhase(matchId, MatchPhase.Queue)
        nonReentrant
    {
        MatchConfig storage config = matchConfigs[matchId];
        MatchState storage state = matchStates[matchId];

        // Check queue deadline
        if (block.timestamp > config.queueDeadline) revert QueueDeadlinePassed(matchId);

        // Check if already in match
        if (isPlayerInMatch[matchId][msg.sender]) revert AlreadyInMatch(matchId, msg.sender);

        // Check if match is full
        if (matchPlayers[matchId].length >= config.maxPlayers) revert MatchFull(matchId);

        // Check entry fee
        if (msg.value < config.entryFee) revert InsufficientEntryFee(config.entryFee, msg.value);

        // Add player to match
        matchPlayers[matchId].push(msg.sender);
        isPlayerInMatch[matchId][msg.sender] = true;
        state.pool += msg.value;

        // Refund excess
        if (msg.value > config.entryFee) {
            (bool refundSuccess,) = payable(msg.sender).call{value: msg.value - config.entryFee}("");
            require(refundSuccess, "Refund failed");
        }

        emit AgentJoinedQueue(matchId, msg.sender, matchPlayers[matchId].length, state.pool);
    }

    /**
     * @notice Start a match after queue has enough players
     * @dev Called by operator when ready to start (after queue deadline or max players reached)
     * @param matchId The match to start
     */
    function startMatch(uint256 matchId)
        external
        onlyOperator
        matchExists(matchId)
        onlyPhase(matchId, MatchPhase.Queue)
    {
        MatchConfig storage config = matchConfigs[matchId];
        MatchState storage state = matchStates[matchId];
        uint256 playerCount = matchPlayers[matchId].length;

        // Check minimum players
        if (playerCount < config.minPlayers) {
            revert NotEnoughPlayers(config.minPlayers, playerCount);
        }

        // Transition to QuestionRevealed phase (waiting for question to be posted)
        state.phase = MatchPhase.QuestionRevealed;

        emit MatchStarted(matchId, playerCount, state.pool);
    }

    // ============ Question Functions (ax-1.3c) ============

    /**
     * @notice Post the question and answer hash for a match
     * @param matchId The match ID
     * @param question The question text
     * @param category Question category (crypto, math, etc.)
     * @param difficulty Difficulty level 1-5
     * @param formatHint Expected answer format (number, hex, text, etc.)
     * @param answerHash keccak256(answer + salt) committed before answer period
     */
    function postQuestion(
        uint256 matchId,
        string calldata question,
        string calldata category,
        uint8 difficulty,
        string calldata formatHint,
        bytes32 answerHash
    )
        external
        onlyOperator
        matchExists(matchId)
        onlyPhase(matchId, MatchPhase.QuestionRevealed)
    {
        if (answerHash == bytes32(0)) revert InvalidAnswerHash();
        if (difficulty == 0 || difficulty > 5) revert InvalidParameters();

        MatchState storage state = matchStates[matchId];

        // Store question data
        matchQuestions[matchId] = MatchQuestion({
            questionText: question,
            category: category,
            formatHint: formatHint
        });

        // Store answer hash and difficulty
        state.answerHash = answerHash;
        state.difficulty = difficulty;

        emit QuestionRevealed(matchId, question, category, difficulty, formatHint, answerHash);
    }

    /**
     * @notice Start the answer period for a match
     * @param matchId The match ID
     */
    function startAnswerPeriod(uint256 matchId)
        external
        onlyOperator
        matchExists(matchId)
        onlyPhase(matchId, MatchPhase.QuestionRevealed)
    {
        MatchConfig storage config = matchConfigs[matchId];
        MatchState storage state = matchStates[matchId];

        // Ensure question was posted
        if (state.answerHash == bytes32(0)) revert InvalidAnswerHash();

        // Set answer deadline and transition phase
        uint64 startTime = uint64(block.timestamp);
        state.answerDeadline = startTime + config.answerDuration;
        state.phase = MatchPhase.AnswerPeriod;

        emit AnswerPeriodStarted(matchId, startTime, state.answerDeadline);
    }

    // ============ Answer Functions (ax-1.3d) ============

    /**
     * @notice Submit an answer attempt (burns NEURON, fee doubles each attempt)
     * @param matchId The match ID
     * @param answer The submitted answer
     * @dev Requires prior NEURON approval for burn amount
     */
    function submitAnswer(uint256 matchId, string calldata answer)
        external
        matchExists(matchId)
        onlyPhase(matchId, MatchPhase.AnswerPeriod)
        nonReentrant
    {
        MatchState storage state = matchStates[matchId];

        // Check answer deadline
        if (block.timestamp > state.answerDeadline) revert AnswerDeadlinePassed(matchId);

        // Check if player is in match
        if (!isPlayerInMatch[matchId][msg.sender]) revert NotInMatch(matchId, msg.sender);

        // Calculate burn amount (doubles each attempt)
        uint256 attempts = answerAttempts[matchId][msg.sender];
        uint256 burnAmount = matchConfigs[matchId].baseAnswerFee * (2 ** attempts);

        // Burn NEURON from sender (requires approval)
        neuronToken.burnFrom(msg.sender, burnAmount);

        // Update tracking
        answerAttempts[matchId][msg.sender] = attempts + 1;
        matchBurnTotal[matchId] += burnAmount;

        emit NeuronBurned(matchId, msg.sender, burnAmount);
        emit AnswerSubmitted(matchId, msg.sender, answer, attempts + 1, burnAmount);
    }

    // ============ Settlement Functions (ax-1.3e) ============

    /**
     * @notice Settle match with a winner
     * @param matchId The match ID
     * @param winner The winning agent address
     * @dev Distributes: 90% to winner, 5% to treasury, 5% to burn allocation
     */
    function settleWinner(uint256 matchId, address winner)
        external
        onlyOperator
        matchExists(matchId)
        onlyPhase(matchId, MatchPhase.AnswerPeriod)
        nonReentrant
    {
        if (winner == address(0)) revert ZeroAddress();
        if (!isPlayerInMatch[matchId][winner]) revert NotInMatch(matchId, winner);

        MatchState storage state = matchStates[matchId];
        uint256 pool = state.pool;

        // Calculate distribution (90/5/5)
        uint256 winnerPrize = (pool * 90) / 100;
        uint256 treasuryFee = (pool * 5) / 100;
        uint256 burnAllocationAmount = pool - winnerPrize - treasuryFee; // Remaining ~5%

        // Update state
        state.winner = winner;
        state.phase = MatchPhase.Settled;
        burnAllocation[winner] += burnAllocationAmount;

        // Transfer winner prize
        (bool winnerSuccess,) = payable(winner).call{value: winnerPrize}("");
        require(winnerSuccess, "Winner transfer failed");

        // Transfer treasury fee
        (bool treasurySuccess,) = payable(treasury).call{value: treasuryFee}("");
        require(treasurySuccess, "Treasury transfer failed");

        emit MatchSettled(matchId, winner, winnerPrize, treasuryFee, burnAllocationAmount);
    }

    /**
     * @notice Reveal the correct answer post-settlement
     * @param matchId The match ID
     * @param answer The correct answer
     * @param salt The salt used in hash commitment
     * @dev Verifies keccak256(answer, salt) == answerHash
     */
    function revealAnswer(uint256 matchId, string calldata answer, bytes32 salt)
        external
        onlyOperator
        matchExists(matchId)
    {
        MatchState storage state = matchStates[matchId];

        // Only reveal after settlement or refund
        if (state.phase != MatchPhase.Settled && state.phase != MatchPhase.Refunded) {
            revert InvalidPhase(MatchPhase.Settled, state.phase);
        }

        // Verify hash
        bytes32 computedHash = keccak256(abi.encodePacked(answer, salt));
        if (computedHash != state.answerHash) revert InvalidAnswerHash();

        // Store revealed answer
        revealedAnswers[matchId] = answer;

        emit AnswerRevealed(matchId, answer, salt);
    }

    /**
     * @notice Withdraw own accumulated burn allocation
     * @dev Anyone can withdraw their own allocation (e.g., winners)
     */
    function withdrawBurnAllocation() external nonReentrant {
        uint256 amount = burnAllocation[msg.sender];
        if (amount == 0) revert NoBurnAllocation();

        burnAllocation[msg.sender] = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");

        emit BurnAllocationWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim burn allocation on behalf of a winner for NEURON buyback swap
     * @dev Called by operator to get winner's MON for nad.fun swap
     * @param winner The winner whose allocation to claim
     */
    function claimBurnAllocationFor(address winner) external onlyOperator nonReentrant {
        uint256 amount = burnAllocation[winner];
        if (amount == 0) revert NoBurnAllocation();

        burnAllocation[winner] = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Claim failed");

        emit BurnAllocationClaimed(msg.sender, winner, amount);
    }

    // ============ Refund Functions (ax-1.3f) ============

    /**
     * @notice Refund match after answer period timeout with no winner
     * @param matchId The match ID
     * @dev Distributes: 95% equally to players (credited to pendingRefunds), 5% to treasury
     */
    function refundMatch(uint256 matchId)
        external
        onlyOperator
        matchExists(matchId)
        onlyPhase(matchId, MatchPhase.AnswerPeriod)
        nonReentrant
    {
        MatchState storage state = matchStates[matchId];

        // Check that answer deadline has passed
        if (block.timestamp <= state.answerDeadline) revert AnswerDeadlineNotPassed(matchId);

        address[] storage players = matchPlayers[matchId];
        uint256 playerCount = players.length;
        uint256 pool = state.pool;

        // Calculate distribution
        uint256 treasuryFee = (pool * 5) / 100;
        uint256 refundPool = pool - treasuryFee;
        uint256 refundPerPlayer = playerCount > 0 ? refundPool / playerCount : 0;

        // Update state
        state.phase = MatchPhase.Refunded;

        // Transfer treasury fee
        if (treasuryFee > 0) {
            (bool treasurySuccess,) = payable(treasury).call{value: treasuryFee}("");
            require(treasurySuccess, "Treasury transfer failed");
        }

        // Credit refunds to each player (pull pattern - safe against griefing)
        for (uint256 i = 0; i < playerCount; i++) {
            pendingRefunds[players[i]] += refundPerPlayer;
            emit RefundCredited(matchId, players[i], refundPerPlayer);
        }

        emit MatchRefunded(matchId, playerCount, refundPerPlayer);
    }

    /**
     * @notice Cancel match during queue phase (not enough players)
     * @param matchId The match ID
     * @dev Full refund to all players (credited to pendingRefunds), no treasury cut
     */
    function cancelMatch(uint256 matchId)
        external
        onlyOperator
        matchExists(matchId)
        onlyPhase(matchId, MatchPhase.Queue)
        nonReentrant
    {
        MatchConfig storage config = matchConfigs[matchId];
        MatchState storage state = matchStates[matchId];

        // Queue deadline must have passed (can't cancel active queue)
        if (block.timestamp <= config.queueDeadline) revert QueueDeadlineNotPassed(matchId);

        address[] storage players = matchPlayers[matchId];
        uint256 playerCount = players.length;
        uint256 pool = state.pool;

        // Update state
        state.phase = MatchPhase.Refunded;

        // Handle zero players case
        if (playerCount == 0) {
            emit MatchCancelled(matchId);
            return;
        }

        // Full refund per player (no treasury cut for cancelled queue)
        uint256 refundPerPlayer = pool / playerCount;

        // Credit refunds to each player (pull pattern - safe against griefing)
        for (uint256 i = 0; i < playerCount; i++) {
            pendingRefunds[players[i]] += refundPerPlayer;
            emit RefundCredited(matchId, players[i], refundPerPlayer);
        }

        emit MatchRefunded(matchId, playerCount, refundPerPlayer);
    }

    /**
     * @notice Withdraw pending refunds
     * @dev Pull pattern - players call this to withdraw their refunds
     */
    function withdrawRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        if (amount == 0) revert NoPendingRefund();

        pendingRefunds[msg.sender] = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Refund withdrawal failed");

        emit RefundWithdrawn(msg.sender, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/INeuronToken.sol";
import "./interfaces/IReputationRegistry.sol";
import "./interfaces/IIdentityRegistry.sol";

/**
 * @title BountyArena
 * @notice On-chain AI Agent Bounty Arena on Monad
 * @dev Bounty lifecycle: Open -> AnswerPeriod -> Settled/Expired/Refunded
 *
 * Economic model:
 * - Bounty creation: MON deposit as reward pool
 * - Answers: $NEURON burn per attempt (doubles each attempt per bounty)
 * - Settlement: configurable split (default 85% winner, 10% treasury, 5% burn allocation)
 * - Rating gate: optional minimum ERC-8004 reputation to join bounty
 */
contract BountyArena is Ownable, ReentrancyGuard, Pausable {
    // ============ Type Definitions ============

    /**
     * @notice Bounty lifecycle phases
     * @dev Open: Accepting agents, waiting for joinDeadline
     *      AnswerPeriod: Active answering, NEURON burned per attempt
     *      Settled: Winner determined, prizes distributed
     *      Expired: No agents joined by deadline
     *      Refunded: Answer timeout with no winner, agents refunded NEURON cost? No — MON refund
     */
    enum BountyPhase {
        Open,
        AnswerPeriod,
        Settled,
        Expired,
        Refunded
    }

    /**
     * @notice Bounty configuration (set at creation, immutable during bounty)
     */
    struct BountyConfig {
        address creator;         // Address that created and funded the bounty
        uint256 reward;          // Total MON reward pool
        uint256 baseAnswerFee;   // Base NEURON burned per answer (doubles each attempt)
        int128 minRating;        // Minimum ERC-8004 reputation score (0 = open bounty)
        uint64 joinDeadline;     // When open phase times out
        uint64 answerDuration;   // Duration of answer period in seconds
        uint8 maxAgents;         // Maximum agents allowed
        string question;         // Bounty question text
        string category;         // Question category
        uint8 difficulty;        // Difficulty level 1-5
    }

    /**
     * @notice Bounty dynamic state (changes during bounty lifecycle)
     */
    struct BountyState {
        uint64 answerDeadline;   // When answer period ends (0 until answer period starts)
        BountyPhase phase;
        address winner;
        uint256 agentCount;      // Number of agents that joined
    }

    // ============ Storage ============

    /// @notice The $NEURON token contract for answer fee burns
    INeuronToken public immutable neuronToken;

    /// @notice The ERC-8004 reputation registry
    IReputationRegistry public immutable reputationRegistry;

    /// @notice The ERC-8004 identity registry
    IIdentityRegistry public immutable identityRegistry;

    /// @notice Treasury address for protocol fees
    address public treasury;

    /// @notice Prize split in basis points (10000 = 100%)
    uint16 public winnerBps;
    uint16 public treasuryBps;
    uint16 public burnBps;

    /// @notice Minimum bounty reward in MON
    uint256 public minBountyReward;

    /// @notice Base answer fee for bounties (NEURON)
    uint256 public defaultBaseAnswerFee;

    /// @notice Authorized operators (can manage bounties)
    mapping(address => bool) public operators;

    /// @notice Counter for generating unique bounty IDs
    uint256 public nextBountyId;

    /// @notice Bounty configuration by ID
    mapping(uint256 => BountyConfig) internal _bountyConfigs;

    /// @notice Bounty state by ID
    mapping(uint256 => BountyState) public bountyStates;

    /// @notice Agents in each bounty
    /// @dev bountyId => array of agent addresses
    mapping(uint256 => address[]) public bountyAgents;

    /// @notice Track if an address is in a specific bounty
    /// @dev bountyId => agent => isInBounty
    mapping(uint256 => mapping(address => bool)) public isAgentInBounty;

    /// @notice Number of answer attempts per agent per bounty
    /// @dev bountyId => agent => attemptCount (used for doubling fee calculation)
    mapping(uint256 => mapping(address => uint256)) public answerAttempts;

    /// @notice Total NEURON burned per bounty (for stats/events)
    mapping(uint256 => uint256) public bountyBurnTotal;

    /// @notice Accumulated NEURON buyback allocation
    /// @dev winner => accumulated MON for NEURON buyback
    mapping(address => uint256) public burnAllocation;

    /// @notice Pending refunds for pull-pattern withdrawal
    /// @dev player => pending MON refund amount
    mapping(address => uint256) public pendingRefunds;

    // ============ Events ============

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed creator,
        uint256 reward,
        string question,
        string category,
        uint8 difficulty,
        int128 minRating,
        uint64 joinDeadline,
        uint8 maxAgents
    );

    event AgentJoinedBounty(
        uint256 indexed bountyId,
        address indexed agent,
        uint256 agentId,
        uint256 agentCount
    );

    event BountyAnswerPeriodStarted(
        uint256 indexed bountyId,
        uint256 startTime,
        uint256 deadline
    );

    event BountyAnswerSubmitted(
        uint256 indexed bountyId,
        address indexed agent,
        string answer,
        uint256 attemptNumber,
        uint256 neuronBurned
    );

    event BountySettled(
        uint256 indexed bountyId,
        address indexed winner,
        uint256 winnerPrize,
        uint256 treasuryFee,
        uint256 burnAllocationAmount
    );

    event BountyExpired(uint256 indexed bountyId);

    event BountyRefunded(
        uint256 indexed bountyId,
        uint256 agentCount,
        uint256 refundPerAgent
    );

    event BountyNeuronBurned(
        uint256 indexed bountyId,
        address indexed agent,
        uint256 amount
    );

    event RefundCredited(
        uint256 indexed bountyId,
        address indexed agent,
        uint256 amount
    );

    event RefundWithdrawn(
        address indexed agent,
        uint256 amount
    );

    event BurnAllocationClaimed(
        address indexed operator,
        address indexed winner,
        uint256 amount
    );

    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SplitUpdated(uint16 winnerBps, uint16 treasuryBps, uint16 burnBps);
    event MinBountyRewardUpdated(uint256 oldMinReward, uint256 newMinReward);

    // ============ Errors ============

    error NotOperator();
    error BountyNotFound(uint256 bountyId);
    error InvalidPhase(BountyPhase expected, BountyPhase actual);
    error AlreadyInBounty(uint256 bountyId, address agent);
    error NotInBounty(uint256 bountyId, address agent);
    error BountyFull(uint256 bountyId);
    error JoinDeadlinePassed(uint256 bountyId);
    error JoinDeadlineNotPassed(uint256 bountyId);
    error AnswerDeadlinePassed(uint256 bountyId);
    error AnswerDeadlineNotPassed(uint256 bountyId);
    error InsufficientRating(int128 required, int128 actual);
    error InsufficientReward(uint256 minRequired, uint256 provided);
    error CreatorCannotJoin(uint256 bountyId);
    error AgentNotRegistered(address agent);
    error NoAgentsJoined(uint256 bountyId);
    error ZeroAddress();
    error NoBurnAllocation();
    error NoPendingRefund();
    error InvalidParameters();
    error InvalidSplit();

    // ============ Modifiers ============

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert NotOperator();
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        if (bountyId == 0 || bountyId >= nextBountyId) revert BountyNotFound(bountyId);
        _;
    }

    modifier onlyPhase(uint256 bountyId, BountyPhase expectedPhase) {
        BountyPhase currentPhase = bountyStates[bountyId].phase;
        if (currentPhase != expectedPhase) revert InvalidPhase(expectedPhase, currentPhase);
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Deploy the BountyArena contract
     * @param _neuronToken Address of the $NEURON token contract
     * @param _reputationRegistry Address of the ERC-8004 reputation registry
     * @param _identityRegistry Address of the ERC-8004 identity registry
     * @param _treasury Address to receive protocol fees
     * @param _initialOperator Initial operator address (Agent Chief)
     */
    constructor(
        address _neuronToken,
        address _reputationRegistry,
        address _identityRegistry,
        address _treasury,
        address _initialOperator
    ) Ownable(msg.sender) {
        if (_neuronToken == address(0)) revert ZeroAddress();
        if (_reputationRegistry == address(0)) revert ZeroAddress();
        if (_identityRegistry == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_initialOperator == address(0)) revert ZeroAddress();

        neuronToken = INeuronToken(_neuronToken);
        reputationRegistry = IReputationRegistry(_reputationRegistry);
        identityRegistry = IIdentityRegistry(_identityRegistry);
        treasury = _treasury;
        operators[_initialOperator] = true;
        nextBountyId = 1; // Start from 1, 0 reserved for "no bounty"

        // Default split: 85% winner, 10% treasury, 5% burn allocation
        winnerBps = 8500;
        treasuryBps = 1000;
        burnBps = 500;

        // Default minimum bounty reward: 0.01 MON
        minBountyReward = 0.01 ether;

        // Default base answer fee: 0.1 NEURON
        defaultBaseAnswerFee = 0.1 ether;

        emit OperatorAdded(_initialOperator);
    }

    // ============ Admin Functions ============

    function addOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert ZeroAddress();
        if (operators[_operator]) revert InvalidParameters();
        operators[_operator] = true;
        emit OperatorAdded(_operator);
    }

    function removeOperator(address _operator) external onlyOwner {
        if (!operators[_operator]) revert InvalidParameters();
        operators[_operator] = false;
        emit OperatorRemoved(_operator);
    }

    function isOperator(address _operator) external view returns (bool) {
        return operators[_operator];
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    function setSplit(uint16 _winnerBps, uint16 _treasuryBps, uint16 _burnBps) external onlyOwner {
        if (uint256(_winnerBps) + uint256(_treasuryBps) + uint256(_burnBps) != 10000) revert InvalidSplit();
        winnerBps = _winnerBps;
        treasuryBps = _treasuryBps;
        burnBps = _burnBps;
        emit SplitUpdated(_winnerBps, _treasuryBps, _burnBps);
    }

    function setMinBountyReward(uint256 _minReward) external onlyOwner {
        uint256 oldMinReward = minBountyReward;
        minBountyReward = _minReward;
        emit MinBountyRewardUpdated(oldMinReward, _minReward);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============

    function getBountyConfig(uint256 bountyId) external view returns (BountyConfig memory) {
        return _bountyConfigs[bountyId];
    }

    function getBountyState(uint256 bountyId) external view returns (BountyState memory) {
        return bountyStates[bountyId];
    }

    function getBountyAgents(uint256 bountyId) external view returns (address[] memory) {
        return bountyAgents[bountyId];
    }

    function getAgentCount(uint256 bountyId) external view returns (uint256) {
        return bountyAgents[bountyId].length;
    }

    function getCurrentAnswerFee(uint256 bountyId, address agent) public view returns (uint256) {
        uint256 attempts = answerAttempts[bountyId][agent];
        return _bountyConfigs[bountyId].baseAnswerFee * (2 ** attempts);
    }

    // ============ Bounty Creation ============

    /**
     * @notice Create a new bounty with MON reward
     * @param question The bounty question text
     * @param minRating Minimum ERC-8004 reputation score (0 = open bounty)
     * @param category Question category
     * @param difficulty Difficulty level 1-5
     * @param joinDuration Duration of open phase in seconds
     * @param answerDuration Duration of answer period in seconds
     * @param maxAgents Maximum agents allowed
     * @return bountyId The newly created bounty ID
     */
    function createBounty(
        string calldata question,
        int128 minRating,
        string calldata category,
        uint8 difficulty,
        uint64 joinDuration,
        uint64 answerDuration,
        uint8 maxAgents
    ) external payable whenNotPaused nonReentrant returns (uint256 bountyId) {
        if (msg.value < minBountyReward) revert InsufficientReward(minBountyReward, msg.value);
        if (bytes(question).length == 0) revert InvalidParameters();
        if (difficulty == 0 || difficulty > 5) revert InvalidParameters();
        if (joinDuration == 0) revert InvalidParameters();
        if (answerDuration == 0) revert InvalidParameters();
        if (maxAgents == 0) revert InvalidParameters();

        bountyId = nextBountyId++;

        _bountyConfigs[bountyId] = BountyConfig({
            creator: msg.sender,
            reward: msg.value,
            baseAnswerFee: defaultBaseAnswerFee,
            minRating: minRating,
            joinDeadline: uint64(block.timestamp) + joinDuration,
            answerDuration: answerDuration,
            maxAgents: maxAgents,
            question: question,
            category: category,
            difficulty: difficulty
        });

        bountyStates[bountyId] = BountyState({
            answerDeadline: 0,
            phase: BountyPhase.Open,
            winner: address(0),
            agentCount: 0
        });

        emit BountyCreated(
            bountyId,
            msg.sender,
            msg.value,
            question,
            category,
            difficulty,
            minRating,
            _bountyConfigs[bountyId].joinDeadline,
            maxAgents
        );
    }

    // ============ Join Functions ============

    /**
     * @notice Join a bounty (checks ERC-8004 rating gate)
     * @param bountyId The bounty to join
     * @param agentId The ERC-8004 agent ID of the caller
     */
    function joinBounty(uint256 bountyId, uint256 agentId)
        external
        whenNotPaused
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Open)
        nonReentrant
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        // Check join deadline
        if (block.timestamp > config.joinDeadline) revert JoinDeadlinePassed(bountyId);

        // Creator cannot join own bounty
        if (msg.sender == config.creator) revert CreatorCannotJoin(bountyId);

        // Check if already in bounty
        if (isAgentInBounty[bountyId][msg.sender]) revert AlreadyInBounty(bountyId, msg.sender);

        // Check if bounty is full
        if (bountyAgents[bountyId].length >= config.maxAgents) revert BountyFull(bountyId);

        // Verify agent identity: ownerOf reverts or returns zero for unregistered IDs
        if (identityRegistry.ownerOf(agentId) != msg.sender) revert AgentNotRegistered(msg.sender);

        // Check rating gate (if minRating > 0)
        if (config.minRating > 0) {
            address[] memory emptyClients = new address[](0);
            (, int128 summaryValue,) =
                reputationRegistry.getSummary(agentId, emptyClients, "", "");
            if (summaryValue < config.minRating) {
                revert InsufficientRating(config.minRating, summaryValue);
            }
        }

        // Add agent to bounty
        bountyAgents[bountyId].push(msg.sender);
        isAgentInBounty[bountyId][msg.sender] = true;
        state.agentCount++;

        emit AgentJoinedBounty(bountyId, msg.sender, agentId, state.agentCount);
    }

    // ============ Answer Period Functions ============

    /**
     * @notice Start the answer period for a bounty
     * @param bountyId The bounty ID
     * @dev Operator-only. At least one agent must have joined.
     */
    function startBountyAnswerPeriod(uint256 bountyId)
        external
        onlyOperator
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Open)
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        if (state.agentCount == 0) revert NoAgentsJoined(bountyId);

        uint64 startTime = uint64(block.timestamp);
        state.answerDeadline = startTime + config.answerDuration;
        state.phase = BountyPhase.AnswerPeriod;

        emit BountyAnswerPeriodStarted(bountyId, startTime, state.answerDeadline);
    }

    // ============ Answer Functions ============

    /**
     * @notice Submit a bounty answer attempt (burns NEURON, fee doubles each attempt)
     * @param bountyId The bounty ID
     * @param answer The submitted answer
     */
    function submitBountyAnswer(uint256 bountyId, string calldata answer)
        external
        whenNotPaused
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.AnswerPeriod)
        nonReentrant
    {
        BountyState storage state = bountyStates[bountyId];

        // Check answer deadline
        if (block.timestamp > state.answerDeadline) revert AnswerDeadlinePassed(bountyId);

        // Check if agent is in bounty
        if (!isAgentInBounty[bountyId][msg.sender]) revert NotInBounty(bountyId, msg.sender);

        // Calculate burn amount (doubles each attempt)
        uint256 attempts = answerAttempts[bountyId][msg.sender];
        uint256 burnAmount = _bountyConfigs[bountyId].baseAnswerFee * (2 ** attempts);

        // Burn NEURON from sender (requires approval)
        neuronToken.burnFrom(msg.sender, burnAmount);

        // Update tracking
        answerAttempts[bountyId][msg.sender] = attempts + 1;
        bountyBurnTotal[bountyId] += burnAmount;

        emit BountyNeuronBurned(bountyId, msg.sender, burnAmount);
        emit BountyAnswerSubmitted(bountyId, msg.sender, answer, attempts + 1, burnAmount);
    }

    // ============ Settlement Functions ============

    /**
     * @notice Settle bounty with a winner
     * @param bountyId The bounty ID
     * @param winner The winning agent address
     * @dev Distribution: 85% winner / 10% treasury / 5% burn allocation (configurable)
     */
    function settleBounty(uint256 bountyId, address winner)
        external
        onlyOperator
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.AnswerPeriod)
        nonReentrant
    {
        if (winner == address(0)) revert ZeroAddress();
        if (!isAgentInBounty[bountyId][winner]) revert NotInBounty(bountyId, winner);

        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];
        uint256 pool = config.reward;

        // Calculate distribution
        uint256 winnerPrize = (pool * winnerBps) / 10000;
        uint256 treasuryFee = (pool * treasuryBps) / 10000;
        uint256 burnAllocationAmount = pool - winnerPrize - treasuryFee;

        // Update state
        state.winner = winner;
        state.phase = BountyPhase.Settled;
        burnAllocation[winner] += burnAllocationAmount;

        // Transfer winner prize
        (bool winnerSuccess,) = payable(winner).call{value: winnerPrize}("");
        require(winnerSuccess, "Winner transfer failed");

        // Transfer treasury fee
        (bool treasurySuccess,) = payable(treasury).call{value: treasuryFee}("");
        require(treasurySuccess, "Treasury transfer failed");

        emit BountySettled(bountyId, winner, winnerPrize, treasuryFee, burnAllocationAmount);
    }

    // ============ Expiry Functions ============

    /**
     * @notice Expire a bounty that has no agents joined after deadline
     * @param bountyId The bounty ID
     * @dev Refunds the full reward to the creator via pull pattern
     */
    function expireBounty(uint256 bountyId)
        external
        onlyOperator
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Open)
        nonReentrant
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        // Join deadline must have passed
        if (block.timestamp <= config.joinDeadline) revert JoinDeadlineNotPassed(bountyId);

        // No agents joined
        if (state.agentCount > 0) revert InvalidParameters();

        // Update state
        state.phase = BountyPhase.Expired;

        // Refund creator via pull pattern
        pendingRefunds[config.creator] += config.reward;

        emit RefundCredited(bountyId, config.creator, config.reward);
        emit BountyExpired(bountyId);
    }

    // ============ Refund Functions ============

    /**
     * @notice Refund bounty after answer period timeout with no winner
     * @param bountyId The bounty ID
     * @dev Creator gets reward back (minus treasury fee) via pull pattern
     */
    function refundBounty(uint256 bountyId)
        external
        onlyOperator
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.AnswerPeriod)
        nonReentrant
    {
        BountyState storage state = bountyStates[bountyId];
        BountyConfig storage config = _bountyConfigs[bountyId];

        // Check that answer deadline has passed
        if (block.timestamp <= state.answerDeadline) revert AnswerDeadlineNotPassed(bountyId);

        uint256 pool = config.reward;

        // Calculate distribution using configurable treasury rate
        uint256 treasuryFee = (pool * treasuryBps) / 10000;
        uint256 refundPool = pool - treasuryFee;

        // Update state
        state.phase = BountyPhase.Refunded;

        // Transfer treasury fee
        if (treasuryFee > 0) {
            (bool treasurySuccess,) = payable(treasury).call{value: treasuryFee}("");
            require(treasurySuccess, "Treasury transfer failed");
        }

        // Refund creator via pull pattern
        pendingRefunds[config.creator] += refundPool;

        emit RefundCredited(bountyId, config.creator, refundPool);
        emit BountyRefunded(bountyId, state.agentCount, refundPool);
    }

    /**
     * @notice Withdraw pending refunds
     * @dev Pull pattern - users call this to withdraw their refunds
     */
    function withdrawRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        if (amount == 0) revert NoPendingRefund();

        pendingRefunds[msg.sender] = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Refund withdrawal failed");

        emit RefundWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim burn allocation on behalf of a winner for NEURON buyback swap
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
}

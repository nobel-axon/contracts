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
 * @notice Permissionless NEURON-based bounty arena on Monad
 * @dev Bounty lifecycle: Pending -> Active -> Settled (poster picks winner)
 *      or Active -> Expired (deadline passes, proportional claim / refund)
 *      or Pending -> Settled (rejected by operator, creator refunded)
 *
 * Economic model:
 * - Bounty creation: poster deposits NEURON via transferFrom (starts Pending)
 * - Operator screening: operator approves (Pending -> Active) or rejects (refund)
 * - Answers: $NEURON burn per attempt (doubles each attempt per bounty)
 * - Settlement: poster picks winner before deadline, winner claims full reward
 * - Fallback: proportional split by reputation if deadline passes, or refund if no answers
 */
contract BountyArena is Ownable, ReentrancyGuard, Pausable {
    // ============ Constants ============

    uint256 public constant MAX_ANSWER_ATTEMPTS = 20;
    uint256 public constant MAX_ANSWER_LENGTH = 5000;

    // ============ Operator Management ============

    mapping(address => bool) public operators;

    modifier onlyOperator() {
        require(operators[msg.sender] || msg.sender == owner(), "not operator");
        _;
    }

    // ============ Type Definitions ============

    enum BountyPhase {
        Pending,
        Active,
        Settled
    }

    struct BountyConfig {
        address creator;
        uint256 reward;          // NEURON deposited
        uint256 baseAnswerFee;   // NEURON burn per answer (caller-provided at creation)
        int128 minRating;        // ERC-8004 reputation gate (0 = open)
        uint64 deadline;         // Single deadline for join + answer + pickWinner
        uint8 maxAgents;
        string question;
        string category;
        uint8 difficulty;        // 1-5
    }

    struct BountyState {
        BountyPhase phase;
        address winner;
        uint256 agentCount;
        uint256 answeringAgentCount;
        int128 totalAnsweringReputation;  // sum of snapshotted reps of answering agents
        bool rewardClaimed;               // true after winner/refund claim
    }

    // ============ Storage ============

    INeuronToken public immutable neuronToken;
    IReputationRegistry public immutable reputationRegistry;
    IIdentityRegistry public immutable identityRegistry;

    uint256 public nextBountyId;

    mapping(uint256 => BountyConfig) internal _bountyConfigs;
    mapping(uint256 => BountyState) public bountyStates;

    mapping(uint256 => address[]) public bountyAgents;
    mapping(uint256 => mapping(address => bool)) public isAgentInBounty;

    mapping(uint256 => mapping(address => uint256)) public answerAttempts;
    mapping(uint256 => uint256) public bountyBurnTotal;

    mapping(uint256 => mapping(address => int128)) public agentReputation;
    mapping(uint256 => mapping(address => bool)) public hasAnswered;
    mapping(uint256 => mapping(address => bool)) public claimed;

    // ============ Events ============

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed creator,
        uint256 reward,
        uint256 baseAnswerFee,
        string question,
        string category,
        uint8 difficulty,
        int128 minRating,
        uint64 deadline,
        uint8 maxAgents
    );

    event AgentJoinedBounty(
        uint256 indexed bountyId,
        address indexed agent,
        uint256 agentId,
        uint256 agentCount,
        int128 snapshotReputation
    );

    event BountyAnswerSubmitted(
        uint256 indexed bountyId,
        address indexed agent,
        string answer,
        uint256 attemptNumber,
        uint256 neuronBurned
    );

    event BountyNeuronBurned(
        uint256 indexed bountyId,
        address indexed agent,
        uint256 amount
    );

    event BountySettled(
        uint256 indexed bountyId,
        address indexed winner,
        uint256 reward
    );

    event WinnerRewardClaimed(
        uint256 indexed bountyId,
        address indexed winner,
        uint256 amount
    );

    event ProportionalClaimed(
        uint256 indexed bountyId,
        address indexed agent,
        uint256 amount
    );

    event RefundClaimed(
        uint256 indexed bountyId,
        address indexed creator,
        uint256 amount
    );

    event BountyApproved(uint256 indexed bountyId);
    event BountyRejected(uint256 indexed bountyId, string reason);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);

    // ============ Errors ============

    error BountyNotFound(uint256 bountyId);
    error InvalidPhase(BountyPhase expected, BountyPhase actual);
    error AlreadyInBounty(uint256 bountyId, address agent);
    error NotInBounty(uint256 bountyId, address agent);
    error BountyFull(uint256 bountyId);
    error InsufficientRating(int128 required, int128 actual);
    error CreatorCannotJoin(uint256 bountyId);
    error AgentNotRegistered(address agent);
    error ZeroAddress();
    error InvalidParameters();
    error DeadlinePassed(uint256 bountyId);
    error DeadlineNotPassed(uint256 bountyId);
    error NotCreator(uint256 bountyId);
    error NotWinner(uint256 bountyId);
    error NotSettled(uint256 bountyId);
    error AgentNotAnswered(uint256 bountyId, address agent);
    error AgentsAnswered(uint256 bountyId);
    error AlreadyClaimed(uint256 bountyId, address agent);
    error NoAgentsAnswered(uint256 bountyId);

    // ============ Modifiers ============

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

    constructor(
        address _neuronToken,
        address _reputationRegistry,
        address _identityRegistry
    ) Ownable(msg.sender) {
        if (_neuronToken == address(0)) revert ZeroAddress();
        if (_reputationRegistry == address(0)) revert ZeroAddress();
        if (_identityRegistry == address(0)) revert ZeroAddress();

        neuronToken = INeuronToken(_neuronToken);
        reputationRegistry = IReputationRegistry(_reputationRegistry);
        identityRegistry = IIdentityRegistry(_identityRegistry);
        nextBountyId = 1;
    }

    // ============ Admin Functions ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function addOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "zero address");
        operators[_operator] = true;
        emit OperatorAdded(_operator);
    }

    function removeOperator(address _operator) external onlyOwner {
        operators[_operator] = false;
        emit OperatorRemoved(_operator);
    }

    // ============ View Functions ============

    function getBountyConfig(uint256 bountyId) external view bountyExists(bountyId) returns (BountyConfig memory) {
        return _bountyConfigs[bountyId];
    }

    function getBountyState(uint256 bountyId) external view bountyExists(bountyId) returns (BountyState memory) {
        return bountyStates[bountyId];
    }

    function getBountyAgents(uint256 bountyId) external view bountyExists(bountyId) returns (address[] memory) {
        return bountyAgents[bountyId];
    }

    function getAgentCount(uint256 bountyId) external view bountyExists(bountyId) returns (uint256) {
        return bountyAgents[bountyId].length;
    }

    function getCurrentAnswerFee(uint256 bountyId, address agent) public view bountyExists(bountyId) returns (uint256) {
        uint256 attempts = answerAttempts[bountyId][agent];
        if (attempts >= MAX_ANSWER_ATTEMPTS) revert InvalidParameters();
        return _bountyConfigs[bountyId].baseAnswerFee * (2 ** attempts);
    }

    function getClaimableAmount(uint256 bountyId, address agent) external view bountyExists(bountyId) returns (uint256) {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        if (state.phase != BountyPhase.Active) return 0;
        if (block.timestamp <= config.deadline) return 0;
        if (!hasAnswered[bountyId][agent]) return 0;
        if (claimed[bountyId][agent]) return 0;
        if (state.answeringAgentCount == 0) return 0;

        if (state.totalAnsweringReputation <= 0) {
            return config.reward / state.answeringAgentCount;
        }

        int128 agentRep = agentReputation[bountyId][agent];
        if (agentRep <= 0) return 0;

        return (config.reward * uint256(uint128(agentRep))) / uint256(uint128(state.totalAnsweringReputation));
    }

    // ============ Bounty Creation ============

    function createBounty(
        string calldata question,
        int128 minRating,
        string calldata category,
        uint8 difficulty,
        uint64 duration,
        uint8 maxAgents,
        uint256 reward,
        uint256 baseAnswerFee
    ) external whenNotPaused nonReentrant returns (uint256 bountyId) {
        if (reward == 0) revert InvalidParameters();
        if (baseAnswerFee == 0) revert InvalidParameters();
        if (bytes(question).length == 0) revert InvalidParameters();
        if (difficulty == 0 || difficulty > 5) revert InvalidParameters();
        if (duration == 0) revert InvalidParameters();
        if (maxAgents == 0) revert InvalidParameters();

        neuronToken.transferFrom(msg.sender, address(this), reward);

        bountyId = nextBountyId++;

        _bountyConfigs[bountyId] = BountyConfig({
            creator: msg.sender,
            reward: reward,
            baseAnswerFee: baseAnswerFee,
            minRating: minRating,
            deadline: uint64(block.timestamp) + duration,
            maxAgents: maxAgents,
            question: question,
            category: category,
            difficulty: difficulty
        });

        bountyStates[bountyId] = BountyState({
            phase: BountyPhase.Pending,
            winner: address(0),
            agentCount: 0,
            answeringAgentCount: 0,
            totalAnsweringReputation: 0,
            rewardClaimed: false
        });

        emit BountyCreated(
            bountyId,
            msg.sender,
            reward,
            baseAnswerFee,
            question,
            category,
            difficulty,
            minRating,
            _bountyConfigs[bountyId].deadline,
            maxAgents
        );
    }

    // ============ Operator Screening ============

    function approveBounty(uint256 bountyId)
        external
        onlyOperator
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Pending)
    {
        bountyStates[bountyId].phase = BountyPhase.Active;
        emit BountyApproved(bountyId);
    }

    function rejectBounty(uint256 bountyId, string calldata reason)
        external
        onlyOperator
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Pending)
        nonReentrant
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        bountyStates[bountyId].phase = BountyPhase.Settled;
        bountyStates[bountyId].rewardClaimed = true;
        neuronToken.transfer(config.creator, config.reward);
        emit BountyRejected(bountyId, reason);
    }

    // ============ Join Functions ============

    function joinBounty(uint256 bountyId, uint256 agentId)
        external
        whenNotPaused
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Active)
        nonReentrant
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        if (block.timestamp > config.deadline) revert DeadlinePassed(bountyId);
        if (msg.sender == config.creator) revert CreatorCannotJoin(bountyId);
        if (isAgentInBounty[bountyId][msg.sender]) revert AlreadyInBounty(bountyId, msg.sender);
        if (bountyAgents[bountyId].length >= config.maxAgents) revert BountyFull(bountyId);
        if (identityRegistry.ownerOf(agentId) != msg.sender) revert AgentNotRegistered(msg.sender);

        // Always snapshot reputation
        address[] memory emptyClients = new address[](0);
        (, int128 summaryValue,) =
            reputationRegistry.getSummary(agentId, emptyClients, "", "");
        agentReputation[bountyId][msg.sender] = summaryValue;

        // Rating gate check if minRating > 0
        if (config.minRating > 0) {
            if (summaryValue < config.minRating) {
                revert InsufficientRating(config.minRating, summaryValue);
            }
        }

        bountyAgents[bountyId].push(msg.sender);
        isAgentInBounty[bountyId][msg.sender] = true;
        state.agentCount++;

        emit AgentJoinedBounty(bountyId, msg.sender, agentId, state.agentCount, summaryValue);
    }

    // ============ Answer Functions ============

    function submitBountyAnswer(uint256 bountyId, string calldata answer)
        external
        whenNotPaused
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Active)
        nonReentrant
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        if (block.timestamp > config.deadline) revert DeadlinePassed(bountyId);
        if (bytes(answer).length == 0 || bytes(answer).length > MAX_ANSWER_LENGTH) revert InvalidParameters();
        if (!isAgentInBounty[bountyId][msg.sender]) revert NotInBounty(bountyId, msg.sender);

        uint256 attempts = answerAttempts[bountyId][msg.sender];
        if (attempts >= MAX_ANSWER_ATTEMPTS) revert InvalidParameters();
        uint256 burnAmount = config.baseAnswerFee * (2 ** attempts);

        neuronToken.burnFrom(msg.sender, burnAmount);

        answerAttempts[bountyId][msg.sender] = attempts + 1;
        bountyBurnTotal[bountyId] += burnAmount;

        // Track first answer — only accumulate positive reputation into
        // totalAnsweringReputation so proportional shares always sum to ≤ reward.
        if (!hasAnswered[bountyId][msg.sender]) {
            hasAnswered[bountyId][msg.sender] = true;
            state.answeringAgentCount++;
            int128 rep = agentReputation[bountyId][msg.sender];
            if (rep > 0) {
                state.totalAnsweringReputation += rep;
            }
        }

        emit BountyNeuronBurned(bountyId, msg.sender, burnAmount);
        emit BountyAnswerSubmitted(bountyId, msg.sender, answer, attempts + 1, burnAmount);
    }

    // ============ Settlement Functions ============

    function pickWinner(uint256 bountyId, address winner)
        external
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Active)
        nonReentrant
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        if (msg.sender != config.creator) revert NotCreator(bountyId);
        if (block.timestamp > config.deadline) revert DeadlinePassed(bountyId);
        if (!hasAnswered[bountyId][winner]) revert AgentNotAnswered(bountyId, winner);

        state.winner = winner;
        state.phase = BountyPhase.Settled;

        emit BountySettled(bountyId, winner, config.reward);
    }

    function claimWinnerReward(uint256 bountyId)
        external
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Settled)
        nonReentrant
    {
        BountyState storage state = bountyStates[bountyId];
        BountyConfig storage config = _bountyConfigs[bountyId];

        if (msg.sender != state.winner) revert NotWinner(bountyId);
        if (state.rewardClaimed) revert AlreadyClaimed(bountyId, msg.sender);

        state.rewardClaimed = true;
        neuronToken.transfer(msg.sender, config.reward);

        emit WinnerRewardClaimed(bountyId, msg.sender, config.reward);
    }

    function claimProportional(uint256 bountyId)
        external
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Active)
        nonReentrant
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        if (block.timestamp <= config.deadline) revert DeadlineNotPassed(bountyId);
        if (!hasAnswered[bountyId][msg.sender]) revert AgentNotAnswered(bountyId, msg.sender);
        if (claimed[bountyId][msg.sender]) revert AlreadyClaimed(bountyId, msg.sender);
        if (state.answeringAgentCount == 0) revert NoAgentsAnswered(bountyId);

        uint256 share;
        if (state.totalAnsweringReputation <= 0) {
            share = config.reward / state.answeringAgentCount;
        } else {
            int128 agentRep = agentReputation[bountyId][msg.sender];
            if (agentRep <= 0) {
                share = 0;
            } else {
                share = (config.reward * uint256(uint128(agentRep))) / uint256(uint128(state.totalAnsweringReputation));
            }
        }

        claimed[bountyId][msg.sender] = true;

        if (share > 0) {
            neuronToken.transfer(msg.sender, share);
        }

        emit ProportionalClaimed(bountyId, msg.sender, share);
    }

    function claimRefund(uint256 bountyId)
        external
        bountyExists(bountyId)
        onlyPhase(bountyId, BountyPhase.Active)
        nonReentrant
    {
        BountyConfig storage config = _bountyConfigs[bountyId];
        BountyState storage state = bountyStates[bountyId];

        if (msg.sender != config.creator) revert NotCreator(bountyId);
        if (block.timestamp <= config.deadline) revert DeadlineNotPassed(bountyId);
        if (state.answeringAgentCount != 0) revert AgentsAnswered(bountyId);
        if (state.rewardClaimed) revert AlreadyClaimed(bountyId, msg.sender);

        state.rewardClaimed = true;
        neuronToken.transfer(msg.sender, config.reward);

        emit RefundClaimed(bountyId, msg.sender, config.reward);
    }
}

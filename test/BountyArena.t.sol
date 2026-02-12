// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BountyArena.sol";
import "./mocks/MockNeuronToken.sol";
import "./mocks/MockIdentityRegistry.sol";
import "./mocks/MockReputationRegistry.sol";

/**
 * @title BountyArena Test Suite
 * @notice Comprehensive tests for the BountyArena contract
 */
contract BountyArenaTest is Test {
    BountyArena public arena;
    MockNeuronToken public neuron;
    MockIdentityRegistry public identity;
    MockReputationRegistry public reputation;

    address public owner;
    address public operator;
    address public treasury;
    address public creator;
    address public agent1;
    address public agent2;
    address public agent3;
    address public agent4;

    uint256 public agent1Id;
    uint256 public agent2Id;
    uint256 public agent3Id;
    uint256 public agent4Id;

    uint256 public constant BOUNTY_REWARD = 5 ether;
    uint256 public constant BASE_ANSWER_FEE = 0.1 ether;
    uint64 public constant JOIN_DURATION = 120; // 2 minutes
    uint64 public constant ANSWER_DURATION = 180; // 3 minutes
    uint8 public constant MAX_AGENTS = 8;
    int128 public constant NO_RATING_GATE = 0;

    string public constant DEFAULT_QUESTION = "What is the best consensus algorithm for high throughput?";
    string public constant DEFAULT_CATEGORY = "crypto";
    uint8 public constant DEFAULT_DIFFICULTY = 3;

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

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        agent1 = makeAddr("agent1");
        agent2 = makeAddr("agent2");
        agent3 = makeAddr("agent3");
        agent4 = makeAddr("agent4");

        // Deploy mocks
        neuron = new MockNeuronToken();
        identity = new MockIdentityRegistry();
        reputation = new MockReputationRegistry();

        // Deploy arena
        arena = new BountyArena(
            address(neuron),
            address(reputation),
            address(identity),
            treasury,
            operator
        );

        // Fund accounts with MON
        vm.deal(creator, 100 ether);
        vm.deal(agent1, 100 ether);
        vm.deal(agent2, 100 ether);
        vm.deal(agent3, 100 ether);
        vm.deal(agent4, 100 ether);

        // Fund agents with NEURON and approve arena
        neuron.mint(agent1, 100 ether);
        neuron.mint(agent2, 100 ether);
        neuron.mint(agent3, 100 ether);
        neuron.mint(agent4, 100 ether);

        vm.prank(agent1);
        neuron.approve(address(arena), type(uint256).max);
        vm.prank(agent2);
        neuron.approve(address(arena), type(uint256).max);
        vm.prank(agent3);
        neuron.approve(address(arena), type(uint256).max);
        vm.prank(agent4);
        neuron.approve(address(arena), type(uint256).max);

        // Register agents in identity registry (agents register themselves)
        vm.prank(agent1);
        agent1Id = identity.register("");
        vm.prank(agent2);
        agent2Id = identity.register("");
        vm.prank(agent3);
        agent3Id = identity.register("");
        vm.prank(agent4);
        agent4Id = identity.register("");

        // Set default good reputation for all agents
        // setSummary(agentId, count, summaryValue, summaryValueDecimals)
        reputation.setSummary(agent1Id, 10, 100, 0);
        reputation.setSummary(agent2Id, 8, 80, 0);
        reputation.setSummary(agent3Id, 6, 60, 0);
        reputation.setSummary(agent4Id, 4, 40, 0);
    }

    // ============ Helper Functions ============

    function _createDefaultBounty() internal returns (uint256 bountyId) {
        vm.prank(creator);
        bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION,
            NO_RATING_GATE,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            JOIN_DURATION,
            ANSWER_DURATION,
            MAX_AGENTS
        );
    }

    function _createRatedBounty(int128 minRating) internal returns (uint256 bountyId) {
        vm.prank(creator);
        bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION,
            minRating,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            JOIN_DURATION,
            ANSWER_DURATION,
            MAX_AGENTS
        );
    }

    function _joinBounty(address agent, uint256 agentId, uint256 bountyId) internal {
        vm.prank(agent);
        arena.joinBounty(bountyId, agentId);
    }

    function _setupBountyToAnswerPeriod(uint256 bountyId) internal {
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);

        vm.prank(operator);
        arena.startBountyAnswerPeriod(bountyId);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsDefaults() public view {
        assertEq(address(arena.neuronToken()), address(neuron));
        assertEq(address(arena.reputationRegistry()), address(reputation));
        assertEq(address(arena.identityRegistry()), address(identity));
        assertEq(arena.treasury(), treasury);
        assertTrue(arena.isOperator(operator));
        assertEq(arena.nextBountyId(), 1);
        assertEq(arena.winnerBps(), 8500);
        assertEq(arena.treasuryBps(), 1000);
        assertEq(arena.burnBps(), 500);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(BountyArena.ZeroAddress.selector);
        new BountyArena(address(0), address(reputation), address(identity), treasury, operator);

        vm.expectRevert(BountyArena.ZeroAddress.selector);
        new BountyArena(address(neuron), address(0), address(identity), treasury, operator);

        vm.expectRevert(BountyArena.ZeroAddress.selector);
        new BountyArena(address(neuron), address(reputation), address(0), treasury, operator);

        vm.expectRevert(BountyArena.ZeroAddress.selector);
        new BountyArena(address(neuron), address(reputation), address(identity), address(0), operator);

        vm.expectRevert(BountyArena.ZeroAddress.selector);
        new BountyArena(address(neuron), address(reputation), address(identity), treasury, address(0));
    }

    // ============ Bounty Creation Tests ============

    function test_createBounty_success() public {
        uint256 creatorBalanceBefore = creator.balance;

        vm.prank(creator);
        vm.expectEmit(true, true, false, true);
        emit BountyCreated(
            1,
            creator,
            BOUNTY_REWARD,
            DEFAULT_QUESTION,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            NO_RATING_GATE,
            uint64(block.timestamp) + JOIN_DURATION,
            MAX_AGENTS
        );
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION,
            NO_RATING_GATE,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            JOIN_DURATION,
            ANSWER_DURATION,
            MAX_AGENTS
        );

        assertEq(bountyId, 1);
        assertEq(creator.balance, creatorBalanceBefore - BOUNTY_REWARD);

        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);
        assertEq(config.creator, creator);
        assertEq(config.reward, BOUNTY_REWARD);
        assertEq(config.minRating, NO_RATING_GATE);
        assertEq(config.maxAgents, MAX_AGENTS);
        assertEq(config.difficulty, DEFAULT_DIFFICULTY);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Open));
        assertEq(state.agentCount, 0);
    }

    function test_createBounty_incrementsId() public {
        vm.startPrank(creator);
        uint256 id1 = arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
        uint256 id2 = arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_createBounty_revertsIfInsufficientReward() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InsufficientReward.selector, arena.minBountyReward(), 0.001 ether
        ));
        arena.createBounty{value: 0.001 ether}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
    }

    function test_createBounty_revertsIfEmptyQuestion() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty{value: BOUNTY_REWARD}(
            "", NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
    }

    function test_createBounty_revertsIfInvalidDifficulty() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, 0,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );

        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, 6,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
    }

    function test_createBounty_revertsIfZeroDurations() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            0, ANSWER_DURATION, MAX_AGENTS
        );

        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, 0, MAX_AGENTS
        );
    }

    function test_createBounty_revertsIfZeroMaxAgents() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, 0
        );
    }

    function test_createBounty_withRatingGate() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, int128(50), DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );

        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);
        assertEq(config.minRating, int128(50));
    }

    // ============ Join Bounty Tests ============

    function test_joinBounty_success() public {
        uint256 bountyId = _createDefaultBounty();

        vm.prank(agent1);
        vm.expectEmit(true, true, false, true);
        emit AgentJoinedBounty(bountyId, agent1, agent1Id, 1);
        arena.joinBounty(bountyId, agent1Id);

        assertTrue(arena.isAgentInBounty(bountyId, agent1));
        assertEq(arena.getAgentCount(bountyId), 1);
    }

    function test_joinBounty_multipleAgents() public {
        uint256 bountyId = _createDefaultBounty();

        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
        _joinBounty(agent3, agent3Id, bountyId);

        assertEq(arena.getAgentCount(bountyId), 3);
        assertTrue(arena.isAgentInBounty(bountyId, agent1));
        assertTrue(arena.isAgentInBounty(bountyId, agent2));
        assertTrue(arena.isAgentInBounty(bountyId, agent3));
    }

    function test_joinBounty_revertsIfCreator() public {
        // Register creator as an agent too
        vm.prank(creator);
        uint256 creatorAgentId = identity.register("");
        reputation.setSummary(creatorAgentId, 10, 100, 0);

        uint256 bountyId = _createDefaultBounty();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.CreatorCannotJoin.selector, bountyId));
        arena.joinBounty(bountyId, creatorAgentId);
    }

    function test_joinBounty_revertsIfAlreadyJoined() public {
        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AlreadyInBounty.selector, bountyId, agent1));
        arena.joinBounty(bountyId, agent1Id);
    }

    function test_joinBounty_revertsIfFull() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, 2 // maxAgents = 2
        );

        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);

        vm.prank(agent3);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyFull.selector, bountyId));
        arena.joinBounty(bountyId, agent3Id);
    }

    function test_joinBounty_revertsAfterDeadline() public {
        uint256 bountyId = _createDefaultBounty();

        vm.warp(block.timestamp + JOIN_DURATION + 1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.JoinDeadlinePassed.selector, bountyId));
        arena.joinBounty(bountyId, agent1Id);
    }

    function test_joinBounty_revertsIfNotRegistered() public {
        uint256 bountyId = _createDefaultBounty();
        address unregistered = makeAddr("unregistered");

        vm.prank(unregistered);
        // ownerOf(999) returns address(0), which != unregistered
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AgentNotRegistered.selector, unregistered));
        arena.joinBounty(bountyId, 999);
    }

    function test_joinBounty_revertsIfWrongAgentId() public {
        uint256 bountyId = _createDefaultBounty();

        // agent1 tries to use agent2's ID
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AgentNotRegistered.selector, agent1));
        arena.joinBounty(bountyId, agent2Id);
    }

    function test_joinBounty_ratingGate_passes() public {
        // Create bounty with minRating = 5
        uint256 bountyId = _createRatedBounty(int128(5));

        // agent1 has summaryValue=100, should pass
        _joinBounty(agent1, agent1Id, bountyId);
        assertTrue(arena.isAgentInBounty(bountyId, agent1));
    }

    function test_joinBounty_ratingGate_fails() public {
        // Create bounty with minRating = 50
        uint256 bountyId = _createRatedBounty(int128(50));

        // Set agent1 low reputation: count=2, summaryValue=2
        reputation.setSummary(agent1Id, 2, 2, 0);

        // agent1 has summaryValue=2, should fail
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.InsufficientRating.selector, int128(50), int128(2)));
        arena.joinBounty(bountyId, agent1Id);
    }

    function test_joinBounty_ratingGate_zeroMeansOpen() public {
        uint256 bountyId = _createDefaultBounty(); // NO_RATING_GATE = 0

        // Set agent with zero reputation
        reputation.setSummary(agent1Id, 0, 0, 0);

        // Should still be able to join open bounty
        _joinBounty(agent1, agent1Id, bountyId);
        assertTrue(arena.isAgentInBounty(bountyId, agent1));
    }

    // ============ Answer Period Tests ============

    function test_startBountyAnswerPeriod_success() public {
        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);

        vm.prank(operator);
        vm.expectEmit(true, false, false, true);
        emit BountyAnswerPeriodStarted(bountyId, block.timestamp, block.timestamp + ANSWER_DURATION);
        arena.startBountyAnswerPeriod(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.AnswerPeriod));
        assertTrue(state.answerDeadline > block.timestamp);
    }

    function test_startBountyAnswerPeriod_revertsIfNoAgents() public {
        uint256 bountyId = _createDefaultBounty();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.NoAgentsJoined.selector, bountyId));
        arena.startBountyAnswerPeriod(bountyId);
    }

    function test_startBountyAnswerPeriod_revertsIfNotOperator() public {
        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);

        vm.prank(agent1);
        vm.expectRevert(BountyArena.NotOperator.selector);
        arena.startBountyAnswerPeriod(bountyId);
    }

    function test_startBountyAnswerPeriod_revertsIfWrongPhase() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        // Already in AnswerPeriod
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.Open,
            BountyArena.BountyPhase.AnswerPeriod
        ));
        arena.startBountyAnswerPeriod(bountyId);
    }

    // ============ Submit Answer Tests ============

    function test_submitBountyAnswer_burnsCorrectAmount() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        uint256 neuronBefore = neuron.balanceOf(agent1);

        vm.prank(agent1);
        arena.submitBountyAnswer(bountyId, "my answer");

        assertEq(neuron.balanceOf(agent1), neuronBefore - BASE_ANSWER_FEE);
        assertEq(arena.answerAttempts(bountyId, agent1), 1);
    }

    function test_submitBountyAnswer_feeDoubles() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        uint256 neuronBefore = neuron.balanceOf(agent1);

        // First attempt: BASE_ANSWER_FEE
        vm.prank(agent1);
        arena.submitBountyAnswer(bountyId, "attempt1");
        assertEq(neuron.balanceOf(agent1), neuronBefore - BASE_ANSWER_FEE);

        // Second attempt: 2x
        vm.prank(agent1);
        arena.submitBountyAnswer(bountyId, "attempt2");
        assertEq(neuron.balanceOf(agent1), neuronBefore - BASE_ANSWER_FEE - (BASE_ANSWER_FEE * 2));

        // Third attempt: 4x
        vm.prank(agent1);
        arena.submitBountyAnswer(bountyId, "attempt3");
        assertEq(neuron.balanceOf(agent1), neuronBefore - BASE_ANSWER_FEE - (BASE_ANSWER_FEE * 2) - (BASE_ANSWER_FEE * 4));

        assertEq(arena.answerAttempts(bountyId, agent1), 3);
    }

    function test_submitBountyAnswer_emitsEvents() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.prank(agent1);
        vm.expectEmit(true, true, false, true);
        emit BountyAnswerSubmitted(bountyId, agent1, "test answer", 1, BASE_ANSWER_FEE);
        arena.submitBountyAnswer(bountyId, "test answer");
    }

    function test_submitBountyAnswer_revertsIfNotInBounty() public {
        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);

        vm.prank(operator);
        arena.startBountyAnswerPeriod(bountyId);

        vm.prank(agent3);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.NotInBounty.selector, bountyId, agent3));
        arena.submitBountyAnswer(bountyId, "answer");
    }

    function test_submitBountyAnswer_revertsAfterDeadline() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AnswerDeadlinePassed.selector, bountyId));
        arena.submitBountyAnswer(bountyId, "answer");
    }

    function test_submitBountyAnswer_revertsIfWrongPhase() public {
        uint256 bountyId = _createDefaultBounty();

        // Still in Open phase
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.AnswerPeriod,
            BountyArena.BountyPhase.Open
        ));
        arena.submitBountyAnswer(bountyId, "answer");
    }

    function test_getCurrentAnswerFee_doublesCorrectly() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        assertEq(arena.getCurrentAnswerFee(bountyId, agent1), BASE_ANSWER_FEE);

        vm.prank(agent1);
        arena.submitBountyAnswer(bountyId, "attempt1");
        assertEq(arena.getCurrentAnswerFee(bountyId, agent1), BASE_ANSWER_FEE * 2);

        vm.prank(agent1);
        arena.submitBountyAnswer(bountyId, "attempt2");
        assertEq(arena.getCurrentAnswerFee(bountyId, agent1), BASE_ANSWER_FEE * 4);
    }

    // ============ Settlement Tests ============

    function test_settleBounty_distributesCorrectly() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        uint256 pool = BOUNTY_REWARD;
        uint256 expectedWinnerPrize = (pool * 8500) / 10000;
        uint256 expectedTreasuryFee = (pool * 1000) / 10000;
        uint256 expectedBurnAllocation = pool - expectedWinnerPrize - expectedTreasuryFee;

        uint256 winnerBalanceBefore = agent1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(operator);
        vm.expectEmit(true, true, false, true);
        emit BountySettled(bountyId, agent1, expectedWinnerPrize, expectedTreasuryFee, expectedBurnAllocation);
        arena.settleBounty(bountyId, agent1);

        assertEq(agent1.balance, winnerBalanceBefore + expectedWinnerPrize);
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);
        assertEq(arena.burnAllocation(agent1), expectedBurnAllocation);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(state.winner, agent1);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Settled));
    }

    function test_settleBounty_revertsIfNotOperator() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.prank(agent1);
        vm.expectRevert(BountyArena.NotOperator.selector);
        arena.settleBounty(bountyId, agent1);
    }

    function test_settleBounty_revertsIfNotInBounty() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.NotInBounty.selector, bountyId, agent3));
        arena.settleBounty(bountyId, agent3);
    }

    function test_settleBounty_revertsIfZeroAddress() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.prank(operator);
        vm.expectRevert(BountyArena.ZeroAddress.selector);
        arena.settleBounty(bountyId, address(0));
    }

    function test_settleBounty_revertsIfWrongPhase() public {
        uint256 bountyId = _createDefaultBounty();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.AnswerPeriod,
            BountyArena.BountyPhase.Open
        ));
        arena.settleBounty(bountyId, agent1);
    }

    // ============ Expiry Tests ============

    function test_expireBounty_refundsCreator() public {
        uint256 bountyId = _createDefaultBounty();

        // Fast forward past join deadline
        vm.warp(block.timestamp + JOIN_DURATION + 1);

        vm.prank(operator);
        arena.expireBounty(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Expired));

        // Creator has pending refund
        assertEq(arena.pendingRefunds(creator), BOUNTY_REWARD);

        // Creator withdraws
        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(creator);
        arena.withdrawRefund();
        assertEq(creator.balance, creatorBalanceBefore + BOUNTY_REWARD);
    }

    function test_expireBounty_revertsBeforeDeadline() public {
        uint256 bountyId = _createDefaultBounty();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.JoinDeadlineNotPassed.selector, bountyId));
        arena.expireBounty(bountyId);
    }

    function test_expireBounty_revertsIfAgentsJoined() public {
        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);

        vm.warp(block.timestamp + JOIN_DURATION + 1);

        vm.prank(operator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.expireBounty(bountyId);
    }

    function test_expireBounty_revertsIfNotOperator() public {
        uint256 bountyId = _createDefaultBounty();

        vm.warp(block.timestamp + JOIN_DURATION + 1);

        vm.prank(agent1);
        vm.expectRevert(BountyArena.NotOperator.selector);
        arena.expireBounty(bountyId);
    }

    // ============ Refund Tests ============

    function test_refundBounty_refundsCreatorMinusTreasury() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        uint256 pool = BOUNTY_REWARD;
        uint256 expectedTreasuryFee = (pool * 1000) / 10000;
        uint256 expectedRefund = pool - expectedTreasuryFee;

        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(operator);
        arena.refundBounty(bountyId);

        // Treasury gets paid immediately
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);

        // Creator has pending refund
        assertEq(arena.pendingRefunds(creator), expectedRefund);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Refunded));

        // Creator withdraws
        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(creator);
        arena.withdrawRefund();
        assertEq(creator.balance, creatorBalanceBefore + expectedRefund);
    }

    function test_refundBounty_revertsBeforeDeadline() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AnswerDeadlineNotPassed.selector, bountyId));
        arena.refundBounty(bountyId);
    }

    function test_refundBounty_revertsIfNotOperator() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        vm.prank(agent1);
        vm.expectRevert(BountyArena.NotOperator.selector);
        arena.refundBounty(bountyId);
    }

    function test_withdrawRefund_revertsIfNoPending() public {
        vm.prank(agent1);
        vm.expectRevert(BountyArena.NoPendingRefund.selector);
        arena.withdrawRefund();
    }

    // ============ Burn Allocation Tests ============

    function test_claimBurnAllocationFor_success() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.prank(operator);
        arena.settleBounty(bountyId, agent1);

        uint256 allocation = arena.burnAllocation(agent1);
        assertTrue(allocation > 0);

        uint256 operatorBalanceBefore = operator.balance;

        vm.prank(operator);
        arena.claimBurnAllocationFor(agent1);

        assertEq(operator.balance, operatorBalanceBefore + allocation);
        assertEq(arena.burnAllocation(agent1), 0);
    }

    function test_claimBurnAllocationFor_revertsIfNotOperator() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        vm.prank(operator);
        arena.settleBounty(bountyId, agent1);

        vm.prank(agent2);
        vm.expectRevert(BountyArena.NotOperator.selector);
        arena.claimBurnAllocationFor(agent1);
    }

    function test_claimBurnAllocationFor_revertsIfNone() public {
        vm.prank(operator);
        vm.expectRevert(BountyArena.NoBurnAllocation.selector);
        arena.claimBurnAllocationFor(agent1);
    }

    // ============ Admin Tests ============

    function test_addOperator_success() public {
        address newOperator = makeAddr("newOperator");
        arena.addOperator(newOperator);
        assertTrue(arena.isOperator(newOperator));
    }

    function test_addOperator_revertsIfNotOwner() public {
        vm.prank(agent1);
        vm.expectRevert();
        arena.addOperator(agent1);
    }

    function test_addOperator_revertsIfAlreadyOperator() public {
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.addOperator(operator);
    }

    function test_removeOperator_success() public {
        assertTrue(arena.isOperator(operator));
        arena.removeOperator(operator);
        assertFalse(arena.isOperator(operator));
    }

    function test_removeOperator_revertsIfNotOwner() public {
        vm.prank(agent1);
        vm.expectRevert();
        arena.removeOperator(operator);
    }

    function test_removeOperator_revertsIfNotOperator() public {
        address notOperator = makeAddr("notOperator");
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.removeOperator(notOperator);
    }

    function test_setTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");
        arena.setTreasury(newTreasury);
        assertEq(arena.treasury(), newTreasury);
    }

    function test_setSplit_success() public {
        arena.setSplit(8000, 1000, 1000);
        assertEq(arena.winnerBps(), 8000);
        assertEq(arena.treasuryBps(), 1000);
        assertEq(arena.burnBps(), 1000);
    }

    function test_setSplit_revertsIfNotSumTo10000() public {
        vm.expectRevert(BountyArena.InvalidSplit.selector);
        arena.setSplit(8000, 1000, 500);
    }

    function test_setSplit_affectsSettlement() public {
        arena.setSplit(7000, 2000, 1000);

        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        uint256 pool = BOUNTY_REWARD;
        uint256 expectedWinnerPrize = (pool * 7000) / 10000;
        uint256 expectedTreasuryFee = (pool * 2000) / 10000;

        uint256 winnerBalanceBefore = agent1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(operator);
        arena.settleBounty(bountyId, agent1);

        assertEq(agent1.balance, winnerBalanceBefore + expectedWinnerPrize);
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);
    }

    // ============ Pause Tests ============

    function test_pause_blocksCreateBounty() public {
        arena.pause();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
    }

    function test_pause_blocksJoinBounty() public {
        uint256 bountyId = _createDefaultBounty();

        arena.pause();

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        arena.joinBounty(bountyId, agent1Id);
    }

    function test_pause_blocksSubmitAnswer() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        arena.pause();

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        arena.submitBountyAnswer(bountyId, "answer");
    }

    function test_pause_allowsSettlement() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        arena.pause();

        vm.prank(operator);
        arena.settleBounty(bountyId, agent1);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Settled));
    }

    function test_pause_allowsRefund() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        arena.pause();

        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        vm.prank(operator);
        arena.refundBounty(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Refunded));
    }

    function test_unpause_restoresOperations() public {
        arena.pause();
        arena.unpause();

        _createDefaultBounty();
        assertEq(arena.nextBountyId(), 2);
    }

    // ============ View Function Tests ============

    function test_getBountyAgents() public {
        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);

        address[] memory agents = arena.getBountyAgents(bountyId);
        assertEq(agents.length, 2);
        assertEq(agents[0], agent1);
        assertEq(agents[1], agent2);
    }

    function test_getBountyConfig() public {
        uint256 bountyId = _createDefaultBounty();

        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);
        assertEq(config.creator, creator);
        assertEq(config.reward, BOUNTY_REWARD);
        assertEq(config.maxAgents, MAX_AGENTS);
    }

    // ============ Full Lifecycle Integration Tests ============

    function test_fullLifecycle_happyPath() public {
        // Step 1: Creator creates bounty
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "What is the most efficient sorting algorithm for nearly sorted data?",
            NO_RATING_GATE,
            "algorithms",
            2,
            JOIN_DURATION,
            ANSWER_DURATION,
            MAX_AGENTS
        );

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Open));

        // Step 2: Agents join
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
        _joinBounty(agent3, agent3Id, bountyId);

        assertEq(arena.getAgentCount(bountyId), 3);

        // Step 3: Operator starts answer period
        vm.prank(operator);
        arena.startBountyAnswerPeriod(bountyId);

        state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.AnswerPeriod));

        // Step 4: Agents submit answers (with NEURON burns)
        uint256 agent1NeuronBefore = neuron.balanceOf(agent1);
        uint256 agent2NeuronBefore = neuron.balanceOf(agent2);

        vm.prank(agent1);
        arena.submitBountyAnswer(bountyId, "Insertion sort for nearly sorted data");

        vm.prank(agent2);
        arena.submitBountyAnswer(bountyId, "TimSort");

        assertEq(neuron.balanceOf(agent1), agent1NeuronBefore - BASE_ANSWER_FEE);
        assertEq(neuron.balanceOf(agent2), agent2NeuronBefore - BASE_ANSWER_FEE);
        assertEq(arena.bountyBurnTotal(bountyId), BASE_ANSWER_FEE * 2);

        // Step 5: Operator settles bounty with winner
        uint256 pool = BOUNTY_REWARD;
        uint256 expectedWinnerPrize = (pool * 8500) / 10000;
        uint256 expectedTreasuryFee = (pool * 1000) / 10000;

        uint256 agent1BalanceBefore = agent1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(operator);
        arena.settleBounty(bountyId, agent1);

        state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Settled));
        assertEq(state.winner, agent1);

        assertEq(agent1.balance, agent1BalanceBefore + expectedWinnerPrize);
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);
    }

    function test_fullLifecycle_expiryPath() public {
        // Create bounty
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );

        // Nobody joins
        vm.warp(block.timestamp + JOIN_DURATION + 1);

        // Expire
        vm.prank(operator);
        arena.expireBounty(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Expired));

        // Creator gets full refund
        assertEq(arena.pendingRefunds(creator), BOUNTY_REWARD);

        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(creator);
        arena.withdrawRefund();
        assertEq(creator.balance, creatorBalanceBefore + BOUNTY_REWARD);
    }

    function test_fullLifecycle_refundPath() public {
        // Create and setup bounty
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        // Agents submit wrong answers
        vm.prank(agent1);
        arena.submitBountyAnswer(bountyId, "wrong1");
        vm.prank(agent2);
        arena.submitBountyAnswer(bountyId, "wrong2");

        // Answer period times out
        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        uint256 pool = BOUNTY_REWARD;
        uint256 expectedTreasuryFee = (pool * 1000) / 10000;
        uint256 expectedRefund = pool - expectedTreasuryFee;

        uint256 treasuryBalanceBefore = treasury.balance;

        // Refund bounty
        vm.prank(operator);
        arena.refundBounty(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Refunded));

        // Treasury paid
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);

        // Creator gets refund
        assertEq(arena.pendingRefunds(creator), expectedRefund);

        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(creator);
        arena.withdrawRefund();
        assertEq(creator.balance, creatorBalanceBefore + expectedRefund);
    }

    function test_fullLifecycle_multipleAttempts() public {
        uint256 bountyId = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId);

        uint256 neuronBefore = neuron.balanceOf(agent1);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(agent1);
            arena.submitBountyAnswer(bountyId, string(abi.encodePacked("attempt", i)));
        }

        // Total: 0.1 + 0.2 + 0.4 + 0.8 = 1.5 ether
        uint256 expectedTotalBurn = BASE_ANSWER_FEE * (1 + 2 + 4 + 8);
        assertEq(neuron.balanceOf(agent1), neuronBefore - expectedTotalBurn);
        assertEq(arena.answerAttempts(bountyId, agent1), 4);
        assertEq(arena.bountyBurnTotal(bountyId), expectedTotalBurn);
    }

    function test_fullLifecycle_burnAllocationAccumulates() public {
        // First bounty
        uint256 bountyId1 = _createDefaultBounty();
        _setupBountyToAnswerPeriod(bountyId1);

        vm.prank(operator);
        arena.settleBounty(bountyId1, agent1);

        uint256 allocation1 = arena.burnAllocation(agent1);
        assertTrue(allocation1 > 0);

        // Second bounty
        uint256 bountyId2 = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId2);
        _joinBounty(agent3, agent3Id, bountyId2);

        vm.prank(operator);
        arena.startBountyAnswerPeriod(bountyId2);

        vm.prank(operator);
        arena.settleBounty(bountyId2, agent1);

        uint256 allocation2 = arena.burnAllocation(agent1);
        assertTrue(allocation2 > allocation1, "Burn allocation should accumulate");
    }

    function test_fullLifecycle_ratedBounty() public {
        // Create bounty with rating gate of 5
        uint256 bountyId = _createRatedBounty(int128(5));

        // agent1 has summaryValue=100 - should pass
        _joinBounty(agent1, agent1Id, bountyId);

        // Set agent2 low reputation
        reputation.setSummary(agent2Id, 2, 1, 0);

        // agent2 has summaryValue=1 - should fail
        vm.prank(agent2);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.InsufficientRating.selector, int128(5), int128(1)));
        arena.joinBounty(bountyId, agent2Id);

        // agent3 has summaryValue=60 - should pass
        _joinBounty(agent3, agent3Id, bountyId);

        assertEq(arena.getAgentCount(bountyId), 2);
    }
}

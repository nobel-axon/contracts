// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BountyArena.sol";
import "./mocks/MockNeuronToken.sol";
import "./mocks/MockIdentityRegistry.sol";
import "./mocks/MockReputationRegistry.sol";

contract BountyArenaTest is Test {
    BountyArena public arena;
    MockNeuronToken public neuron;
    MockIdentityRegistry public identity;
    MockReputationRegistry public reputation;

    address public owner;
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
    uint64 public constant DURATION = 300; // 5 minutes
    uint8 public constant MAX_AGENTS = 8;
    int128 public constant NO_RATING_GATE = 0;

    string public constant DEFAULT_QUESTION = "What is the best consensus algorithm for high throughput?";
    string public constant DEFAULT_CATEGORY = "crypto";
    uint8 public constant DEFAULT_DIFFICULTY = 3;

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

    function setUp() public {
        owner = address(this);
        creator = makeAddr("creator");
        agent1 = makeAddr("agent1");
        agent2 = makeAddr("agent2");
        agent3 = makeAddr("agent3");
        agent4 = makeAddr("agent4");

        // Deploy mocks
        neuron = new MockNeuronToken();
        identity = new MockIdentityRegistry();
        reputation = new MockReputationRegistry();

        // Deploy arena (3 args only)
        arena = new BountyArena(
            address(neuron),
            address(reputation),
            address(identity)
        );

        // Add test contract as operator (owner = address(this))
        arena.addOperator(address(this));

        // Fund creator with NEURON + approve arena (for reward deposit)
        neuron.mint(creator, 1000 ether);
        vm.prank(creator);
        neuron.approve(address(arena), type(uint256).max);

        // Fund agents with MON (gas only) + NEURON + approve arena (for answer fees)
        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        vm.deal(agent3, 10 ether);
        vm.deal(agent4, 10 ether);

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

        // Register agents in identity registry
        vm.prank(agent1);
        agent1Id = identity.register("");
        vm.prank(agent2);
        agent2Id = identity.register("");
        vm.prank(agent3);
        agent3Id = identity.register("");
        vm.prank(agent4);
        agent4Id = identity.register("");

        // Set default reputations
        reputation.setSummary(agent1Id, 10, 100, 0);
        reputation.setSummary(agent2Id, 8, 80, 0);
        reputation.setSummary(agent3Id, 6, 60, 0);
        reputation.setSummary(agent4Id, 4, 40, 0);
    }

    // ============ Helpers ============

    function _createDefaultBounty() internal returns (uint256 bountyId) {
        vm.prank(creator);
        bountyId = arena.createBounty(
            DEFAULT_QUESTION,
            NO_RATING_GATE,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            DURATION,
            MAX_AGENTS,
            BOUNTY_REWARD,
            BASE_ANSWER_FEE
        );
        arena.approveBounty(bountyId);
    }

    function _createPendingBounty() internal returns (uint256 bountyId) {
        vm.prank(creator);
        bountyId = arena.createBounty(
            DEFAULT_QUESTION,
            NO_RATING_GATE,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            DURATION,
            MAX_AGENTS,
            BOUNTY_REWARD,
            BASE_ANSWER_FEE
        );
    }

    function _createRatedBounty(int128 minRating) internal returns (uint256 bountyId) {
        vm.prank(creator);
        bountyId = arena.createBounty(
            DEFAULT_QUESTION,
            minRating,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            DURATION,
            MAX_AGENTS,
            BOUNTY_REWARD,
            BASE_ANSWER_FEE
        );
        arena.approveBounty(bountyId);
    }

    function _joinBounty(address agent, uint256 agentId, uint256 bountyId) internal {
        vm.prank(agent);
        arena.joinBounty(bountyId, agentId);
    }

    function _submitAnswer(address agent, uint256 bountyId, string memory answer) internal {
        vm.prank(agent);
        arena.submitBountyAnswer(bountyId, answer);
    }

    function _createAndPopulate() internal returns (uint256 bountyId) {
        bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsDefaults() public view {
        assertEq(address(arena.neuronToken()), address(neuron));
        assertEq(address(arena.reputationRegistry()), address(reputation));
        assertEq(address(arena.identityRegistry()), address(identity));
        assertEq(arena.nextBountyId(), 1);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(BountyArena.ZeroAddress.selector);
        new BountyArena(address(0), address(reputation), address(identity));

        vm.expectRevert(BountyArena.ZeroAddress.selector);
        new BountyArena(address(neuron), address(0), address(identity));

        vm.expectRevert(BountyArena.ZeroAddress.selector);
        new BountyArena(address(neuron), address(reputation), address(0));
    }

    // ============ Operator Tests ============

    function test_addOperator_success() public {
        address op = makeAddr("operator");
        vm.expectEmit(true, false, false, true);
        emit OperatorAdded(op);
        arena.addOperator(op);
        assertTrue(arena.operators(op));
    }

    function test_removeOperator_success() public {
        address op = makeAddr("operator");
        arena.addOperator(op);
        vm.expectEmit(true, false, false, true);
        emit OperatorRemoved(op);
        arena.removeOperator(op);
        assertFalse(arena.operators(op));
    }

    function test_addOperator_revertsIfNotOwner() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", agent1));
        arena.addOperator(agent1);
    }

    // ============ approveBounty / rejectBounty Tests ============

    function test_createBounty_startsPending() public {
        uint256 bountyId = _createPendingBounty();
        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Pending));
    }

    function test_approveBounty_success() public {
        uint256 bountyId = _createPendingBounty();

        vm.expectEmit(true, false, false, true);
        emit BountyApproved(bountyId);
        arena.approveBounty(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Active));
    }

    function test_approveBounty_revertsIfNotOperator() public {
        uint256 bountyId = _createPendingBounty();

        vm.prank(agent1);
        vm.expectRevert("not operator");
        arena.approveBounty(bountyId);
    }

    function test_approveBounty_revertsIfNotPending() public {
        uint256 bountyId = _createDefaultBounty(); // already approved (Active)

        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.Pending,
            BountyArena.BountyPhase.Active
        ));
        arena.approveBounty(bountyId);
    }

    function test_rejectBounty_refundsCreator() public {
        uint256 creatorBefore = neuron.balanceOf(creator);
        uint256 bountyId = _createPendingBounty();
        assertEq(neuron.balanceOf(creator), creatorBefore - BOUNTY_REWARD);

        vm.expectEmit(true, false, false, false);
        emit BountyRejected(bountyId, "spam question");
        arena.rejectBounty(bountyId, "spam question");

        // Creator gets refund
        assertEq(neuron.balanceOf(creator), creatorBefore);

        // Bounty is Settled with rewardClaimed = true
        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Settled));
        assertTrue(state.rewardClaimed);
    }

    function test_rejectBounty_revertsIfNotOperator() public {
        uint256 bountyId = _createPendingBounty();

        vm.prank(agent1);
        vm.expectRevert("not operator");
        arena.rejectBounty(bountyId, "reason");
    }

    function test_rejectBounty_revertsIfNotPending() public {
        uint256 bountyId = _createDefaultBounty(); // already approved (Active)

        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.Pending,
            BountyArena.BountyPhase.Active
        ));
        arena.rejectBounty(bountyId, "reason");
    }

    function test_joinBounty_revertsIfPending() public {
        uint256 bountyId = _createPendingBounty();

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.Active,
            BountyArena.BountyPhase.Pending
        ));
        arena.joinBounty(bountyId, agent1Id);
    }

    // ============ createBounty Tests ============

    function test_createBounty_success() public {
        uint256 creatorNeuronBefore = neuron.balanceOf(creator);

        vm.prank(creator);
        vm.expectEmit(true, true, false, true);
        emit BountyCreated(
            1,
            creator,
            BOUNTY_REWARD,
            BASE_ANSWER_FEE,
            DEFAULT_QUESTION,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            NO_RATING_GATE,
            uint64(block.timestamp) + DURATION,
            MAX_AGENTS
        );
        uint256 bountyId = arena.createBounty(
            DEFAULT_QUESTION,
            NO_RATING_GATE,
            DEFAULT_CATEGORY,
            DEFAULT_DIFFICULTY,
            DURATION,
            MAX_AGENTS,
            BOUNTY_REWARD,
            BASE_ANSWER_FEE
        );

        assertEq(bountyId, 1);
        assertEq(neuron.balanceOf(creator), creatorNeuronBefore - BOUNTY_REWARD);
        assertEq(neuron.balanceOf(address(arena)), BOUNTY_REWARD);

        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);
        assertEq(config.creator, creator);
        assertEq(config.reward, BOUNTY_REWARD);
        assertEq(config.baseAnswerFee, BASE_ANSWER_FEE);
        assertEq(config.minRating, NO_RATING_GATE);
        assertEq(config.maxAgents, MAX_AGENTS);
        assertEq(config.difficulty, DEFAULT_DIFFICULTY);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Pending));
        assertEq(state.agentCount, 0);
        assertEq(state.answeringAgentCount, 0);
        assertFalse(state.rewardClaimed);
    }

    function test_createBounty_incrementsId() public {
        vm.startPrank(creator);
        uint256 id1 = arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        uint256 id2 = arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_createBounty_revertsIfZeroReward() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, 0, BASE_ANSWER_FEE
        );
    }

    function test_createBounty_revertsIfZeroAnswerFee() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, 0
        );
    }

    function test_createBounty_revertsIfEmptyQuestion() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty(
            "", NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
    }

    function test_createBounty_revertsIfInvalidDifficulty() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, 0,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );

        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, 6,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
    }

    function test_createBounty_revertsIfZeroDuration() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            0, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
    }

    function test_createBounty_revertsIfZeroMaxAgents() public {
        vm.prank(creator);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, 0, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
    }

    function test_createBounty_withRatingGate() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            DEFAULT_QUESTION, int128(50), DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );

        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);
        assertEq(config.minRating, int128(50));
    }

    // ============ joinBounty Tests ============

    function test_joinBounty_success() public {
        uint256 bountyId = _createDefaultBounty();

        vm.prank(agent1);
        vm.expectEmit(true, true, false, true);
        emit AgentJoinedBounty(bountyId, agent1, agent1Id, 1, int128(100));
        arena.joinBounty(bountyId, agent1Id);

        assertTrue(arena.isAgentInBounty(bountyId, agent1));
        assertEq(arena.getAgentCount(bountyId), 1);
        assertEq(arena.agentReputation(bountyId, agent1), int128(100));
    }

    function test_joinBounty_snapshotsReputation() public {
        uint256 bountyId = _createDefaultBounty();

        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);

        assertEq(arena.agentReputation(bountyId, agent1), int128(100));
        assertEq(arena.agentReputation(bountyId, agent2), int128(80));
    }

    function test_joinBounty_multipleAgents() public {
        uint256 bountyId = _createDefaultBounty();

        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
        _joinBounty(agent3, agent3Id, bountyId);

        assertEq(arena.getAgentCount(bountyId), 3);
    }

    function test_joinBounty_revertsIfCreator() public {
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
        uint256 bountyId = arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, 2, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        arena.approveBounty(bountyId);

        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);

        vm.prank(agent3);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyFull.selector, bountyId));
        arena.joinBounty(bountyId, agent3Id);
    }

    function test_joinBounty_revertsAfterDeadline() public {
        uint256 bountyId = _createDefaultBounty();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.DeadlinePassed.selector, bountyId));
        arena.joinBounty(bountyId, agent1Id);
    }

    function test_joinBounty_revertsIfNotRegistered() public {
        uint256 bountyId = _createDefaultBounty();
        address unregistered = makeAddr("unregistered");

        vm.prank(unregistered);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AgentNotRegistered.selector, unregistered));
        arena.joinBounty(bountyId, 999);
    }

    function test_joinBounty_revertsIfWrongAgentId() public {
        uint256 bountyId = _createDefaultBounty();

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AgentNotRegistered.selector, agent1));
        arena.joinBounty(bountyId, agent2Id);
    }

    function test_joinBounty_ratingGate_passes() public {
        uint256 bountyId = _createRatedBounty(int128(5));

        _joinBounty(agent1, agent1Id, bountyId);
        assertTrue(arena.isAgentInBounty(bountyId, agent1));
    }

    function test_joinBounty_ratingGate_fails() public {
        uint256 bountyId = _createRatedBounty(int128(50));

        reputation.setSummary(agent1Id, 2, 2, 0);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.InsufficientRating.selector, int128(50), int128(2)));
        arena.joinBounty(bountyId, agent1Id);
    }

    function test_joinBounty_ratingGate_zeroMeansOpen() public {
        uint256 bountyId = _createDefaultBounty();

        reputation.setSummary(agent1Id, 0, 0, 0);

        _joinBounty(agent1, agent1Id, bountyId);
        assertTrue(arena.isAgentInBounty(bountyId, agent1));
    }

    // ============ submitBountyAnswer Tests ============

    function test_submitBountyAnswer_burnsCorrectAmount() public {
        uint256 bountyId = _createAndPopulate();

        uint256 neuronBefore = neuron.balanceOf(agent1);

        _submitAnswer(agent1, bountyId, "my answer");

        assertEq(neuron.balanceOf(agent1), neuronBefore - BASE_ANSWER_FEE);
        assertEq(arena.answerAttempts(bountyId, agent1), 1);
    }

    function test_submitBountyAnswer_setsHasAnswered() public {
        uint256 bountyId = _createAndPopulate();

        assertFalse(arena.hasAnswered(bountyId, agent1));

        _submitAnswer(agent1, bountyId, "my answer");

        assertTrue(arena.hasAnswered(bountyId, agent1));
    }

    function test_submitBountyAnswer_updatesAnsweringAgentCount() public {
        uint256 bountyId = _createAndPopulate();

        _submitAnswer(agent1, bountyId, "answer1");
        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(state.answeringAgentCount, 1);

        _submitAnswer(agent2, bountyId, "answer2");
        state = arena.getBountyState(bountyId);
        assertEq(state.answeringAgentCount, 2);
    }

    function test_submitBountyAnswer_updatesTotalAnsweringReputation() public {
        uint256 bountyId = _createAndPopulate();

        _submitAnswer(agent1, bountyId, "answer1");
        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(state.totalAnsweringReputation, int128(100)); // agent1 rep

        _submitAnswer(agent2, bountyId, "answer2");
        state = arena.getBountyState(bountyId);
        assertEq(state.totalAnsweringReputation, int128(180)); // 100 + 80
    }

    function test_submitBountyAnswer_secondAnswerDoesNotDoubleCount() public {
        uint256 bountyId = _createAndPopulate();

        _submitAnswer(agent1, bountyId, "answer1");
        _submitAnswer(agent1, bountyId, "answer2");

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(state.answeringAgentCount, 1);
        assertEq(state.totalAnsweringReputation, int128(100));
    }

    function test_submitBountyAnswer_feeDoubles() public {
        uint256 bountyId = _createAndPopulate();

        uint256 neuronBefore = neuron.balanceOf(agent1);

        _submitAnswer(agent1, bountyId, "attempt1");
        assertEq(neuron.balanceOf(agent1), neuronBefore - BASE_ANSWER_FEE);

        _submitAnswer(agent1, bountyId, "attempt2");
        assertEq(neuron.balanceOf(agent1), neuronBefore - BASE_ANSWER_FEE - (BASE_ANSWER_FEE * 2));

        _submitAnswer(agent1, bountyId, "attempt3");
        assertEq(neuron.balanceOf(agent1), neuronBefore - BASE_ANSWER_FEE - (BASE_ANSWER_FEE * 2) - (BASE_ANSWER_FEE * 4));

        assertEq(arena.answerAttempts(bountyId, agent1), 3);
    }

    function test_submitBountyAnswer_emitsEvents() public {
        uint256 bountyId = _createAndPopulate();

        vm.prank(agent1);
        vm.expectEmit(true, true, false, true);
        emit BountyAnswerSubmitted(bountyId, agent1, "test answer", 1, BASE_ANSWER_FEE);
        arena.submitBountyAnswer(bountyId, "test answer");
    }

    function test_submitBountyAnswer_revertsIfNotInBounty() public {
        uint256 bountyId = _createAndPopulate();

        vm.prank(agent3);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.NotInBounty.selector, bountyId, agent3));
        arena.submitBountyAnswer(bountyId, "answer");
    }

    function test_submitBountyAnswer_revertsAfterDeadline() public {
        uint256 bountyId = _createAndPopulate();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.DeadlinePassed.selector, bountyId));
        arena.submitBountyAnswer(bountyId, "answer");
    }

    // ============ pickWinner Tests ============

    function test_pickWinner_success() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.prank(creator);
        vm.expectEmit(true, true, false, true);
        emit BountySettled(bountyId, agent1, BOUNTY_REWARD);
        arena.pickWinner(bountyId, agent1);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(state.winner, agent1);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Settled));
    }

    function test_pickWinner_revertsIfNotCreator() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.prank(agent2);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.NotCreator.selector, bountyId));
        arena.pickWinner(bountyId, agent1);
    }

    function test_pickWinner_revertsIfDeadlinePassed() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.DeadlinePassed.selector, bountyId));
        arena.pickWinner(bountyId, agent1);
    }

    function test_pickWinner_revertsIfWinnerNotAnswered() public {
        uint256 bountyId = _createAndPopulate();

        // agent1 joined but didn't answer
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AgentNotAnswered.selector, bountyId, agent1));
        arena.pickWinner(bountyId, agent1);
    }

    function test_pickWinner_revertsIfAlreadySettled() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");
        _submitAnswer(agent2, bountyId, "answer");

        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.Active,
            BountyArena.BountyPhase.Settled
        ));
        arena.pickWinner(bountyId, agent2);
    }

    // ============ claimWinnerReward Tests ============

    function test_claimWinnerReward_success() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        uint256 neuronBefore = neuron.balanceOf(agent1);

        vm.prank(agent1);
        vm.expectEmit(true, true, false, true);
        emit WinnerRewardClaimed(bountyId, agent1, BOUNTY_REWARD);
        arena.claimWinnerReward(bountyId);

        assertEq(neuron.balanceOf(agent1), neuronBefore + BOUNTY_REWARD);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertTrue(state.rewardClaimed);
    }

    function test_claimWinnerReward_revertsIfNotWinner() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        vm.prank(agent2);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.NotWinner.selector, bountyId));
        arena.claimWinnerReward(bountyId);
    }

    function test_claimWinnerReward_revertsIfDoubleClaim() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        vm.prank(agent1);
        arena.claimWinnerReward(bountyId);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AlreadyClaimed.selector, bountyId, agent1));
        arena.claimWinnerReward(bountyId);
    }

    function test_claimWinnerReward_revertsIfNotSettled() public {
        uint256 bountyId = _createAndPopulate();

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.Settled,
            BountyArena.BountyPhase.Active
        ));
        arena.claimWinnerReward(bountyId);
    }

    // ============ claimProportional Tests ============

    function test_claimProportional_proportionalByReputation() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer1"); // rep 100
        _submitAnswer(agent2, bountyId, "answer2"); // rep 80

        vm.warp(block.timestamp + DURATION + 1);

        // Total rep = 180
        uint256 agent1Expected = (BOUNTY_REWARD * 100) / 180;
        uint256 agent2Expected = (BOUNTY_REWARD * 80) / 180;

        uint256 agent1NeuronBefore = neuron.balanceOf(agent1);
        uint256 agent2NeuronBefore = neuron.balanceOf(agent2);

        vm.prank(agent1);
        arena.claimProportional(bountyId);

        vm.prank(agent2);
        arena.claimProportional(bountyId);

        assertEq(neuron.balanceOf(agent1), agent1NeuronBefore + agent1Expected);
        assertEq(neuron.balanceOf(agent2), agent2NeuronBefore + agent2Expected);
    }

    function test_claimProportional_equalSplitIfZeroTotalRep() public {
        // Set all agents to zero rep
        reputation.setSummary(agent1Id, 0, 0, 0);
        reputation.setSummary(agent2Id, 0, 0, 0);

        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);

        _submitAnswer(agent1, bountyId, "answer1");
        _submitAnswer(agent2, bountyId, "answer2");

        vm.warp(block.timestamp + DURATION + 1);

        uint256 expectedShare = BOUNTY_REWARD / 2;

        uint256 agent1NeuronBefore = neuron.balanceOf(agent1);
        uint256 agent2NeuronBefore = neuron.balanceOf(agent2);

        vm.prank(agent1);
        arena.claimProportional(bountyId);

        vm.prank(agent2);
        arena.claimProportional(bountyId);

        assertEq(neuron.balanceOf(agent1), agent1NeuronBefore + expectedShare);
        assertEq(neuron.balanceOf(agent2), agent2NeuronBefore + expectedShare);
    }

    function test_claimProportional_negativeRepGetsZero() public {
        // agent1 has negative rep, agent2 has positive
        reputation.setSummary(agent1Id, 5, -10, 0);
        reputation.setSummary(agent2Id, 5, 100, 0);

        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);

        _submitAnswer(agent1, bountyId, "answer1");
        _submitAnswer(agent2, bountyId, "answer2");

        vm.warp(block.timestamp + DURATION + 1);

        // totalAnsweringReputation = 100 (only positive reps summed)
        // agent1 rep = -10 → gets 0
        // agent2 rep = 100 → gets full reward (100/100)

        uint256 agent1NeuronBefore = neuron.balanceOf(agent1);
        uint256 agent2NeuronBefore = neuron.balanceOf(agent2);

        vm.prank(agent1);
        vm.expectEmit(true, true, false, true);
        emit ProportionalClaimed(bountyId, agent1, 0);
        arena.claimProportional(bountyId);

        assertEq(neuron.balanceOf(agent1), agent1NeuronBefore); // no transfer

        // agent2 claims full reward since they're the only positive-rep answerer
        vm.prank(agent2);
        arena.claimProportional(bountyId);
        assertEq(neuron.balanceOf(agent2), agent2NeuronBefore + BOUNTY_REWARD);
    }

    function test_claimProportional_revertsIfDoubleClaim() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(agent1);
        arena.claimProportional(bountyId);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AlreadyClaimed.selector, bountyId, agent1));
        arena.claimProportional(bountyId);
    }

    function test_claimProportional_revertsIfBeforeDeadline() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.DeadlineNotPassed.selector, bountyId));
        arena.claimProportional(bountyId);
    }

    function test_claimProportional_revertsIfNotAnswered() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.warp(block.timestamp + DURATION + 1);

        // agent2 joined but didn't answer
        vm.prank(agent2);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AgentNotAnswered.selector, bountyId, agent2));
        arena.claimProportional(bountyId);
    }

    function test_claimProportional_revertsIfSettled() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(
            BountyArena.InvalidPhase.selector,
            BountyArena.BountyPhase.Active,
            BountyArena.BountyPhase.Settled
        ));
        arena.claimProportional(bountyId);
    }

    // ============ claimRefund Tests ============

    function test_claimRefund_success() public {
        uint256 bountyId = _createDefaultBounty();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 creatorNeuronBefore = neuron.balanceOf(creator);

        vm.prank(creator);
        vm.expectEmit(true, true, false, true);
        emit RefundClaimed(bountyId, creator, BOUNTY_REWARD);
        arena.claimRefund(bountyId);

        assertEq(neuron.balanceOf(creator), creatorNeuronBefore + BOUNTY_REWARD);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertTrue(state.rewardClaimed);
    }

    function test_claimRefund_worksWithJoinsButNoAnswers() public {
        uint256 bountyId = _createAndPopulate();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 creatorNeuronBefore = neuron.balanceOf(creator);

        vm.prank(creator);
        arena.claimRefund(bountyId);

        assertEq(neuron.balanceOf(creator), creatorNeuronBefore + BOUNTY_REWARD);
    }

    function test_claimRefund_revertsIfNotCreator() public {
        uint256 bountyId = _createDefaultBounty();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.NotCreator.selector, bountyId));
        arena.claimRefund(bountyId);
    }

    function test_claimRefund_revertsIfBeforeDeadline() public {
        uint256 bountyId = _createDefaultBounty();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.DeadlineNotPassed.selector, bountyId));
        arena.claimRefund(bountyId);
    }

    function test_claimRefund_revertsIfAgentsAnswered() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AgentsAnswered.selector, bountyId));
        arena.claimRefund(bountyId);
    }

    function test_claimRefund_revertsIfDoubleClaim() public {
        uint256 bountyId = _createDefaultBounty();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(creator);
        arena.claimRefund(bountyId);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.AlreadyClaimed.selector, bountyId, creator));
        arena.claimRefund(bountyId);
    }

    // ============ Pause Tests ============

    function test_pause_blocksCreateBounty() public {
        arena.pause();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
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
        uint256 bountyId = _createAndPopulate();

        arena.pause();

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        arena.submitBountyAnswer(bountyId, "answer");
    }

    function test_pause_allowsPickWinner() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        arena.pause();

        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Settled));
    }

    function test_pause_allowsClaims() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        arena.pause();

        vm.prank(agent1);
        arena.claimWinnerReward(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertTrue(state.rewardClaimed);
    }

    function test_pause_allowsRefund() public {
        uint256 bountyId = _createDefaultBounty();

        arena.pause();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(creator);
        arena.claimRefund(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertTrue(state.rewardClaimed);
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

    function test_getCurrentAnswerFee_doublesCorrectly() public {
        uint256 bountyId = _createAndPopulate();

        assertEq(arena.getCurrentAnswerFee(bountyId, agent1), BASE_ANSWER_FEE);

        _submitAnswer(agent1, bountyId, "attempt1");
        assertEq(arena.getCurrentAnswerFee(bountyId, agent1), BASE_ANSWER_FEE * 2);

        _submitAnswer(agent1, bountyId, "attempt2");
        assertEq(arena.getCurrentAnswerFee(bountyId, agent1), BASE_ANSWER_FEE * 4);
    }

    function test_getClaimableAmount() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer1");
        _submitAnswer(agent2, bountyId, "answer2");

        // Before deadline: 0
        assertEq(arena.getClaimableAmount(bountyId, agent1), 0);

        vm.warp(block.timestamp + DURATION + 1);

        // After deadline: proportional
        uint256 agent1Claimable = arena.getClaimableAmount(bountyId, agent1);
        uint256 agent2Claimable = arena.getClaimableAmount(bountyId, agent2);
        assertEq(agent1Claimable, (BOUNTY_REWARD * 100) / 180);
        assertEq(agent2Claimable, (BOUNTY_REWARD * 80) / 180);

        // After claim: 0
        vm.prank(agent1);
        arena.claimProportional(bountyId);
        assertEq(arena.getClaimableAmount(bountyId, agent1), 0);
    }

    // ============ Full Lifecycle Integration Tests ============

    function test_fullLifecycle_happyPath() public {
        // Create bounty
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "What is the most efficient sorting algorithm for nearly sorted data?",
            NO_RATING_GATE,
            "algorithms",
            2,
            DURATION,
            MAX_AGENTS,
            BOUNTY_REWARD,
            BASE_ANSWER_FEE
        );

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Pending));

        // Approve bounty
        arena.approveBounty(bountyId);
        state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Active));

        // Agents join
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
        _joinBounty(agent3, agent3Id, bountyId);

        assertEq(arena.getAgentCount(bountyId), 3);

        // Agents submit answers
        uint256 agent1NeuronBefore = neuron.balanceOf(agent1);
        uint256 agent2NeuronBefore = neuron.balanceOf(agent2);

        _submitAnswer(agent1, bountyId, "Insertion sort for nearly sorted data");
        _submitAnswer(agent2, bountyId, "TimSort");

        assertEq(neuron.balanceOf(agent1), agent1NeuronBefore - BASE_ANSWER_FEE);
        assertEq(neuron.balanceOf(agent2), agent2NeuronBefore - BASE_ANSWER_FEE);

        // Creator picks winner
        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        state = arena.getBountyState(bountyId);
        assertEq(uint8(state.phase), uint8(BountyArena.BountyPhase.Settled));
        assertEq(state.winner, agent1);

        // Winner claims reward
        uint256 winnerNeuronBefore = neuron.balanceOf(agent1);
        vm.prank(agent1);
        arena.claimWinnerReward(bountyId);

        assertEq(neuron.balanceOf(agent1), winnerNeuronBefore + BOUNTY_REWARD);
    }

    function test_fullLifecycle_proportionalPath() public {
        // Create bounty, agents join and answer
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer1"); // rep 100
        _submitAnswer(agent2, bountyId, "answer2"); // rep 80

        // Deadline passes (no winner picked)
        vm.warp(block.timestamp + DURATION + 1);

        uint256 agent1NeuronBefore = neuron.balanceOf(agent1);
        uint256 agent2NeuronBefore = neuron.balanceOf(agent2);

        // Agents claim proportional
        vm.prank(agent1);
        arena.claimProportional(bountyId);

        vm.prank(agent2);
        arena.claimProportional(bountyId);

        uint256 expectedAgent1 = (BOUNTY_REWARD * 100) / 180;
        uint256 expectedAgent2 = (BOUNTY_REWARD * 80) / 180;

        assertEq(neuron.balanceOf(agent1), agent1NeuronBefore + expectedAgent1);
        assertEq(neuron.balanceOf(agent2), agent2NeuronBefore + expectedAgent2);
    }

    function test_fullLifecycle_refundPath() public {
        // Create bounty, nobody answers
        uint256 bountyId = _createDefaultBounty();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 creatorNeuronBefore = neuron.balanceOf(creator);

        vm.prank(creator);
        arena.claimRefund(bountyId);

        assertEq(neuron.balanceOf(creator), creatorNeuronBefore + BOUNTY_REWARD);
    }

    function test_fullLifecycle_refundWithJoinsButNoAnswers() public {
        // Agents join but never answer
        uint256 bountyId = _createAndPopulate();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 creatorNeuronBefore = neuron.balanceOf(creator);

        vm.prank(creator);
        arena.claimRefund(bountyId);

        assertEq(neuron.balanceOf(creator), creatorNeuronBefore + BOUNTY_REWARD);
    }

    function test_fullLifecycle_multipleAttempts() public {
        uint256 bountyId = _createAndPopulate();

        uint256 neuronBefore = neuron.balanceOf(agent1);

        for (uint256 i = 0; i < 4; i++) {
            _submitAnswer(agent1, bountyId, string(abi.encodePacked("attempt", i)));
        }

        // Total: 0.1 + 0.2 + 0.4 + 0.8 = 1.5 ether
        uint256 expectedTotalBurn = BASE_ANSWER_FEE * (1 + 2 + 4 + 8);
        assertEq(neuron.balanceOf(agent1), neuronBefore - expectedTotalBurn);
        assertEq(arena.answerAttempts(bountyId, agent1), 4);
        assertEq(arena.bountyBurnTotal(bountyId), expectedTotalBurn);
    }

    function test_fullLifecycle_ratedBounty() public {
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

    // ============ Security: Attempt Cap Tests ============

    function test_submitBountyAnswer_revertsAtMaxAttempts() public {
        uint256 bountyId = _createAndPopulate();

        // Fund agent1 with enough NEURON for 20 attempts (sum of 2^0..2^19 * fee)
        neuron.mint(agent1, 200_000 ether);

        // Submit 20 attempts (0..19) — all should succeed
        for (uint256 i = 0; i < 20; i++) {
            _submitAnswer(agent1, bountyId, "answer");
        }
        assertEq(arena.answerAttempts(bountyId, agent1), 20);

        // 21st attempt should revert
        vm.prank(agent1);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.submitBountyAnswer(bountyId, "answer");
    }

    function test_getCurrentAnswerFee_revertsAtMaxAttempts() public {
        uint256 bountyId = _createAndPopulate();
        neuron.mint(agent1, 200_000 ether);

        for (uint256 i = 0; i < 20; i++) {
            _submitAnswer(agent1, bountyId, "answer");
        }

        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.getCurrentAnswerFee(bountyId, agent1);
    }

    // ============ Security: Answer Length Tests ============

    function test_submitBountyAnswer_revertsIfEmptyAnswer() public {
        uint256 bountyId = _createAndPopulate();

        vm.prank(agent1);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.submitBountyAnswer(bountyId, "");
    }

    function test_submitBountyAnswer_revertsIfAnswerTooLong() public {
        uint256 bountyId = _createAndPopulate();

        // Build a string of 5001 bytes
        bytes memory longAnswer = new bytes(5001);
        for (uint256 i = 0; i < 5001; i++) {
            longAnswer[i] = "a";
        }

        vm.prank(agent1);
        vm.expectRevert(BountyArena.InvalidParameters.selector);
        arena.submitBountyAnswer(bountyId, string(longAnswer));
    }

    function test_submitBountyAnswer_succeedsAtMaxLength() public {
        uint256 bountyId = _createAndPopulate();

        bytes memory maxAnswer = new bytes(5000);
        for (uint256 i = 0; i < 5000; i++) {
            maxAnswer[i] = "a";
        }

        _submitAnswer(agent1, bountyId, string(maxAnswer));
        assertEq(arena.answerAttempts(bountyId, agent1), 1);
    }

    // ============ Security: Timestamp Boundary Tests ============

    function test_joinBounty_atExactDeadline() public {
        uint256 bountyId = _createDefaultBounty();
        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);

        // Warp to exactly the deadline — should succeed (uses >)
        vm.warp(config.deadline);

        _joinBounty(agent1, agent1Id, bountyId);
        assertTrue(arena.isAgentInBounty(bountyId, agent1));
    }

    function test_joinBounty_oneSecondAfterDeadline() public {
        uint256 bountyId = _createDefaultBounty();
        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);

        vm.warp(config.deadline + 1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.DeadlinePassed.selector, bountyId));
        arena.joinBounty(bountyId, agent1Id);
    }

    function test_claimProportional_atExactDeadline() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);
        vm.warp(config.deadline);

        // At exact deadline, claimProportional should revert (uses <=)
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.DeadlineNotPassed.selector, bountyId));
        arena.claimProportional(bountyId);
    }

    function test_claimProportional_oneSecondAfterDeadline() public {
        uint256 bountyId = _createAndPopulate();
        _submitAnswer(agent1, bountyId, "answer");

        BountyArena.BountyConfig memory config = arena.getBountyConfig(bountyId);
        vm.warp(config.deadline + 1);

        vm.prank(agent1);
        arena.claimProportional(bountyId);

        assertTrue(arena.claimed(bountyId, agent1));
    }

    // ============ Security: Mixed Reputation Proportional Tests ============

    function test_claimProportional_mixedPositiveNegativeRep() public {
        // agent1: -50, agent2: +100, agent3: +75
        reputation.setSummary(agent1Id, 5, -50, 0);
        reputation.setSummary(agent2Id, 5, 100, 0);
        reputation.setSummary(agent3Id, 5, 75, 0);

        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
        _joinBounty(agent3, agent3Id, bountyId);

        _submitAnswer(agent1, bountyId, "answer1");
        _submitAnswer(agent2, bountyId, "answer2");
        _submitAnswer(agent3, bountyId, "answer3");

        vm.warp(block.timestamp + DURATION + 1);

        // totalAnsweringReputation = 100 + 75 = 175 (only positive reps summed)
        // agent1 rep = -50 → gets 0
        // agent2 rep = 100 → gets reward * 100 / 175
        // agent3 rep = 75  → gets reward * 75 / 175
        // Total payouts ≤ reward (solvent)

        uint256 agent1Before = neuron.balanceOf(agent1);
        uint256 agent2Before = neuron.balanceOf(agent2);
        uint256 agent3Before = neuron.balanceOf(agent3);

        // agent1 (negative rep) claims 0
        vm.prank(agent1);
        arena.claimProportional(bountyId);
        assertEq(neuron.balanceOf(agent1), agent1Before); // 0 share

        // agent2 claims proportional share
        vm.prank(agent2);
        arena.claimProportional(bountyId);
        assertEq(neuron.balanceOf(agent2), agent2Before + (BOUNTY_REWARD * 100) / 175);

        // agent3 also claims successfully — no insolvency
        vm.prank(agent3);
        arena.claimProportional(bountyId);
        assertEq(neuron.balanceOf(agent3), agent3Before + (BOUNTY_REWARD * 75) / 175);
    }

    function test_claimProportional_allNegativeRep() public {
        // All agents negative → equal split
        reputation.setSummary(agent1Id, 5, -20, 0);
        reputation.setSummary(agent2Id, 5, -30, 0);
        reputation.setSummary(agent3Id, 5, -10, 0);

        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
        _joinBounty(agent3, agent3Id, bountyId);

        _submitAnswer(agent1, bountyId, "answer1");
        _submitAnswer(agent2, bountyId, "answer2");
        _submitAnswer(agent3, bountyId, "answer3");

        vm.warp(block.timestamp + DURATION + 1);

        // totalAnsweringReputation = -60 (≤ 0) → equal split
        uint256 expectedShare = BOUNTY_REWARD / 3;

        uint256 agent1Before = neuron.balanceOf(agent1);
        uint256 agent2Before = neuron.balanceOf(agent2);
        uint256 agent3Before = neuron.balanceOf(agent3);

        vm.prank(agent1);
        arena.claimProportional(bountyId);
        vm.prank(agent2);
        arena.claimProportional(bountyId);
        vm.prank(agent3);
        arena.claimProportional(bountyId);

        assertEq(neuron.balanceOf(agent1), agent1Before + expectedShare);
        assertEq(neuron.balanceOf(agent2), agent2Before + expectedShare);
        assertEq(neuron.balanceOf(agent3), agent3Before + expectedShare);
    }

    // ============ Security: View Function bountyExists Tests ============

    function test_getBountyConfig_revertsIfNotExists() public {
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyNotFound.selector, 999));
        arena.getBountyConfig(999);
    }

    function test_getBountyState_revertsIfNotExists() public {
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyNotFound.selector, 0));
        arena.getBountyState(0);
    }

    function test_getBountyAgents_revertsIfNotExists() public {
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyNotFound.selector, 42));
        arena.getBountyAgents(42);
    }

    function test_getAgentCount_revertsIfNotExists() public {
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyNotFound.selector, 5));
        arena.getAgentCount(5);
    }

    function test_getCurrentAnswerFee_revertsIfNotExists() public {
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyNotFound.selector, 100));
        arena.getCurrentAnswerFee(100, agent1);
    }

    function test_getClaimableAmount_revertsIfNotExists() public {
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyNotFound.selector, 50));
        arena.getClaimableAmount(50, agent1);
    }

    // ============ Security: Edge Case Tests ============

    function test_joinBounty_maxAgentsIsOne() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, 1, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        arena.approveBounty(bountyId);

        _joinBounty(agent1, agent1Id, bountyId);
        assertEq(arena.getAgentCount(bountyId), 1);

        // Second agent should fail
        vm.prank(agent2);
        vm.expectRevert(abi.encodeWithSelector(BountyArena.BountyFull.selector, bountyId));
        arena.joinBounty(bountyId, agent2Id);

        // Single agent can answer and win
        _submitAnswer(agent1, bountyId, "solo answer");
        vm.prank(creator);
        arena.pickWinner(bountyId, agent1);

        vm.prank(agent1);
        arena.claimWinnerReward(bountyId);

        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertTrue(state.rewardClaimed);
    }

    function test_submitBountyAnswer_insufficientBalance() public {
        uint256 bountyId = _createAndPopulate();

        // Drain agent1's NEURON by burning it (avoids approval issues)
        uint256 agent1Balance = neuron.balanceOf(agent1);
        vm.prank(agent1);
        neuron.burn(agent1Balance);
        assertEq(neuron.balanceOf(agent1), 0);

        // Should revert due to insufficient balance in burnFrom
        vm.prank(agent1);
        vm.expectRevert();
        arena.submitBountyAnswer(bountyId, "answer");
    }

    function test_constants_areCorrect() public view {
        assertEq(arena.MAX_ANSWER_ATTEMPTS(), 20);
        assertEq(arena.MAX_ANSWER_LENGTH(), 5000);
    }

    // ============ Solvency Regression Tests ============

    function test_solvency_mixedRepAllAgentsCanClaim() public {
        // Regression: mixed positive/negative rep must not cause insolvency
        reputation.setSummary(agent1Id, 5, -50, 0);
        reputation.setSummary(agent2Id, 5, 100, 0);
        reputation.setSummary(agent3Id, 5, 75, 0);

        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
        _joinBounty(agent3, agent3Id, bountyId);

        _submitAnswer(agent1, bountyId, "a1");
        _submitAnswer(agent2, bountyId, "a2");
        _submitAnswer(agent3, bountyId, "a3");

        // totalAnsweringReputation should be 175 (only positive: 100 + 75)
        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(state.totalAnsweringReputation, int128(175));

        vm.warp(block.timestamp + DURATION + 1);

        // All three agents claim without reverting
        vm.prank(agent1);
        arena.claimProportional(bountyId);
        vm.prank(agent2);
        arena.claimProportional(bountyId);
        vm.prank(agent3);
        arena.claimProportional(bountyId);

        // Contract retains dust from integer division, never goes negative
        assertTrue(neuron.balanceOf(address(arena)) >= 0);
    }

    function test_solvency_crossBountyFundsProtected() public {
        // Regression: insolvency in bounty1 must not drain bounty2's funds
        reputation.setSummary(agent1Id, 5, -50, 0);
        reputation.setSummary(agent2Id, 5, 100, 0);

        vm.prank(creator);
        uint256 bounty1 = arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        arena.approveBounty(bounty1);
        vm.prank(creator);
        uint256 bounty2 = arena.createBounty(
            DEFAULT_QUESTION, NO_RATING_GATE, DEFAULT_CATEGORY, DEFAULT_DIFFICULTY,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        arena.approveBounty(bounty2);

        // Contract holds 10 ETH (5 per bounty)
        assertEq(neuron.balanceOf(address(arena)), BOUNTY_REWARD * 2);

        _joinBounty(agent1, agent1Id, bounty1);
        _joinBounty(agent2, agent2Id, bounty1);
        _submitAnswer(agent1, bounty1, "a1");
        _submitAnswer(agent2, bounty1, "a2");

        vm.warp(block.timestamp + DURATION + 1);

        // agent2 claims from bounty1
        vm.prank(agent2);
        arena.claimProportional(bounty1);

        // Contract must still hold at least bounty2's full reward
        assertTrue(neuron.balanceOf(address(arena)) >= BOUNTY_REWARD);

        // bounty2 creator can still get a full refund
        vm.prank(creator);
        arena.claimRefund(bounty2);
    }

    function test_solvency_extremeNegativeRepNoAmplification() public {
        // Regression: near-zero denominator must not amplify payouts
        reputation.setSummary(agent1Id, 5, -999, 0);
        reputation.setSummary(agent2Id, 5, 1000, 0);
        reputation.setSummary(agent3Id, 5, 1, 0);

        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);
        _joinBounty(agent3, agent3Id, bountyId);

        _submitAnswer(agent1, bountyId, "a1");
        _submitAnswer(agent2, bountyId, "a2");
        _submitAnswer(agent3, bountyId, "a3");

        // totalAnsweringReputation should be 1001 (1000 + 1), NOT 2
        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(state.totalAnsweringReputation, int128(1001));

        vm.warp(block.timestamp + DURATION + 1);

        // agent2's share = reward * 1000 / 1001, NOT reward * 1000 / 2
        uint256 claimB = arena.getClaimableAmount(bountyId, agent2);
        assertTrue(claimB <= BOUNTY_REWARD);

        // All agents claim without reverting
        vm.prank(agent1);
        arena.claimProportional(bountyId);
        vm.prank(agent2);
        arena.claimProportional(bountyId);
        vm.prank(agent3);
        arena.claimProportional(bountyId);
    }

    function test_solvency_negativeRepExcludedFromTotal() public {
        // Verify negative rep is NOT added to totalAnsweringReputation
        reputation.setSummary(agent1Id, 5, -30, 0);
        reputation.setSummary(agent2Id, 5, 50, 0);

        uint256 bountyId = _createDefaultBounty();
        _joinBounty(agent1, agent1Id, bountyId);
        _joinBounty(agent2, agent2Id, bountyId);

        _submitAnswer(agent1, bountyId, "a1");
        BountyArena.BountyState memory state = arena.getBountyState(bountyId);
        assertEq(state.totalAnsweringReputation, int128(0)); // -30 excluded

        _submitAnswer(agent2, bountyId, "a2");
        state = arena.getBountyState(bountyId);
        assertEq(state.totalAnsweringReputation, int128(50)); // only +50
    }
}

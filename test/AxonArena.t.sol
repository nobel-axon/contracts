// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AxonArena.sol";
import "./mocks/MockNeuronToken.sol";

/**
 * @title AxonArena Test Suite
 * @notice Comprehensive tests for the AxonArena contract
 */
contract AxonArenaTest is Test {
    AxonArena public arena;
    MockNeuronToken public neuron;

    address public owner;
    address public operator;
    address public treasury;
    address public player1;
    address public player2;
    address public player3;
    address public player4;

    uint256 public constant ENTRY_FEE = 1 ether;
    uint256 public constant BASE_ANSWER_FEE = 0.1 ether;
    uint64 public constant QUEUE_DURATION = 120; // 2 minutes
    uint64 public constant ANSWER_DURATION = 180; // 3 minutes
    uint8 public constant MIN_PLAYERS = 2;
    uint8 public constant MAX_PLAYERS = 8;

    bytes32 public constant ANSWER_SALT = keccak256("salt123");
    string public constant CORRECT_ANSWER = "42";
    bytes32 public answerHash;

    event MatchCreated(
        uint256 indexed matchId,
        uint256 entryFee,
        uint256 baseAnswerFee,
        uint64 queueDeadline,
        uint8 minPlayers,
        uint8 maxPlayers
    );

    event AgentJoinedQueue(
        uint256 indexed matchId,
        address indexed agent,
        uint256 playerCount,
        uint256 poolTotal
    );

    event MatchStarted(uint256 indexed matchId, uint256 playerCount, uint256 pool);

    event AnswerSubmitted(
        uint256 indexed matchId,
        address indexed agent,
        string answer,
        uint256 attemptNumber,
        uint256 neuronBurned
    );

    event MatchSettled(
        uint256 indexed matchId,
        address indexed winner,
        uint256 winnerPrize,
        uint256 treasuryFee,
        uint256 burnAllocationAmount
    );

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        treasury = makeAddr("treasury");
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        player3 = makeAddr("player3");
        player4 = makeAddr("player4");

        // Deploy mock token
        neuron = new MockNeuronToken();

        // Deploy arena
        arena = new AxonArena(address(neuron), treasury, operator);

        // Fund players with MON
        vm.deal(player1, 100 ether);
        vm.deal(player2, 100 ether);
        vm.deal(player3, 100 ether);
        vm.deal(player4, 100 ether);

        // Fund players with NEURON and approve arena
        neuron.mint(player1, 100 ether);
        neuron.mint(player2, 100 ether);
        neuron.mint(player3, 100 ether);
        neuron.mint(player4, 100 ether);

        vm.prank(player1);
        neuron.approve(address(arena), type(uint256).max);
        vm.prank(player2);
        neuron.approve(address(arena), type(uint256).max);
        vm.prank(player3);
        neuron.approve(address(arena), type(uint256).max);
        vm.prank(player4);
        neuron.approve(address(arena), type(uint256).max);

        // Calculate answer hash
        answerHash = keccak256(abi.encodePacked(CORRECT_ANSWER, ANSWER_SALT));
    }

    // ============ Helper Functions ============

    function _createDefaultMatch() internal returns (uint256 matchId) {
        vm.prank(operator);
        matchId = arena.createMatch(
            ENTRY_FEE,
            BASE_ANSWER_FEE,
            QUEUE_DURATION,
            ANSWER_DURATION,
            MIN_PLAYERS,
            MAX_PLAYERS
        );
    }

    function _joinQueue(address player, uint256 matchId) internal {
        vm.prank(player);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
    }

    function _setupMatchToAnswerPeriod(uint256 matchId) internal {
        _joinQueue(player1, matchId);
        _joinQueue(player2, matchId);

        vm.prank(operator);
        arena.startMatch(matchId);

        vm.prank(operator);
        arena.postQuestion(matchId, "What is the answer?", "math", 3, "number", answerHash);

        vm.prank(operator);
        arena.startAnswerPeriod(matchId);
    }

    // ============ Queue Flow Tests (ax-1.5a) ============

    function test_createMatch_emitsEvent() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true);
        emit MatchCreated(1, ENTRY_FEE, BASE_ANSWER_FEE, uint64(block.timestamp) + QUEUE_DURATION, MIN_PLAYERS, MAX_PLAYERS);
        arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);
    }

    function test_createMatch_incrementsMatchId() public {
        vm.startPrank(operator);
        uint256 id1 = arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);
        uint256 id2 = arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_createMatch_revertsIfNotOperator() public {
        vm.prank(player1);
        vm.expectRevert(AxonArena.NotOperator.selector);
        arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);
    }

    function test_createMatch_revertsIfInvalidParams() public {
        vm.startPrank(operator);

        // Zero entry fee
        vm.expectRevert(AxonArena.InvalidParameters.selector);
        arena.createMatch(0, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);

        // Min players < 2
        vm.expectRevert(AxonArena.InvalidParameters.selector);
        arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, 1, MAX_PLAYERS);

        // Max < min players
        vm.expectRevert(AxonArena.InvalidParameters.selector);
        arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, 4, 2);

        vm.stopPrank();
    }

    function test_joinQueue_success() public {
        uint256 matchId = _createDefaultMatch();

        uint256 playerBalanceBefore = player1.balance;

        vm.prank(player1);
        vm.expectEmit(true, true, false, true);
        emit AgentJoinedQueue(matchId, player1, 1, ENTRY_FEE);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        assertEq(arena.getPlayerCount(matchId), 1);
        assertTrue(arena.isPlayerInMatch(matchId, player1));
        assertEq(player1.balance, playerBalanceBefore - ENTRY_FEE);
    }

    function test_joinQueue_multipleAgents() public {
        uint256 matchId = _createDefaultMatch();

        _joinQueue(player1, matchId);
        _joinQueue(player2, matchId);
        _joinQueue(player3, matchId);

        assertEq(arena.getPlayerCount(matchId), 3);
        assertTrue(arena.isPlayerInMatch(matchId, player1));
        assertTrue(arena.isPlayerInMatch(matchId, player2));
        assertTrue(arena.isPlayerInMatch(matchId, player3));

        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(state.pool, ENTRY_FEE * 3);
    }

    function test_joinQueue_refundsExcess() public {
        uint256 matchId = _createDefaultMatch();
        uint256 excessAmount = 0.5 ether;

        uint256 balanceBefore = player1.balance;

        vm.prank(player1);
        arena.joinQueue{value: ENTRY_FEE + excessAmount}(matchId);

        // Should only deduct entry fee
        assertEq(player1.balance, balanceBefore - ENTRY_FEE);
    }

    function test_joinQueue_revertsIfInsufficientFee() public {
        uint256 matchId = _createDefaultMatch();

        vm.prank(player1);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.InsufficientEntryFee.selector, ENTRY_FEE, ENTRY_FEE - 1));
        arena.joinQueue{value: ENTRY_FEE - 1}(matchId);
    }

    function test_joinQueue_revertsIfAlreadyJoined() public {
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);

        vm.prank(player1);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.AlreadyInMatch.selector, matchId, player1));
        arena.joinQueue{value: ENTRY_FEE}(matchId);
    }

    function test_joinQueue_revertsIfMatchFull() public {
        vm.prank(operator);
        uint256 matchId = arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, 2, 2);

        _joinQueue(player1, matchId);
        _joinQueue(player2, matchId);

        vm.prank(player3);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.MatchFull.selector, matchId));
        arena.joinQueue{value: ENTRY_FEE}(matchId);
    }

    function test_joinQueue_revertsAfterDeadline() public {
        uint256 matchId = _createDefaultMatch();

        // Fast forward past queue deadline
        vm.warp(block.timestamp + QUEUE_DURATION + 1);

        vm.prank(player1);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.QueueDeadlinePassed.selector, matchId));
        arena.joinQueue{value: ENTRY_FEE}(matchId);
    }

    function test_startMatch_success() public {
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);
        _joinQueue(player2, matchId);

        vm.prank(operator);
        vm.expectEmit(true, false, false, true);
        emit MatchStarted(matchId, 2, ENTRY_FEE * 2);
        arena.startMatch(matchId);

        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.QuestionRevealed));
    }

    function test_startMatch_revertsIfNotEnoughPlayers() public {
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.NotEnoughPlayers.selector, MIN_PLAYERS, 1));
        arena.startMatch(matchId);
    }

    // ============ Answer Flow Tests (ax-1.5b) ============

    function test_submitAnswer_burnsCorrectAmount() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        uint256 neuronBefore = neuron.balanceOf(player1);

        vm.prank(player1);
        arena.submitAnswer(matchId, "wrong answer");

        assertEq(neuron.balanceOf(player1), neuronBefore - BASE_ANSWER_FEE);
        assertEq(arena.answerAttempts(matchId, player1), 1);
    }

    function test_submitAnswer_feeDoubles() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        uint256 neuronBefore = neuron.balanceOf(player1);

        // First attempt: BASE_ANSWER_FEE (0.1 ether)
        vm.prank(player1);
        arena.submitAnswer(matchId, "attempt1");
        assertEq(neuron.balanceOf(player1), neuronBefore - BASE_ANSWER_FEE);

        // Second attempt: 2x (0.2 ether)
        vm.prank(player1);
        arena.submitAnswer(matchId, "attempt2");
        assertEq(neuron.balanceOf(player1), neuronBefore - BASE_ANSWER_FEE - (BASE_ANSWER_FEE * 2));

        // Third attempt: 4x (0.4 ether)
        vm.prank(player1);
        arena.submitAnswer(matchId, "attempt3");
        assertEq(neuron.balanceOf(player1), neuronBefore - BASE_ANSWER_FEE - (BASE_ANSWER_FEE * 2) - (BASE_ANSWER_FEE * 4));

        // Fourth attempt: 8x (0.8 ether)
        vm.prank(player1);
        arena.submitAnswer(matchId, "attempt4");
        uint256 totalBurned = BASE_ANSWER_FEE + (BASE_ANSWER_FEE * 2) + (BASE_ANSWER_FEE * 4) + (BASE_ANSWER_FEE * 8);
        assertEq(neuron.balanceOf(player1), neuronBefore - totalBurned);

        assertEq(arena.answerAttempts(matchId, player1), 4);
    }

    function test_submitAnswer_emitsEvents() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(player1);
        vm.expectEmit(true, true, false, true);
        emit AnswerSubmitted(matchId, player1, "test answer", 1, BASE_ANSWER_FEE);
        arena.submitAnswer(matchId, "test answer");
    }

    function test_submitAnswer_revertsBeforeAnswerPeriod() public {
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);
        _joinQueue(player2, matchId);

        vm.prank(operator);
        arena.startMatch(matchId);

        // Still in QuestionRevealed phase
        vm.prank(player1);
        vm.expectRevert(abi.encodeWithSelector(
            AxonArena.InvalidPhase.selector,
            AxonArena.MatchPhase.AnswerPeriod,
            AxonArena.MatchPhase.QuestionRevealed
        ));
        arena.submitAnswer(matchId, "answer");
    }

    function test_submitAnswer_revertsAfterDeadline() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        // Fast forward past answer deadline
        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        vm.prank(player1);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.AnswerDeadlinePassed.selector, matchId));
        arena.submitAnswer(matchId, "answer");
    }

    function test_submitAnswer_revertsIfNotInMatch() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(player3);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.NotInMatch.selector, matchId, player3));
        arena.submitAnswer(matchId, "answer");
    }

    function test_getCurrentAnswerFee_doublesCorrectly() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        assertEq(arena.getCurrentAnswerFee(matchId, player1), BASE_ANSWER_FEE);

        vm.prank(player1);
        arena.submitAnswer(matchId, "attempt1");
        assertEq(arena.getCurrentAnswerFee(matchId, player1), BASE_ANSWER_FEE * 2);

        vm.prank(player1);
        arena.submitAnswer(matchId, "attempt2");
        assertEq(arena.getCurrentAnswerFee(matchId, player1), BASE_ANSWER_FEE * 4);
    }

    // ============ Settlement Flow Tests (ax-1.5c) ============

    function test_settleWinner_distributesCorrectly() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        uint256 pool = ENTRY_FEE * 2;
        uint256 expectedWinnerPrize = (pool * 90) / 100;
        uint256 expectedTreasuryFee = (pool * 5) / 100;
        uint256 expectedBurnAllocation = pool - expectedWinnerPrize - expectedTreasuryFee;

        uint256 winnerBalanceBefore = player1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(operator);
        vm.expectEmit(true, true, false, true);
        emit MatchSettled(matchId, player1, expectedWinnerPrize, expectedTreasuryFee, expectedBurnAllocation);
        arena.settleWinner(matchId, player1);

        assertEq(player1.balance, winnerBalanceBefore + expectedWinnerPrize);
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);
        assertEq(arena.burnAllocation(player1), expectedBurnAllocation);

        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(state.winner, player1);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.Settled));
    }

    function test_settleWinner_revertsIfNotOperator() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(player1);
        vm.expectRevert(AxonArena.NotOperator.selector);
        arena.settleWinner(matchId, player1);
    }

    function test_settleWinner_revertsIfNotInMatch() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.NotInMatch.selector, matchId, player3));
        arena.settleWinner(matchId, player3);
    }

    function test_revealAnswer_success() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(operator);
        arena.settleWinner(matchId, player1);

        vm.prank(operator);
        arena.revealAnswer(matchId, CORRECT_ANSWER, ANSWER_SALT);

        assertEq(arena.revealedAnswers(matchId), CORRECT_ANSWER);
    }

    function test_revealAnswer_revertsIfHashMismatch() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(operator);
        arena.settleWinner(matchId, player1);

        vm.prank(operator);
        vm.expectRevert(AxonArena.InvalidAnswerHash.selector);
        arena.revealAnswer(matchId, "wrong answer", ANSWER_SALT);
    }

    function test_revealAnswer_revertsBeforeSettlement() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(
            AxonArena.InvalidPhase.selector,
            AxonArena.MatchPhase.Settled,
            AxonArena.MatchPhase.AnswerPeriod
        ));
        arena.revealAnswer(matchId, CORRECT_ANSWER, ANSWER_SALT);
    }

    function test_withdrawBurnAllocation_winnerCanWithdraw() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        // Settle with player1 as winner
        vm.prank(operator);
        arena.settleWinner(matchId, player1);

        uint256 allocation = arena.burnAllocation(player1);
        assertTrue(allocation > 0);

        // Player1 (non-operator) can now withdraw their own allocation
        uint256 balanceBefore = player1.balance;

        vm.prank(player1);
        arena.withdrawBurnAllocation();

        assertEq(player1.balance, balanceBefore + allocation);
        assertEq(arena.burnAllocation(player1), 0);
    }

    function test_withdrawBurnAllocation_revertsIfNone() public {
        vm.prank(player1);
        vm.expectRevert(AxonArena.NoBurnAllocation.selector);
        arena.withdrawBurnAllocation();
    }

    function test_claimBurnAllocationFor_operatorCanClaimForWinner() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        // Settle with player1 as winner
        vm.prank(operator);
        arena.settleWinner(matchId, player1);

        uint256 allocation = arena.burnAllocation(player1);
        assertTrue(allocation > 0);

        // Operator can claim player1's allocation for NEURON buyback swap
        uint256 operatorBalanceBefore = operator.balance;

        vm.prank(operator);
        arena.claimBurnAllocationFor(player1);

        assertEq(operator.balance, operatorBalanceBefore + allocation);
        assertEq(arena.burnAllocation(player1), 0);
    }

    function test_claimBurnAllocationFor_revertsIfNotOperator() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(operator);
        arena.settleWinner(matchId, player1);

        vm.prank(player2);
        vm.expectRevert(AxonArena.NotOperator.selector);
        arena.claimBurnAllocationFor(player1);
    }

    function test_claimBurnAllocationFor_revertsIfNone() public {
        vm.prank(operator);
        vm.expectRevert(AxonArena.NoBurnAllocation.selector);
        arena.claimBurnAllocationFor(player1);
    }

    // ============ Refund Flow Tests (ax-1.5d) ============

    function test_refundMatch_distributes95to5() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        uint256 pool = ENTRY_FEE * 2;
        uint256 expectedTreasuryFee = (pool * 5) / 100;
        uint256 expectedRefundPool = pool - expectedTreasuryFee;
        uint256 expectedRefundPerPlayer = expectedRefundPool / 2;

        // Fast forward past answer deadline
        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(operator);
        arena.refundMatch(matchId);

        // Treasury gets paid immediately
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);

        // Players have pending refunds (pull pattern)
        assertEq(arena.pendingRefunds(player1), expectedRefundPerPlayer);
        assertEq(arena.pendingRefunds(player2), expectedRefundPerPlayer);

        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.Refunded));

        // Players withdraw their refunds
        uint256 player1BalanceBefore = player1.balance;
        uint256 player2BalanceBefore = player2.balance;

        vm.prank(player1);
        arena.withdrawRefund();
        vm.prank(player2);
        arena.withdrawRefund();

        assertEq(player1.balance, player1BalanceBefore + expectedRefundPerPlayer);
        assertEq(player2.balance, player2BalanceBefore + expectedRefundPerPlayer);
        assertEq(arena.pendingRefunds(player1), 0);
        assertEq(arena.pendingRefunds(player2), 0);
    }

    function test_refundMatch_revertsBeforeDeadline() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.AnswerDeadlineNotPassed.selector, matchId));
        arena.refundMatch(matchId);
    }

    function test_cancelMatch_returns100percent() public {
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);

        // Fast forward past queue deadline
        vm.warp(block.timestamp + QUEUE_DURATION + 1);

        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(operator);
        arena.cancelMatch(matchId);

        // No treasury cut for cancelled queue
        assertEq(treasury.balance, treasuryBalanceBefore);

        // Player has pending refund (pull pattern)
        assertEq(arena.pendingRefunds(player1), ENTRY_FEE);

        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.Refunded));

        // Player withdraws refund
        uint256 player1BalanceBefore = player1.balance;
        vm.prank(player1);
        arena.withdrawRefund();

        assertEq(player1.balance, player1BalanceBefore + ENTRY_FEE);
        assertEq(arena.pendingRefunds(player1), 0);
    }

    function test_withdrawRefund_revertsIfNoPending() public {
        vm.prank(player1);
        vm.expectRevert(AxonArena.NoPendingRefund.selector);
        arena.withdrawRefund();
    }

    function test_cancelMatch_handlesZeroPlayers() public {
        uint256 matchId = _createDefaultMatch();

        // Fast forward past queue deadline
        vm.warp(block.timestamp + QUEUE_DURATION + 1);

        vm.prank(operator);
        arena.cancelMatch(matchId);

        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.Refunded));
    }

    function test_cancelMatch_revertsBeforeDeadline() public {
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AxonArena.QueueDeadlineNotPassed.selector, matchId));
        arena.cancelMatch(matchId);
    }

    function test_cancelMatch_revertsIfNotQueuePhase() public {
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);
        _joinQueue(player2, matchId);

        vm.prank(operator);
        arena.startMatch(matchId);

        // Now in QuestionRevealed phase
        vm.warp(block.timestamp + QUEUE_DURATION + 1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(
            AxonArena.InvalidPhase.selector,
            AxonArena.MatchPhase.Queue,
            AxonArena.MatchPhase.QuestionRevealed
        ));
        arena.cancelMatch(matchId);
    }

    // ============ Admin Tests ============

    function test_addOperator_success() public {
        address newOperator = makeAddr("newOperator");

        arena.addOperator(newOperator);

        assertTrue(arena.isOperator(newOperator));
    }

    function test_addOperator_revertsIfNotOwner() public {
        vm.prank(player1);
        vm.expectRevert();
        arena.addOperator(player1);
    }

    function test_addOperator_revertsIfAlreadyOperator() public {
        // operator is already added in constructor
        vm.expectRevert(AxonArena.InvalidParameters.selector);
        arena.addOperator(operator);
    }

    function test_removeOperator_success() public {
        assertTrue(arena.isOperator(operator));

        arena.removeOperator(operator);

        assertFalse(arena.isOperator(operator));
    }

    function test_removeOperator_revertsIfNotOwner() public {
        vm.prank(player1);
        vm.expectRevert();
        arena.removeOperator(operator);
    }

    function test_removeOperator_revertsIfNotOperator() public {
        address notOperator = makeAddr("notOperator");

        vm.expectRevert(AxonArena.InvalidParameters.selector);
        arena.removeOperator(notOperator);
    }

    function test_multipleOperators_canManageMatches() public {
        address operator2 = makeAddr("operator2");
        address operator3 = makeAddr("operator3");

        // Add more operators
        arena.addOperator(operator2);
        arena.addOperator(operator3);

        // All operators can create matches
        vm.prank(operator);
        uint256 matchId1 = arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);

        vm.prank(operator2);
        uint256 matchId2 = arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);

        vm.prank(operator3);
        uint256 matchId3 = arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);

        assertEq(matchId1, 1);
        assertEq(matchId2, 2);
        assertEq(matchId3, 3);
    }

    function test_setTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");

        arena.setTreasury(newTreasury);

        assertEq(arena.treasury(), newTreasury);
    }

    // ============ View Function Tests ============

    function test_getMatchPlayers() public {
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);
        _joinQueue(player2, matchId);

        address[] memory players = arena.getMatchPlayers(matchId);

        assertEq(players.length, 2);
        assertEq(players[0], player1);
        assertEq(players[1], player2);
    }

    function test_getMatchConfig() public {
        uint256 matchId = _createDefaultMatch();

        AxonArena.MatchConfig memory config = arena.getMatchConfig(matchId);

        assertEq(config.entryFee, ENTRY_FEE);
        assertEq(config.baseAnswerFee, BASE_ANSWER_FEE);
        assertEq(config.minPlayers, MIN_PLAYERS);
        assertEq(config.maxPlayers, MAX_PLAYERS);
    }

    // ============ Full Lifecycle Integration Tests (ax-1.5e) ============

    /**
     * @notice Test complete happy path: create -> join -> start -> question -> answer -> settle -> reveal
     */
    function test_fullLifecycle_happyPath() public {
        // Step 1: Create match
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE,
            BASE_ANSWER_FEE,
            QUEUE_DURATION,
            ANSWER_DURATION,
            MIN_PLAYERS,
            MAX_PLAYERS
        );

        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.Queue));

        // Step 2: Multiple players join queue
        vm.prank(player1);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        vm.prank(player2);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        vm.prank(player3);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        assertEq(arena.getPlayerCount(matchId), 3);
        state = arena.getMatchState(matchId);
        assertEq(state.pool, ENTRY_FEE * 3);

        // Step 3: Start match
        vm.prank(operator);
        arena.startMatch(matchId);

        state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.QuestionRevealed));

        // Step 4: Post question
        vm.prank(operator);
        arena.postQuestion(matchId, "What is 6 * 7?", "math", 1, "number", answerHash);

        state = arena.getMatchState(matchId);
        assertEq(state.answerHash, answerHash);
        assertEq(state.difficulty, 1);

        AxonArena.MatchQuestion memory question = arena.getMatchQuestion(matchId);
        assertEq(question.questionText, "What is 6 * 7?");
        assertEq(question.category, "math");
        assertEq(question.formatHint, "number");

        // Step 5: Start answer period
        vm.prank(operator);
        arena.startAnswerPeriod(matchId);

        state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.AnswerPeriod));
        assertTrue(state.answerDeadline > block.timestamp);

        // Step 6: Players submit answers (with NEURON burns)
        uint256 player1NeuronBefore = neuron.balanceOf(player1);
        uint256 player2NeuronBefore = neuron.balanceOf(player2);

        // Player 2 submits wrong answer
        vm.prank(player2);
        arena.submitAnswer(matchId, "41");

        // Player 1 submits correct answer
        vm.prank(player1);
        arena.submitAnswer(matchId, CORRECT_ANSWER);

        // Verify burns
        assertEq(neuron.balanceOf(player1), player1NeuronBefore - BASE_ANSWER_FEE);
        assertEq(neuron.balanceOf(player2), player2NeuronBefore - BASE_ANSWER_FEE);
        assertEq(arena.matchBurnTotal(matchId), BASE_ANSWER_FEE * 2);

        // Step 7: Settle winner
        uint256 pool = ENTRY_FEE * 3;
        uint256 expectedWinnerPrize = (pool * 90) / 100;
        uint256 expectedTreasuryFee = (pool * 5) / 100;

        uint256 player1BalanceBefore = player1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(operator);
        arena.settleWinner(matchId, player1);

        state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.Settled));
        assertEq(state.winner, player1);

        assertEq(player1.balance, player1BalanceBefore + expectedWinnerPrize);
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);

        // Step 8: Reveal answer
        vm.prank(operator);
        arena.revealAnswer(matchId, CORRECT_ANSWER, ANSWER_SALT);

        assertEq(arena.revealedAnswers(matchId), CORRECT_ANSWER);
    }

    /**
     * @notice Test timeout path: create -> join -> start -> question -> answer period -> timeout -> refund
     */
    function test_fullLifecycle_timeoutPath() public {
        // Create and setup match
        uint256 matchId = _createDefaultMatch();
        _joinQueue(player1, matchId);
        _joinQueue(player2, matchId);

        vm.prank(operator);
        arena.startMatch(matchId);

        vm.prank(operator);
        arena.postQuestion(matchId, "Hard question", "crypto", 5, "text", answerHash);

        vm.prank(operator);
        arena.startAnswerPeriod(matchId);

        // Players submit wrong answers
        vm.prank(player1);
        arena.submitAnswer(matchId, "wrong1");

        vm.prank(player2);
        arena.submitAnswer(matchId, "wrong2");

        // Fast forward past answer deadline
        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        uint256 treasuryBalanceBefore = treasury.balance;

        uint256 pool = ENTRY_FEE * 2;
        uint256 expectedTreasuryFee = (pool * 5) / 100;
        uint256 expectedRefundPool = pool - expectedTreasuryFee;
        uint256 expectedRefundPerPlayer = expectedRefundPool / 2;

        // Refund match
        vm.prank(operator);
        arena.refundMatch(matchId);

        // Verify state
        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.Refunded));

        // Verify treasury paid immediately
        assertEq(treasury.balance, treasuryBalanceBefore + expectedTreasuryFee);

        // Verify pending refunds (pull pattern)
        assertEq(arena.pendingRefunds(player1), expectedRefundPerPlayer);
        assertEq(arena.pendingRefunds(player2), expectedRefundPerPlayer);

        // Players withdraw their refunds
        uint256 player1BalanceBefore = player1.balance;
        uint256 player2BalanceBefore = player2.balance;

        vm.prank(player1);
        arena.withdrawRefund();
        vm.prank(player2);
        arena.withdrawRefund();

        assertEq(player1.balance, player1BalanceBefore + expectedRefundPerPlayer);
        assertEq(player2.balance, player2BalanceBefore + expectedRefundPerPlayer);
    }

    /**
     * @notice Test cancel path: create -> join (not enough) -> queue deadline -> cancel
     */
    function test_fullLifecycle_cancelPath() public {
        // Create match
        uint256 matchId = _createDefaultMatch();

        // Only one player joins (not enough for minPlayers=2)
        vm.prank(player1);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        assertEq(arena.getPlayerCount(matchId), 1);

        // Fast forward past queue deadline
        vm.warp(block.timestamp + QUEUE_DURATION + 1);

        // Cancel match
        vm.prank(operator);
        arena.cancelMatch(matchId);

        // Verify state
        AxonArena.MatchState memory state = arena.getMatchState(matchId);
        assertEq(uint8(state.phase), uint8(AxonArena.MatchPhase.Refunded));

        // Verify pending refund (pull pattern, full refund, no treasury cut)
        assertEq(arena.pendingRefunds(player1), ENTRY_FEE);

        // Player withdraws
        uint256 player1BalanceBefore = player1.balance;
        vm.prank(player1);
        arena.withdrawRefund();

        assertEq(player1.balance, player1BalanceBefore + ENTRY_FEE);
    }

    /**
     * @notice Test multiple answer attempts with doubling fee
     */
    function test_fullLifecycle_multipleAttempts() public {
        uint256 matchId = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId);

        uint256 neuronBefore = neuron.balanceOf(player1);

        // Submit 4 answers with doubling fees
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(player1);
            arena.submitAnswer(matchId, string(abi.encodePacked("attempt", i)));
        }

        // Total burned: 0.1 + 0.2 + 0.4 + 0.8 = 1.5 ether
        uint256 expectedTotalBurn = BASE_ANSWER_FEE * (1 + 2 + 4 + 8);
        assertEq(neuron.balanceOf(player1), neuronBefore - expectedTotalBurn);
        assertEq(arena.answerAttempts(matchId, player1), 4);
        assertEq(arena.matchBurnTotal(matchId), expectedTotalBurn);
    }

    /**
     * @notice Test that multiple matches can run independently
     */
    function test_fullLifecycle_multipleMatches() public {
        // Create two matches
        vm.startPrank(operator);
        uint256 matchId1 = arena.createMatch(ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);
        uint256 matchId2 = arena.createMatch(ENTRY_FEE * 2, BASE_ANSWER_FEE * 2, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS);
        vm.stopPrank();

        // Players join different matches
        vm.prank(player1);
        arena.joinQueue{value: ENTRY_FEE}(matchId1);
        vm.prank(player2);
        arena.joinQueue{value: ENTRY_FEE}(matchId1);

        vm.prank(player3);
        arena.joinQueue{value: ENTRY_FEE * 2}(matchId2);
        vm.prank(player4);
        arena.joinQueue{value: ENTRY_FEE * 2}(matchId2);

        // Verify independent state
        assertEq(arena.getPlayerCount(matchId1), 2);
        assertEq(arena.getPlayerCount(matchId2), 2);

        AxonArena.MatchState memory state1 = arena.getMatchState(matchId1);
        AxonArena.MatchState memory state2 = arena.getMatchState(matchId2);

        assertEq(state1.pool, ENTRY_FEE * 2);
        assertEq(state2.pool, ENTRY_FEE * 4);

        // Start both matches
        vm.startPrank(operator);
        arena.startMatch(matchId1);
        arena.startMatch(matchId2);
        vm.stopPrank();

        state1 = arena.getMatchState(matchId1);
        state2 = arena.getMatchState(matchId2);

        assertEq(uint8(state1.phase), uint8(AxonArena.MatchPhase.QuestionRevealed));
        assertEq(uint8(state2.phase), uint8(AxonArena.MatchPhase.QuestionRevealed));
    }

    /**
     * @notice Test burn allocation accumulates across multiple wins
     */
    function test_fullLifecycle_burnAllocationAccumulates() public {
        // First match
        uint256 matchId1 = _createDefaultMatch();
        _setupMatchToAnswerPeriod(matchId1);

        vm.prank(operator);
        arena.settleWinner(matchId1, player1);

        uint256 allocation1 = arena.burnAllocation(player1);
        assertTrue(allocation1 > 0);

        // Second match
        uint256 matchId2 = _createDefaultMatch();
        _joinQueue(player1, matchId2);
        _joinQueue(player3, matchId2);

        vm.prank(operator);
        arena.startMatch(matchId2);

        vm.prank(operator);
        arena.postQuestion(matchId2, "Question 2", "crypto", 2, "number", answerHash);

        vm.prank(operator);
        arena.startAnswerPeriod(matchId2);

        vm.prank(operator);
        arena.settleWinner(matchId2, player1);

        uint256 allocation2 = arena.burnAllocation(player1);
        assertTrue(allocation2 > allocation1, "Burn allocation should accumulate");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AxonArena.sol";
import "./mocks/MockNeuronToken.sol";

/**
 * @title GasAnalysis
 * @notice Dedicated gas measurement tests for AxonArena operations
 * @dev Run with: forge test --match-contract GasAnalysis --gas-report -vvv
 *
 * This test suite measures gas costs for all operator-called functions
 * to determine operational costs per match.
 */
contract GasAnalysisTest is Test {
    AxonArena public arena;
    MockNeuronToken public neuron;

    address public owner;
    address public operator;
    address public treasury;
    address[] public players;

    uint256 public constant ENTRY_FEE = 0.1 ether;
    uint256 public constant BASE_ANSWER_FEE = 1 ether; // 1 NEURON
    uint64 public constant QUEUE_DURATION = 300; // 5 minutes
    uint64 public constant ANSWER_DURATION = 180; // 3 minutes
    uint8 public constant MIN_PLAYERS = 2;
    uint8 public constant MAX_PLAYERS = 8;

    bytes32 public constant ANSWER_SALT = keccak256("test_salt_123");
    string public constant CORRECT_ANSWER = "42";
    bytes32 public answerHash;

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        treasury = makeAddr("treasury");

        // Create 8 players for max player tests
        for (uint256 i = 0; i < 8; i++) {
            address player = makeAddr(string(abi.encodePacked("player", i)));
            players.push(player);
            vm.deal(player, 100 ether);
        }

        // Deploy mock token
        neuron = new MockNeuronToken();

        // Deploy arena
        arena = new AxonArena(address(neuron), treasury, operator);

        // Fund and approve NEURON for all players
        for (uint256 i = 0; i < players.length; i++) {
            neuron.mint(players[i], 100 ether);
            vm.prank(players[i]);
            neuron.approve(address(arena), type(uint256).max);
        }

        // Calculate answer hash
        answerHash = keccak256(abi.encodePacked(CORRECT_ANSWER, ANSWER_SALT));
    }

    // ============ Operator Operation Gas Tests ============

    /**
     * @notice Measure gas for createMatch
     * @dev This is called once per match by operator
     */
    function test_gas_createMatch() public {
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.createMatch(
            ENTRY_FEE,
            BASE_ANSWER_FEE,
            QUEUE_DURATION,
            ANSWER_DURATION,
            MIN_PLAYERS,
            MAX_PLAYERS
        );
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("createMatch gas", gasUsed);
    }

    /**
     * @notice Measure gas for startMatch
     * @dev Called by operator after queue has enough players
     */
    function test_gas_startMatch() public {
        // Setup: create match and add players
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );

        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        // Measure startMatch
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.startMatch(matchId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("startMatch gas (2 players)", gasUsed);
    }

    /**
     * @notice Measure gas for postQuestion with typical question length
     * @dev String length affects gas - testing with realistic question
     */
    function test_gas_postQuestion_short() public {
        // Setup
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);

        // Measure postQuestion (short question ~50 chars)
        string memory question = "What is the square root of 144?";
        string memory category = "math";
        string memory formatHint = "number";

        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.postQuestion(matchId, question, category, 2, formatHint, answerHash);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("postQuestion gas (short ~50 chars)", gasUsed);
    }

    /**
     * @notice Measure gas for postQuestion with long question
     * @dev Tests upper bound of question gas cost
     */
    function test_gas_postQuestion_long() public {
        // Setup
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);

        // Measure postQuestion (long question ~300 chars)
        string memory question = "In the context of decentralized finance and blockchain technology, what is the maximum theoretical transactions per second (TPS) that Monad blockchain claims to achieve through its parallel execution engine and optimistic concurrency?";
        string memory category = "crypto";
        string memory formatHint = "number";

        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.postQuestion(matchId, question, category, 4, formatHint, answerHash);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("postQuestion gas (long ~250 chars)", gasUsed);
    }

    /**
     * @notice Measure gas for startAnswerPeriod
     */
    function test_gas_startAnswerPeriod() public {
        // Setup
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);
        vm.prank(operator);
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);

        // Measure startAnswerPeriod
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.startAnswerPeriod(matchId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("startAnswerPeriod gas", gasUsed);
    }

    /**
     * @notice Measure gas for settleWinner
     * @dev Includes MON transfers to winner and treasury
     */
    function test_gas_settleWinner() public {
        // Setup full match to answer period
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);
        vm.prank(operator);
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);
        vm.prank(operator);
        arena.startAnswerPeriod(matchId);

        // Measure settleWinner
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.settleWinner(matchId, players[0]);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("settleWinner gas (2 players)", gasUsed);
    }

    /**
     * @notice Measure gas for revealAnswer
     */
    function test_gas_revealAnswer() public {
        // Setup and settle match
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);
        vm.prank(operator);
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);
        vm.prank(operator);
        arena.startAnswerPeriod(matchId);
        vm.prank(operator);
        arena.settleWinner(matchId, players[0]);

        // Measure revealAnswer
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.revealAnswer(matchId, CORRECT_ANSWER, ANSWER_SALT);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("revealAnswer gas", gasUsed);
    }

    /**
     * @notice Measure gas for refundMatch with 2 players
     */
    function test_gas_refundMatch_2players() public {
        // Setup match to answer period then timeout
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);
        vm.prank(operator);
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);
        vm.prank(operator);
        arena.startAnswerPeriod(matchId);

        // Fast forward past deadline
        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        // Measure refundMatch
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.refundMatch(matchId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("refundMatch gas (2 players)", gasUsed);
    }

    /**
     * @notice Measure gas for refundMatch with 8 players (max)
     * @dev Tests upper bound gas cost
     */
    function test_gas_refundMatch_8players() public {
        // Setup match with 8 players
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );

        // All 8 players join
        for (uint256 i = 0; i < 8; i++) {
            vm.prank(players[i]);
            arena.joinQueue{value: ENTRY_FEE}(matchId);
        }

        vm.prank(operator);
        arena.startMatch(matchId);
        vm.prank(operator);
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);
        vm.prank(operator);
        arena.startAnswerPeriod(matchId);

        // Fast forward past deadline
        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        // Measure refundMatch
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.refundMatch(matchId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("refundMatch gas (8 players)", gasUsed);
    }

    /**
     * @notice Measure gas for cancelMatch with 1 player
     */
    function test_gas_cancelMatch_1player() public {
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );

        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        // Fast forward past queue deadline
        vm.warp(block.timestamp + QUEUE_DURATION + 1);

        // Measure cancelMatch
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.cancelMatch(matchId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("cancelMatch gas (1 player)", gasUsed);
    }

    // ============ Agent Operation Gas Tests ============

    /**
     * @notice Measure gas for joinQueue
     */
    function test_gas_joinQueue() public {
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );

        // Measure joinQueue
        vm.prank(players[0]);
        uint256 gasBefore = gasleft();
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("joinQueue gas", gasUsed);
    }

    /**
     * @notice Measure gas for submitAnswer (first attempt)
     */
    function test_gas_submitAnswer_first() public {
        // Setup to answer period
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);
        vm.prank(operator);
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);
        vm.prank(operator);
        arena.startAnswerPeriod(matchId);

        // Measure submitAnswer
        vm.prank(players[0]);
        uint256 gasBefore = gasleft();
        arena.submitAnswer(matchId, "test answer");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("submitAnswer gas (first)", gasUsed);
    }

    /**
     * @notice Measure gas for submitAnswer (subsequent attempts - storage already warm)
     */
    function test_gas_submitAnswer_subsequent() public {
        // Setup to answer period
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);
        vm.prank(operator);
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);
        vm.prank(operator);
        arena.startAnswerPeriod(matchId);

        // First attempt to warm storage
        vm.prank(players[0]);
        arena.submitAnswer(matchId, "attempt 1");

        // Measure second attempt
        vm.prank(players[0]);
        uint256 gasBefore = gasleft();
        arena.submitAnswer(matchId, "attempt 2");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("submitAnswer gas (subsequent)", gasUsed);
    }

    /**
     * @notice Measure gas for claimBurnAllocationFor (operator claiming for winner)
     */
    function test_gas_claimBurnAllocationFor() public {
        // Setup and settle match
        vm.prank(operator);
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(operator);
        arena.startMatch(matchId);
        vm.prank(operator);
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);
        vm.prank(operator);
        arena.startAnswerPeriod(matchId);
        vm.prank(operator);
        arena.settleWinner(matchId, players[0]);

        // Measure claimBurnAllocationFor
        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.claimBurnAllocationFor(players[0]);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("claimBurnAllocationFor gas", gasUsed);
    }

    // ============ Full Match Cycle Gas Summary ============

    /**
     * @notice Measure total operator gas for happy path match (2 players)
     * @dev createMatch + startMatch + postQuestion + startAnswerPeriod + settleWinner + revealAnswer
     */
    function test_gas_fullCycle_happyPath_2players() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        // createMatch
        vm.prank(operator);
        gasBefore = gasleft();
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        totalGas += gasBefore - gasleft();

        // Players join (not operator gas, but needed for flow)
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        // startMatch
        vm.prank(operator);
        gasBefore = gasleft();
        arena.startMatch(matchId);
        totalGas += gasBefore - gasleft();

        // postQuestion
        vm.prank(operator);
        gasBefore = gasleft();
        arena.postQuestion(matchId, "What is the answer to life?", "trivia", 3, "number", answerHash);
        totalGas += gasBefore - gasleft();

        // startAnswerPeriod
        vm.prank(operator);
        gasBefore = gasleft();
        arena.startAnswerPeriod(matchId);
        totalGas += gasBefore - gasleft();

        // settleWinner
        vm.prank(operator);
        gasBefore = gasleft();
        arena.settleWinner(matchId, players[0]);
        totalGas += gasBefore - gasleft();

        // revealAnswer
        vm.prank(operator);
        gasBefore = gasleft();
        arena.revealAnswer(matchId, CORRECT_ANSWER, ANSWER_SALT);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL operator gas (happy path, 2 players)", totalGas);
    }

    /**
     * @notice Measure total operator gas for timeout path (2 players)
     * @dev createMatch + startMatch + postQuestion + startAnswerPeriod + refundMatch
     */
    function test_gas_fullCycle_timeoutPath_2players() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        // createMatch
        vm.prank(operator);
        gasBefore = gasleft();
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        totalGas += gasBefore - gasleft();

        // Players join
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        // startMatch
        vm.prank(operator);
        gasBefore = gasleft();
        arena.startMatch(matchId);
        totalGas += gasBefore - gasleft();

        // postQuestion
        vm.prank(operator);
        gasBefore = gasleft();
        arena.postQuestion(matchId, "Hard question nobody answers", "crypto", 5, "text", answerHash);
        totalGas += gasBefore - gasleft();

        // startAnswerPeriod
        vm.prank(operator);
        gasBefore = gasleft();
        arena.startAnswerPeriod(matchId);
        totalGas += gasBefore - gasleft();

        // Wait for timeout
        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        // refundMatch
        vm.prank(operator);
        gasBefore = gasleft();
        arena.refundMatch(matchId);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL operator gas (timeout path, 2 players)", totalGas);
    }

    /**
     * @notice Measure total operator gas for cancel path (1 player)
     * @dev createMatch + cancelMatch (no startMatch because not enough players)
     */
    function test_gas_fullCycle_cancelPath_1player() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        // createMatch
        vm.prank(operator);
        gasBefore = gasleft();
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        totalGas += gasBefore - gasleft();

        // Only 1 player joins
        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        // Wait for queue timeout
        vm.warp(block.timestamp + QUEUE_DURATION + 1);

        // cancelMatch
        vm.prank(operator);
        gasBefore = gasleft();
        arena.cancelMatch(matchId);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL operator gas (cancel path, 1 player)", totalGas);
    }

    /**
     * @notice Measure gas for happy path with burn allocation claim
     * @dev Full cycle + claimBurnAllocationFor
     */
    function test_gas_fullCycle_withBurnClaim() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        // Full happy path
        vm.prank(operator);
        gasBefore = gasleft();
        uint256 matchId = arena.createMatch(
            ENTRY_FEE, BASE_ANSWER_FEE, QUEUE_DURATION, ANSWER_DURATION, MIN_PLAYERS, MAX_PLAYERS
        );
        totalGas += gasBefore - gasleft();

        vm.prank(players[0]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);
        vm.prank(players[1]);
        arena.joinQueue{value: ENTRY_FEE}(matchId);

        vm.prank(operator);
        gasBefore = gasleft();
        arena.startMatch(matchId);
        totalGas += gasBefore - gasleft();

        vm.prank(operator);
        gasBefore = gasleft();
        arena.postQuestion(matchId, "Test question", "test", 1, "text", answerHash);
        totalGas += gasBefore - gasleft();

        vm.prank(operator);
        gasBefore = gasleft();
        arena.startAnswerPeriod(matchId);
        totalGas += gasBefore - gasleft();

        vm.prank(operator);
        gasBefore = gasleft();
        arena.settleWinner(matchId, players[0]);
        totalGas += gasBefore - gasleft();

        vm.prank(operator);
        gasBefore = gasleft();
        arena.revealAnswer(matchId, CORRECT_ANSWER, ANSWER_SALT);
        totalGas += gasBefore - gasleft();

        // Claim burn allocation for swap
        vm.prank(operator);
        gasBefore = gasleft();
        arena.claimBurnAllocationFor(players[0]);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL operator gas (happy path + burn claim)", totalGas);
    }
}

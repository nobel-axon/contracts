// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BountyArena.sol";
import "./mocks/MockNeuronToken.sol";
import "./mocks/MockIdentityRegistry.sol";
import "./mocks/MockReputationRegistry.sol";

/**
 * @title BountyGasAnalysis
 * @notice Dedicated gas measurement tests for BountyArena operations
 * @dev Run with: forge test --match-contract BountyGasAnalysis --gas-report -vvv
 */
contract BountyGasAnalysisTest is Test {
    BountyArena public arena;
    MockNeuronToken public neuron;
    MockIdentityRegistry public identity;
    MockReputationRegistry public reputation;

    address public owner;
    address public operator;
    address public treasury;
    address public creator;
    address[] public agents;
    uint256[] public agentIds;

    uint256 public constant BOUNTY_REWARD = 5 ether;
    uint256 public constant BASE_ANSWER_FEE = 0.1 ether;
    uint64 public constant JOIN_DURATION = 300;
    uint64 public constant ANSWER_DURATION = 180;
    uint8 public constant MAX_AGENTS = 8;

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        vm.deal(creator, 100 ether);

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

        // Create 8 agents
        for (uint256 i = 0; i < 8; i++) {
            address agent = makeAddr(string(abi.encodePacked("agent", i)));
            agents.push(agent);
            vm.deal(agent, 100 ether);
            neuron.mint(agent, 100 ether);
            vm.prank(agent);
            neuron.approve(address(arena), type(uint256).max);

            vm.prank(agent);
            uint256 agentId = identity.register("");
            agentIds.push(agentId);
            // setSummary(agentId, count, summaryValue, summaryValueDecimals)
            reputation.setSummary(agentId, 10, 100, 0);
        }
    }

    function test_gas_createBounty() public {
        vm.prank(creator);
        uint256 gasBefore = gasleft();
        arena.createBounty{value: BOUNTY_REWARD}(
            "What is the best consensus algorithm?",
            int128(0),
            "crypto",
            3,
            JOIN_DURATION,
            ANSWER_DURATION,
            MAX_AGENTS
        );
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("createBounty gas", gasUsed);
    }

    function test_gas_joinBounty() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Test question", int128(0), "test", 1, JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.joinBounty(bountyId, agentIds[0]);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("joinBounty gas", gasUsed);
    }

    function test_gas_joinBounty_withRatingGate() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Test question", int128(5), "test", 1, JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.joinBounty(bountyId, agentIds[0]);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("joinBounty gas (with rating gate)", gasUsed);
    }

    function test_gas_startBountyAnswerPeriod() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Test question", int128(0), "test", 1, JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );

        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.startBountyAnswerPeriod(bountyId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("startBountyAnswerPeriod gas", gasUsed);
    }

    function test_gas_submitBountyAnswer_first() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Test question", int128(0), "test", 1, JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);
        vm.prank(operator);
        arena.startBountyAnswerPeriod(bountyId);

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.submitBountyAnswer(bountyId, "test answer");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("submitBountyAnswer gas (first)", gasUsed);
    }

    function test_gas_submitBountyAnswer_subsequent() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Test question", int128(0), "test", 1, JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);
        vm.prank(operator);
        arena.startBountyAnswerPeriod(bountyId);

        vm.prank(agents[0]);
        arena.submitBountyAnswer(bountyId, "attempt 1");

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.submitBountyAnswer(bountyId, "attempt 2");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("submitBountyAnswer gas (subsequent)", gasUsed);
    }

    function test_gas_settleBounty() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Test question", int128(0), "test", 1, JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);
        vm.prank(operator);
        arena.startBountyAnswerPeriod(bountyId);

        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.settleBounty(bountyId, agents[0]);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("settleBounty gas", gasUsed);
    }

    function test_gas_expireBounty() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Test question", int128(0), "test", 1, JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );

        vm.warp(block.timestamp + JOIN_DURATION + 1);

        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.expireBounty(bountyId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("expireBounty gas", gasUsed);
    }

    function test_gas_refundBounty() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Test question", int128(0), "test", 1, JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);
        vm.prank(operator);
        arena.startBountyAnswerPeriod(bountyId);

        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        vm.prank(operator);
        uint256 gasBefore = gasleft();
        arena.refundBounty(bountyId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("refundBounty gas", gasUsed);
    }

    function test_gas_fullCycle_happyPath() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        vm.prank(creator);
        gasBefore = gasleft();
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "What is the best consensus algorithm?", int128(0), "crypto", 3,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
        totalGas += gasBefore - gasleft();

        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(operator);
        gasBefore = gasleft();
        arena.startBountyAnswerPeriod(bountyId);
        totalGas += gasBefore - gasleft();

        vm.prank(operator);
        gasBefore = gasleft();
        arena.settleBounty(bountyId, agents[0]);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL operator gas (bounty happy path)", totalGas);
    }

    function test_gas_fullCycle_refundPath() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        vm.prank(creator);
        gasBefore = gasleft();
        uint256 bountyId = arena.createBounty{value: BOUNTY_REWARD}(
            "Hard question nobody answers", int128(0), "crypto", 5,
            JOIN_DURATION, ANSWER_DURATION, MAX_AGENTS
        );
        totalGas += gasBefore - gasleft();

        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(operator);
        gasBefore = gasleft();
        arena.startBountyAnswerPeriod(bountyId);
        totalGas += gasBefore - gasleft();

        vm.warp(block.timestamp + ANSWER_DURATION + 1);

        vm.prank(operator);
        gasBefore = gasleft();
        arena.refundBounty(bountyId);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL operator gas (bounty refund path)", totalGas);
    }
}

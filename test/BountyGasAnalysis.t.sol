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
    address public creator;
    address[] public agents;
    uint256[] public agentIds;

    uint256 public constant BOUNTY_REWARD = 5 ether;
    uint256 public constant BASE_ANSWER_FEE = 0.1 ether;
    uint64 public constant DURATION = 300;
    uint8 public constant MAX_AGENTS = 8;

    function setUp() public {
        owner = address(this);
        creator = makeAddr("creator");

        // Deploy mocks
        neuron = new MockNeuronToken();
        identity = new MockIdentityRegistry();
        reputation = new MockReputationRegistry();

        // Deploy arena (3 args)
        arena = new BountyArena(
            address(neuron),
            address(reputation),
            address(identity)
        );

        // Fund creator with NEURON
        neuron.mint(creator, 1000 ether);
        vm.prank(creator);
        neuron.approve(address(arena), type(uint256).max);

        // Create 8 agents
        for (uint256 i = 0; i < 8; i++) {
            address agent = makeAddr(string(abi.encodePacked("agent", i)));
            agents.push(agent);
            vm.deal(agent, 10 ether);
            neuron.mint(agent, 100 ether);
            vm.prank(agent);
            neuron.approve(address(arena), type(uint256).max);

            vm.prank(agent);
            uint256 agentId = identity.register("");
            agentIds.push(agentId);
            reputation.setSummary(agentId, 10, 100, 0);
        }
    }

    function test_gas_createBounty() public {
        vm.prank(creator);
        uint256 gasBefore = gasleft();
        arena.createBounty(
            "What is the best consensus algorithm?",
            int128(0),
            "crypto",
            3,
            DURATION,
            MAX_AGENTS,
            BOUNTY_REWARD,
            BASE_ANSWER_FEE
        );
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("createBounty gas", gasUsed);
    }

    function test_gas_joinBounty() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "Test question", int128(0), "test", 1, DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.joinBounty(bountyId, agentIds[0]);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("joinBounty gas (with reputation snapshot)", gasUsed);
    }

    function test_gas_joinBounty_withRatingGate() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "Test question", int128(5), "test", 1, DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.joinBounty(bountyId, agentIds[0]);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("joinBounty gas (with rating gate)", gasUsed);
    }

    function test_gas_submitBountyAnswer_first() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "Test question", int128(0), "test", 1, DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.submitBountyAnswer(bountyId, "test answer");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("submitBountyAnswer gas (first)", gasUsed);
    }

    function test_gas_submitBountyAnswer_subsequent() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "Test question", int128(0), "test", 1, DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(agents[0]);
        arena.submitBountyAnswer(bountyId, "attempt 1");

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.submitBountyAnswer(bountyId, "attempt 2");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("submitBountyAnswer gas (subsequent)", gasUsed);
    }

    function test_gas_pickWinner() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "Test question", int128(0), "test", 1, DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(agents[0]);
        arena.submitBountyAnswer(bountyId, "answer");

        vm.prank(creator);
        uint256 gasBefore = gasleft();
        arena.pickWinner(bountyId, agents[0]);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("pickWinner gas", gasUsed);
    }

    function test_gas_claimWinnerReward() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "Test question", int128(0), "test", 1, DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[0]);
        arena.submitBountyAnswer(bountyId, "answer");

        vm.prank(creator);
        arena.pickWinner(bountyId, agents[0]);

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.claimWinnerReward(bountyId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("claimWinnerReward gas", gasUsed);
    }

    function test_gas_claimProportional() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "Test question", int128(0), "test", 1, DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(agents[0]);
        arena.submitBountyAnswer(bountyId, "answer1");
        vm.prank(agents[1]);
        arena.submitBountyAnswer(bountyId, "answer2");

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(agents[0]);
        uint256 gasBefore = gasleft();
        arena.claimProportional(bountyId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("claimProportional gas", gasUsed);
    }

    function test_gas_claimRefund() public {
        vm.prank(creator);
        uint256 bountyId = arena.createBounty(
            "Test question", int128(0), "test", 1, DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(creator);
        uint256 gasBefore = gasleft();
        arena.claimRefund(bountyId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("claimRefund gas", gasUsed);
    }

    function test_gas_fullCycle_happyPath() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        vm.prank(creator);
        gasBefore = gasleft();
        uint256 bountyId = arena.createBounty(
            "What is the best consensus algorithm?", int128(0), "crypto", 3,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        totalGas += gasBefore - gasleft();

        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(agents[0]);
        arena.submitBountyAnswer(bountyId, "answer");

        vm.prank(creator);
        gasBefore = gasleft();
        arena.pickWinner(bountyId, agents[0]);
        totalGas += gasBefore - gasleft();

        vm.prank(agents[0]);
        gasBefore = gasleft();
        arena.claimWinnerReward(bountyId);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL gas (bounty happy path: create+pick+claim)", totalGas);
    }

    function test_gas_fullCycle_proportionalPath() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        vm.prank(creator);
        gasBefore = gasleft();
        uint256 bountyId = arena.createBounty(
            "Hard question", int128(0), "crypto", 5,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        totalGas += gasBefore - gasleft();

        vm.prank(agents[0]);
        arena.joinBounty(bountyId, agentIds[0]);
        vm.prank(agents[1]);
        arena.joinBounty(bountyId, agentIds[1]);

        vm.prank(agents[0]);
        arena.submitBountyAnswer(bountyId, "answer1");
        vm.prank(agents[1]);
        arena.submitBountyAnswer(bountyId, "answer2");

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(agents[0]);
        gasBefore = gasleft();
        arena.claimProportional(bountyId);
        totalGas += gasBefore - gasleft();

        vm.prank(agents[1]);
        gasBefore = gasleft();
        arena.claimProportional(bountyId);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL gas (bounty proportional path: create+2xclaim)", totalGas);
    }

    function test_gas_fullCycle_refundPath() public {
        uint256 totalGas = 0;
        uint256 gasBefore;

        vm.prank(creator);
        gasBefore = gasleft();
        uint256 bountyId = arena.createBounty(
            "Nobody will answer this", int128(0), "crypto", 5,
            DURATION, MAX_AGENTS, BOUNTY_REWARD, BASE_ANSWER_FEE
        );
        totalGas += gasBefore - gasleft();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(creator);
        gasBefore = gasleft();
        arena.claimRefund(bountyId);
        totalGas += gasBefore - gasleft();

        emit log_named_uint("TOTAL gas (bounty refund path: create+refund)", totalGas);
    }
}

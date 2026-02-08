// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AxonArena.sol";
import "../test/mocks/MockNeuronToken.sol";

/**
 * @title Deploy Script for AxonArena
 * @notice Deploys AxonArena to Monad testnet or mainnet
 *
 * Usage:
 *   # Deploy to testnet with mock NEURON token (for testing)
 *   forge script script/Deploy.s.sol:DeployTestnet --rpc-url $MONAD_TESTNET_RPC_URL --broadcast --verify
 *
 *   # Deploy to testnet with existing NEURON token
 *   NEURON_TOKEN_ADDRESS=0x... forge script script/Deploy.s.sol:DeployWithToken --rpc-url $MONAD_TESTNET_RPC_URL --broadcast --verify
 *
 *   # Deploy to mainnet
 *   NEURON_TOKEN_ADDRESS=0x... forge script script/Deploy.s.sol:DeployWithToken --rpc-url $MONAD_MAINNET_RPC_URL --broadcast --verify
 */
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        address initialOperator = vm.envOr("OPERATOR_ADDRESS", deployer);

        console.log("Deployer (Owner):", deployer);
        console.log("Treasury:", treasury);
        console.log("Initial Operator (Agent Chief):", initialOperator);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock NEURON token for testnet
        MockNeuronToken neuronToken = new MockNeuronToken();
        console.log("MockNeuronToken deployed at:", address(neuronToken));

        // Deploy AxonArena with initial operator
        // Owner (deployer) can add/remove operators later via addOperator()/removeOperator()
        AxonArena arena = new AxonArena(
            address(neuronToken),
            treasury,
            initialOperator
        );
        console.log("AxonArena deployed at:", address(arena));

        // Mint NEURON to deployer and operator for testing
        neuronToken.mint(deployer, 1_000_000 * 10 ** 18);
        console.log("Minted 1,000,000 NEURON to deployer");

        if (initialOperator != deployer) {
            neuronToken.mint(initialOperator, 1_000_000 * 10 ** 18);
            console.log("Minted 1,000,000 NEURON to operator");
        }

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("Owner (can add/remove operators):", deployer);
        console.log("MockNeuronToken:", address(neuronToken));
        console.log("AxonArena:", address(arena));
        console.log("Treasury:", treasury);
        console.log("Initial Operator:", initialOperator);
        console.log("\nTo add more operators, owner calls: arena.addOperator(address)");
    }
}

contract DeployWithToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address neuronToken = vm.envAddress("NEURON_TOKEN_ADDRESS");
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        address operator = vm.envOr("OPERATOR_ADDRESS", deployer);

        require(neuronToken != address(0), "NEURON_TOKEN_ADDRESS not set");

        console.log("Deployer:", deployer);
        console.log("NEURON Token:", neuronToken);
        console.log("Treasury:", treasury);
        console.log("Operator:", operator);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy AxonArena with existing NEURON token
        AxonArena arena = new AxonArena(
            neuronToken,
            treasury,
            operator
        );
        console.log("AxonArena deployed at:", address(arena));

        vm.stopBroadcast();

        // Log summary
        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("NeuronToken:", neuronToken);
        console.log("AxonArena:", address(arena));
        console.log("Treasury:", treasury);
        console.log("Operator:", operator);
    }
}

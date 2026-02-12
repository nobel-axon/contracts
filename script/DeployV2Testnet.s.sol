// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/BountyArena.sol";

/**
 * @title Monad Testnet V2 Deployment Script
 * @author AXON Team
 * @notice Deploys BountyArena to Monad testnet
 *
 * Usage:
 *   source .env.testnet && forge script script/DeployV2Testnet.s.sol:DeployV2Testnet \
 *     --rpc-url $MONAD_TESTNET_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployV2Testnet is Script {
    uint256 constant MONAD_TESTNET_CHAIN_ID = 10143;

    function run() external {
        // ============ Safety Check: Chain ID ============
        require(
            block.chainid == MONAD_TESTNET_CHAIN_ID,
            string(abi.encodePacked(
                "SAFETY: Wrong chain! Expected Monad testnet (",
                vm.toString(MONAD_TESTNET_CHAIN_ID),
                ") but got chain ID ",
                vm.toString(block.chainid)
            ))
        );

        // ============ Load Configuration ============
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address neuronToken = vm.envAddress("NEURON_TOKEN_ADDRESS");
        address reputationRegistry = vm.envAddress("REPUTATION_REGISTRY_ADDRESS");
        address identityRegistry = vm.envAddress("IDENTITY_REGISTRY_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        console.log("");
        console.log("=== V2 Testnet Deployment ===");
        console.log("Chain: Monad Testnet (Chain ID 10143)");
        console.log("Deployer:", deployer);
        console.log("NEURON Token:", neuronToken);
        console.log("Reputation Registry:", reputationRegistry);
        console.log("Identity Registry:", identityRegistry);
        console.log("Treasury:", treasury);
        console.log("Operator:", operator);
        console.log("");

        // ============ Deploy ============
        vm.startBroadcast(deployerPrivateKey);

        BountyArena bountyArena = new BountyArena(
            neuronToken,
            reputationRegistry,
            identityRegistry,
            treasury,
            operator
        );

        vm.stopBroadcast();

        // ============ Summary ============
        console.log("========================================");
        console.log("  V2 TESTNET DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("");
        console.log("BountyArena:", address(bountyArena));
        console.log("");
        console.log("Update .env.testnet:");
        console.log("BOUNTY_ARENA_ADDRESS=", address(bountyArena));
        console.log("");
    }
}

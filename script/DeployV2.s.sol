// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/BountyArena.sol";
import "../src/interfaces/INeuronToken.sol";

/**
 * @title Monad Mainnet V2 Deployment Script
 * @author AXON Team
 * @notice Deploys BountyArena to Monad mainnet with safety checks
 *
 * Prerequisites:
 * 1. NEURON token must already exist on mainnet
 * 2. Identity and Reputation registries must already be deployed
 * 3. All environment variables must be set in .env.mainnet
 * 4. Contracts must pass all tests: forge test
 *
 * Usage:
 *   # Step 1: Dry-run simulation
 *   source .env.mainnet && forge script script/DeployV2.s.sol:DeployV2 \
 *     --rpc-url $MONAD_MAINNET_RPC_URL \
 *     -vvvv
 *
 *   # Step 2: Actual deployment
 *   source .env.mainnet && V2_DEPLOYMENT_CONFIRMED=true forge script script/DeployV2.s.sol:DeployV2 \
 *     --rpc-url $MONAD_MAINNET_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployV2 is Script {
    uint256 constant MONAD_MAINNET_CHAIN_ID = 143;
    uint256 constant MIN_DEPLOYER_BALANCE = 0.1 ether;

    struct DeploymentConfig {
        address deployer;
        address neuronToken;
        address reputationRegistry;
        address identityRegistry;
        address treasury;
        address operator;
        uint256 deployerBalance;
    }

    function run() external {
        // ============ Safety Check 1: Chain ID ============
        require(
            block.chainid == MONAD_MAINNET_CHAIN_ID,
            string(abi.encodePacked(
                "SAFETY: Wrong chain! Expected Monad mainnet (",
                vm.toString(MONAD_MAINNET_CHAIN_ID),
                ") but got chain ID ",
                vm.toString(block.chainid)
            ))
        );

        // ============ Safety Check 2: Confirmation Flag ============
        bool isConfirmed = vm.envOr("V2_DEPLOYMENT_CONFIRMED", false);
        if (!isConfirmed) {
            console.log("");
            console.log("========================================");
            console.log("     V2 MAINNET DEPLOYMENT DRY-RUN      ");
            console.log("========================================");
            console.log("");
            console.log("This is a SIMULATION only. No transactions will be sent.");
            console.log("To execute, set: V2_DEPLOYMENT_CONFIRMED=true");
            console.log("");
        }

        // ============ Load Configuration ============
        DeploymentConfig memory config = _loadConfig();

        // ============ Safety Check 3: Critical Addresses ============
        require(config.neuronToken != address(0), "SAFETY: NEURON_TOKEN_ADDRESS not set");
        require(config.reputationRegistry != address(0), "SAFETY: REPUTATION_REGISTRY_ADDRESS not set");
        require(config.identityRegistry != address(0), "SAFETY: IDENTITY_REGISTRY_ADDRESS not set");
        require(config.treasury != address(0), "SAFETY: TREASURY_ADDRESS not set");
        require(config.operator != address(0), "SAFETY: OPERATOR_ADDRESS not set");

        // ============ Safety Check 4: Verify Contracts Exist ============
        _verifyContractExists(config.neuronToken, "NEURON Token");
        _verifyContractExists(config.reputationRegistry, "Reputation Registry");
        _verifyContractExists(config.identityRegistry, "Identity Registry");

        // ============ Safety Check 5: Deployer Balance ============
        require(
            config.deployerBalance >= MIN_DEPLOYER_BALANCE,
            "SAFETY: Insufficient deployer balance for gas"
        );

        // ============ Print Configuration ============
        _printConfig(config);

        if (isConfirmed) {
            console.log("");
            console.log("!!! V2 MAINNET DEPLOYMENT CONFIRMED !!!");
            console.log("Proceeding with actual deployment...");
            console.log("");
        }

        // ============ Execute Deployment ============
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        BountyArena bountyArena = new BountyArena(
            config.neuronToken,
            config.reputationRegistry,
            config.identityRegistry,
            config.treasury,
            config.operator
        );

        vm.stopBroadcast();

        // ============ Post-Deployment Verification ============
        _verifyDeployment(address(bountyArena), config);

        // ============ Print Summary ============
        _printSummary(address(bountyArena), config);
    }

    function _loadConfig() internal view returns (DeploymentConfig memory config) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        config.deployer = vm.addr(deployerPrivateKey);
        config.neuronToken = vm.envAddress("NEURON_TOKEN_ADDRESS");
        config.reputationRegistry = vm.envAddress("REPUTATION_REGISTRY_ADDRESS");
        config.identityRegistry = vm.envAddress("IDENTITY_REGISTRY_ADDRESS");
        config.treasury = vm.envAddress("TREASURY_ADDRESS");
        config.operator = vm.envAddress("OPERATOR_ADDRESS");
        config.deployerBalance = config.deployer.balance;
    }

    function _verifyContractExists(address addr, string memory name) internal view {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(addr)
        }
        require(
            codeSize > 0,
            string(abi.encodePacked("SAFETY: ", name, " contract does not exist at specified address"))
        );
        console.log(string(abi.encodePacked("[OK] ", name, " contract verified at:")), addr);
    }

    function _verifyDeployment(address bountyArena, DeploymentConfig memory config) internal view {
        console.log("");
        console.log("=== Post-Deployment Verification ===");

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(bountyArena)
        }
        require(codeSize > 0, "FATAL: BountyArena contract not deployed");
        console.log("[OK] BountyArena contract deployed");

        BountyArena ba = BountyArena(bountyArena);

        require(address(ba.neuronToken()) == config.neuronToken, "FATAL: NEURON token address mismatch");
        console.log("[OK] NEURON token address correct");

        require(address(ba.reputationRegistry()) == config.reputationRegistry, "FATAL: Reputation registry mismatch");
        console.log("[OK] Reputation registry address correct");

        require(address(ba.identityRegistry()) == config.identityRegistry, "FATAL: Identity registry mismatch");
        console.log("[OK] Identity registry address correct");

        require(ba.treasury() == config.treasury, "FATAL: Treasury address mismatch");
        console.log("[OK] Treasury address correct");

        require(ba.operators(config.operator), "FATAL: Operator not set correctly");
        console.log("[OK] Operator address correct");

        require(ba.owner() == config.deployer, "FATAL: Owner not set correctly");
        console.log("[OK] Owner address correct");

        // Verify split
        require(ba.winnerBps() == 8500, "FATAL: Winner BPS mismatch");
        require(ba.treasuryBps() == 1000, "FATAL: Treasury BPS mismatch");
        require(ba.burnBps() == 500, "FATAL: Burn BPS mismatch");
        console.log("[OK] Default split correct (85/10/5)");

        console.log("");
        console.log("All post-deployment checks passed!");
    }

    function _printConfig(DeploymentConfig memory config) internal pure {
        console.log("");
        console.log("=== V2 Deployment Configuration ===");
        console.log("Chain: Monad Mainnet (Chain ID 143)");
        console.log("");
        console.log("Deployer (Owner):", config.deployer);
        console.log("Deployer Balance:", config.deployerBalance / 1e18, "MON");
        console.log("");
        console.log("NEURON Token:", config.neuronToken);
        console.log("Reputation Registry:", config.reputationRegistry);
        console.log("Identity Registry:", config.identityRegistry);
        console.log("Treasury:", config.treasury);
        console.log("Initial Operator:", config.operator);
        console.log("");
    }

    function _printSummary(address bountyArena, DeploymentConfig memory config) internal pure {
        console.log("");
        console.log("========================================");
        console.log("     V2 MAINNET DEPLOYMENT COMPLETE     ");
        console.log("========================================");
        console.log("");
        console.log("BountyArena deployed at:", bountyArena);
        console.log("");
        console.log("=== Update .env.mainnet ===");
        console.log("BOUNTY_ARENA_ADDRESS=", bountyArena);
        console.log("");
        console.log("=== Roles ===");
        console.log("Owner (can add/remove operators):", config.deployer);
        console.log("Operator (can manage bounties):", config.operator);
        console.log("Treasury (receives 10% fees):", config.treasury);
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Verify contract on explorer (if --verify failed)");
        console.log("2. Update all service configs with new address");
        console.log("3. Add additional operators if needed");
        console.log("4. Test with a small bounty before full launch");
        console.log("");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AxonArena.sol";
import "../src/interfaces/INeuronToken.sol";

/**
 * @title Monad Mainnet Deployment Script for AXON
 * @author AXON Team
 * @notice Deploys AxonArena to Monad mainnet with safety checks
 *
 * IMPORTANT: This script includes multiple safety checks to prevent accidental mainnet deployment.
 *
 * Prerequisites:
 * 1. NEURON token must already exist on mainnet (launched via nad.fun)
 * 2. All environment variables must be set in .env.mainnet
 * 3. Contracts must pass all tests: forge test
 * 4. Dry-run simulation must succeed first
 *
 * Usage:
 *   # Step 1: Dry-run simulation (no gas spent)
 *   source .env.mainnet && forge script script/DeployMainnet.s.sol:DeployMainnet \
 *     --rpc-url $MONAD_MAINNET_RPC_URL \
 *     -vvvv
 *
 *   # Step 2: Actual deployment (spends real MON)
 *   source .env.mainnet && MAINNET_DEPLOYMENT_CONFIRMED=true forge script script/DeployMainnet.s.sol:DeployMainnet \
 *     --rpc-url $MONAD_MAINNET_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 *   # Step 3: Verify contracts manually (if --verify failed)
 *   forge verify-contract <AXON_ARENA_ADDRESS> AxonArena \
 *     --rpc-url $MONAD_MAINNET_RPC_URL \
 *     --constructor-args $(cast abi-encode "constructor(address,address,address)" \
 *       $NEURON_TOKEN_ADDRESS $TREASURY_ADDRESS $OPERATOR_ADDRESS)
 */
contract DeployMainnet is Script {
    // ============ Safety Constants ============

    /// @notice Expected Monad mainnet chain ID
    uint256 constant MONAD_MAINNET_CHAIN_ID = 143;

    /// @notice Minimum deployer balance required (0.1 MON for gas buffer)
    uint256 constant MIN_DEPLOYER_BALANCE = 0.1 ether;

    // ============ Deployment Configuration ============

    struct DeploymentConfig {
        address deployer;
        address neuronToken;
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
        bool isConfirmed = vm.envOr("MAINNET_DEPLOYMENT_CONFIRMED", false);
        if (!isConfirmed) {
            console.log("");
            console.log("========================================");
            console.log("       MAINNET DEPLOYMENT DRY-RUN       ");
            console.log("========================================");
            console.log("");
            console.log("This is a SIMULATION only. No transactions will be sent.");
            console.log("");
            console.log("To execute the actual deployment, set:");
            console.log("  MAINNET_DEPLOYMENT_CONFIRMED=true");
            console.log("");
        }

        // ============ Load Configuration ============
        DeploymentConfig memory config = _loadConfig();

        // ============ Safety Check 3: Critical Addresses ============
        require(config.neuronToken != address(0), "SAFETY: NEURON_TOKEN_ADDRESS not set");
        require(config.treasury != address(0), "SAFETY: TREASURY_ADDRESS not set");
        require(config.operator != address(0), "SAFETY: OPERATOR_ADDRESS not set");

        // ============ Safety Check 4: Verify NEURON Token Exists ============
        _verifyNeuronToken(config.neuronToken);

        // ============ Safety Check 5: Deployer Balance ============
        require(
            config.deployerBalance >= MIN_DEPLOYER_BALANCE,
            string(abi.encodePacked(
                "SAFETY: Insufficient deployer balance. Need at least ",
                vm.toString(MIN_DEPLOYER_BALANCE / 1e18),
                " MON for gas"
            ))
        );

        // ============ Print Configuration ============
        _printConfig(config);

        // ============ Safety Check 6: Final Confirmation ============
        if (isConfirmed) {
            console.log("");
            console.log("!!! MAINNET DEPLOYMENT CONFIRMED !!!");
            console.log("Proceeding with actual deployment...");
            console.log("");
        }

        // ============ Execute Deployment ============
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        AxonArena arena = new AxonArena(
            config.neuronToken,
            config.treasury,
            config.operator
        );

        vm.stopBroadcast();

        // ============ Post-Deployment Verification ============
        _verifyDeployment(address(arena), config);

        // ============ Print Summary ============
        _printSummary(address(arena), config);
    }

    function _loadConfig() internal view returns (DeploymentConfig memory config) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        config.deployer = vm.addr(deployerPrivateKey);
        config.neuronToken = vm.envAddress("NEURON_TOKEN_ADDRESS");
        config.treasury = vm.envAddress("TREASURY_ADDRESS");
        config.operator = vm.envAddress("OPERATOR_ADDRESS");
        config.deployerBalance = config.deployer.balance;
    }

    function _verifyNeuronToken(address neuronToken) internal view {
        // Check if contract exists at address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(neuronToken)
        }
        require(codeSize > 0, "SAFETY: NEURON token contract does not exist at specified address");

        // Try to call a view function to verify it's the right contract
        try INeuronToken(neuronToken).totalSupply() returns (uint256 supply) {
            require(supply > 0, "SAFETY: NEURON token has zero supply - verify correct address");
            console.log("NEURON Token verified:");
            console.log("  - Total Supply:", supply / 1e18, "NEURON");
        } catch {
            revert("SAFETY: Failed to call NEURON token - is this the correct address?");
        }

        // Verify token name/symbol if possible
        try INeuronToken(neuronToken).symbol() returns (string memory symbol) {
            console.log("  - Symbol:", symbol);
        } catch {}
    }

    function _verifyDeployment(address arena, DeploymentConfig memory config) internal view {
        console.log("");
        console.log("=== Post-Deployment Verification ===");

        // Verify contract was deployed
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(arena)
        }
        require(codeSize > 0, "FATAL: AxonArena contract not deployed");
        console.log("[OK] AxonArena contract deployed");

        // Verify constructor parameters
        AxonArena arenaContract = AxonArena(arena);

        require(
            address(arenaContract.neuronToken()) == config.neuronToken,
            "FATAL: NEURON token address mismatch"
        );
        console.log("[OK] NEURON token address correct");

        require(
            arenaContract.treasury() == config.treasury,
            "FATAL: Treasury address mismatch"
        );
        console.log("[OK] Treasury address correct");

        require(
            arenaContract.operators(config.operator),
            "FATAL: Operator not set correctly"
        );
        console.log("[OK] Operator address correct");

        require(
            arenaContract.owner() == config.deployer,
            "FATAL: Owner not set correctly"
        );
        console.log("[OK] Owner address correct");

        console.log("");
        console.log("All post-deployment checks passed!");
    }

    function _printConfig(DeploymentConfig memory config) internal pure {
        console.log("");
        console.log("=== Deployment Configuration ===");
        console.log("Chain: Monad Mainnet (Chain ID 143)");
        console.log("");
        console.log("Deployer (Owner):", config.deployer);
        console.log("Deployer Balance:", config.deployerBalance / 1e18, "MON");
        console.log("");
        console.log("NEURON Token:", config.neuronToken);
        console.log("Treasury:", config.treasury);
        console.log("Initial Operator:", config.operator);
        console.log("");
    }

    function _printSummary(address arena, DeploymentConfig memory config) internal pure {
        console.log("");
        console.log("========================================");
        console.log("       MAINNET DEPLOYMENT COMPLETE      ");
        console.log("========================================");
        console.log("");
        console.log("AxonArena deployed at:", arena);
        console.log("");
        console.log("=== Update .env.mainnet ===");
        console.log("AXON_ARENA_ADDRESS=", arena);
        console.log("");
        console.log("=== Roles ===");
        console.log("Owner (can add/remove operators):", config.deployer);
        console.log("Operator (can manage matches):", config.operator);
        console.log("Treasury (receives 5% fees):", config.treasury);
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Verify contract on explorer (if --verify failed)");
        console.log("2. Update all service configs with new address");
        console.log("3. Add additional operators if needed:");
        console.log("   cast send", arena, "'addOperator(address)' <NEW_OPERATOR>");
        console.log("4. Test with a small match before full launch");
        console.log("");
    }
}

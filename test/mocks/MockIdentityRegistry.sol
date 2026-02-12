// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IIdentityRegistry.sol";

/**
 * @title MockIdentityRegistry
 * @notice Mock ERC-8004 identity registry for testing (matches real register() signature)
 */
contract MockIdentityRegistry is IIdentityRegistry {
    uint256 public nextAgentId = 1;

    mapping(uint256 => address) public agentIdToOwner;

    function register(string memory) external returns (uint256 agentId) {
        agentId = nextAgentId++;
        agentIdToOwner[agentId] = msg.sender;
        emit Registered(agentId, "", msg.sender);
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return agentIdToOwner[agentId];
    }

    function getAgentWallet(uint256 agentId) external view returns (address) {
        return agentIdToOwner[agentId];
    }

    function setAgentWallet(uint256, address, uint256, bytes calldata) external {
        // no-op in mock
    }
}

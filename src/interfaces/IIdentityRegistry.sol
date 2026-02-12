// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IIdentityRegistry
 * @notice ERC-8004 Identity Registry interface (matches deployed IdentityRegistryUpgradeable on Monad)
 * @dev Minimal interface — only functions we call from BountyArena + Chief
 */
interface IIdentityRegistry {
    /// @notice Register caller as a new agent identity
    /// @param agentURI Metadata URI for the agent
    /// @return agentId The newly minted agent NFT ID
    function register(string memory agentURI) external returns (uint256 agentId);

    /// @notice Get the owner (registrant) of a given agent ID (ERC-721)
    /// @param agentId The agent ID to look up
    /// @return The address that owns this agent ID
    function ownerOf(uint256 agentId) external view returns (address);

    /// @notice Get the verified wallet address for an agent
    /// @param agentId The agent ID to look up
    /// @return The verified wallet address
    function getAgentWallet(uint256 agentId) external view returns (address);

    /// @notice Set a verified wallet for an agent (requires EIP-712/1271 signature)
    /// @param agentId The agent ID
    /// @param newWallet The wallet address to verify
    /// @param deadline Signature expiry timestamp
    /// @param signature EIP-712 or EIP-1271 signature proving wallet control
    function setAgentWallet(
        uint256 agentId,
        address newWallet,
        uint256 deadline,
        bytes calldata signature
    ) external;

    // ============ Events ============

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
}

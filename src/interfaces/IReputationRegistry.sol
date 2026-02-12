// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReputationRegistry
 * @notice ERC-8004 Reputation Registry interface (matches deployed ReputationRegistryUpgradeable on Monad)
 * @dev Minimal interface — only functions we call from BountyArena + Chief
 */
interface IReputationRegistry {
    /// @notice Submit feedback for an agent
    /// @param agentId The agent ID to give feedback to
    /// @param value The feedback value (positive or negative)
    /// @param valueDecimals Decimal precision of value
    /// @param tag1 Primary tag (e.g. "accuracy", "speed")
    /// @param tag2 Secondary tag (e.g. "bounty", "match")
    /// @param endpoint Endpoint identifier (can be empty)
    /// @param feedbackURI URI to detailed feedback (can be empty)
    /// @param feedbackHash Hash of feedback content (can be zero)
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    /// @notice Get reputation summary for an agent
    /// @param agentId The agent ID to query
    /// @param clientAddresses Array of client addresses to filter by (empty = all)
    /// @param tag1 Primary tag filter (empty = all)
    /// @param tag2 Secondary tag filter (empty = all)
    /// @return count Number of matching feedback entries
    /// @return summaryValue Aggregated feedback value
    /// @return summaryValueDecimals Decimal precision of summaryValue
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);

    // ============ Events ============

    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        int128 value,
        uint8 valueDecimals,
        string indexed indexedTag1,
        string tag1,
        string tag2,
        string endpoint,
        string feedbackURI,
        bytes32 feedbackHash
    );
}

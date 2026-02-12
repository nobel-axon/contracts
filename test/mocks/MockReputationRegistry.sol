// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IReputationRegistry.sol";

/**
 * @title MockReputationRegistry
 * @notice Mock ERC-8004 reputation registry for testing with configurable returns
 */
contract MockReputationRegistry is IReputationRegistry {
    struct MockSummary {
        uint64 count;
        int128 summaryValue;
        uint8 summaryValueDecimals;
    }

    /// @notice Configurable reputation summaries per agent ID
    mapping(uint256 => MockSummary) public agentSummaries;

    /// @notice Set the reputation summary for an agent (test helper)
    function setSummary(
        uint256 agentId,
        uint64 count,
        int128 summaryValue,
        uint8 summaryValueDecimals
    ) external {
        agentSummaries[agentId] = MockSummary({
            count: count,
            summaryValue: summaryValue,
            summaryValueDecimals: summaryValueDecimals
        });
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata,
        string calldata,
        bytes32
    ) external {
        MockSummary storage summary = agentSummaries[agentId];
        summary.count += 1;
        // Simple accumulation for mock
        summary.summaryValue += value;
        summary.summaryValueDecimals = valueDecimals;

        emit NewFeedback(agentId, msg.sender, summary.count - 1, value, valueDecimals, tag1, tag1, tag2, "", "", bytes32(0));
    }

    function getSummary(
        uint256 agentId,
        address[] calldata,
        string calldata,
        string calldata
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals) {
        MockSummary memory s = agentSummaries[agentId];
        return (s.count, s.summaryValue, s.summaryValueDecimals);
    }
}

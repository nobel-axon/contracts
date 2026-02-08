// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title INeuronToken
 * @notice Interface for $NEURON token launched via nad.fun on Monad
 * @dev Based on nad.fun IToken.json ABI - tokens support native burn()
 *
 * Research source: https://github.com/Naddotfun/contract-v3-abi
 */
interface INeuronToken {
    // ============ ERC20 Standard ============

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    // ============ Burn Functions ============

    /**
     * @notice Burns tokens from caller's balance
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external;

    /**
     * @notice Burns tokens from specified account (requires approval)
     * @param account Address to burn tokens from
     * @param amount Amount of tokens to burn
     * @dev Caller must have allowance >= amount from account
     */
    function burnFrom(address account, uint256 amount) external;

    // ============ EIP-2612 Permit ============

    /**
     * @notice Approve via signature (gasless approval)
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    // ============ Events ============

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

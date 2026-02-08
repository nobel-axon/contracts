// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title MockNeuronToken
 * @notice Mock ERC20 token for testing that mimics nad.fun token behavior
 */
contract MockNeuronToken is ERC20, ERC20Burnable {
    constructor() ERC20("Neuron Token", "NEURON") {
        // Mint initial supply for testing
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    /**
     * @notice Mint tokens to an address (for testing)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice burnFrom implementation matching nad.fun behavior
     * @dev Requires prior approval
     */
    function burnFrom(address account, uint256 amount) public override {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }
}

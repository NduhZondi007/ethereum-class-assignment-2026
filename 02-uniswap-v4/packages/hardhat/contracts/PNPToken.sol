// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Re-using the same PNPToken from Assignment 1.
// OpenZeppelin ERC20 handles all standard token logic.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// PNP loyalty points token. In this assignment, 1 PNPT = R0.01.
// The exchange rate with FNBT is: 1 FNBT = 10 PNPT.
contract PNPToken is ERC20 {
    // Mint the full initial supply to the deployer on construction.
    // No additional minting is possible after deployment.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}

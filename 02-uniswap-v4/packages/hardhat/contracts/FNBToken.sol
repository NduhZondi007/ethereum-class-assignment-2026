// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Re-using the same FNBToken from Assignment 1.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// FNB eBucks token. In this assignment, 1 FNBT = R0.10.
// The exchange rate with PNPT is: 1 FNBT = 10 PNPT.
contract FNBToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// I'm importing OpenZeppelin's ERC20 base contract so I don't have to
// write all the standard token logic from scratch. OZ handles balances,
// allowances, transfer logic, and events for me.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// PNPToken represents PnP loyalty points on-chain.
// In the assignment scenario, 1 PNPT = R0.01 (100 points per Rand).
// We inherit all standard ERC20 functionality from OpenZeppelin.
contract PNPToken is ERC20 {
    // The constructor runs once when the contract is deployed.
    // We pass the name and symbol to the parent ERC20 constructor,
    // then mint the full initial supply to whoever deploys the contract.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        // _mint is an internal OZ function that creates new tokens and
        // assigns them to the deployer's address. This is the only time
        // tokens are created — no further minting is allowed.
        _mint(msg.sender, initialSupply);
    }

    // All standard ERC20 functions (transfer, approve, transferFrom,
    // balanceOf, allowance, totalSupply, name, symbol, decimals) are
    // inherited from OZ's ERC20 — no need to implement them here.
    // OZ uses 18 decimals by default, matching Ether's precision.
}

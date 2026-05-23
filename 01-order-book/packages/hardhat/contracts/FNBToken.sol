// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Same approach as PNPToken — using OZ's battle-tested ERC20 implementation.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// FNBToken represents FNB eBucks on-chain.
// In the assignment scenario, 1 FNBT = R0.10 (10 eBucks per Rand).
// The exchange rate used in the DEX is 1 FNBT = 10 PNPT.
contract FNBToken is ERC20 {
    // Deploy with a fixed initial supply minted to the deployer.
    // The deployer (owner) can then distribute tokens to test accounts.
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        // Mint entire supply to deployer. No inflation possible after deploy.
        _mint(msg.sender, initialSupply);
    }

    // All ERC20 standard functionality comes from OZ:
    // - transfer(to, amount): move tokens from caller to recipient
    // - approve(spender, amount): allow spender to use your tokens
    // - transferFrom(from, to, amount): move tokens on behalf of 'from'
    // - balanceOf(account): check token balance
    // - allowance(owner, spender): check approved amount
    // Events Transfer and Approval are also emitted automatically by OZ.
}

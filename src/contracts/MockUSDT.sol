// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract MockUSDT is ERC20 {

    mapping(address => uint) lastClaim;

    constructor() ERC20("NAV TOken", "NAVT") {
        _mint(msg.sender, 1_000_000e18); // give deployer some tokens
    }

    
    /// @notice Faucet: Each wallet can claim 1000 mUSDT once every 24 hours
    function faucet() external {
        require(
            block.timestamp - lastClaim[msg.sender] > 1 days,
            "Faucet: wait 24h before next claim"
        );
        lastClaim[msg.sender] = block.timestamp;

        _mint(msg.sender, 1000e18); // mint directly to the caller
    }
}
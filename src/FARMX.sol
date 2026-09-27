// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply Sepolia demonstration token. No privileged roles or further minting.
contract FARMX is ERC20 {
    constructor() ERC20("Farm", "FARMX") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

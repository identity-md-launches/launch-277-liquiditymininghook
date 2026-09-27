// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Proposed manifest inputs, also consumed by the offline factory-shape rehearsal.
/// @dev The supplied workflow contains no numeric price or seed allocation; these are explicit assumptions.
library LaunchParameters {
    uint256 internal constant CHAIN_ID = 11155111;
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    uint160 internal constant SQRT_PRICE_X96 = 79228162514264337593543950336;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant SEED_TICK_LOWER = -887220;
    int24 internal constant SEED_TICK_UPPER = 0;
    uint128 internal constant SEED_LIQUIDITY = 100_000_000 ether;
}

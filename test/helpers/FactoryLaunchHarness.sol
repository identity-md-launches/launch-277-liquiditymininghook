// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FARMX} from "../../src/FARMX.sol";
import {LiquidityMiningHook} from "../../src/LiquidityMiningHook.sol";
import {LaunchParameters} from "../../script/LaunchParameters.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Offline factory-shape fixture, not the production factory. Owns the seed directly in
/// PoolManager and performs deployment, initialization and token-only settlement in one call.
contract FactoryLaunchHarness is IUnlockCallback {
    IPoolManager public immutable manager;
    FARMX public token;
    LiquidityMiningHook public hook;
    PoolKey private key;
    uint256 public initialFactoryBalance;
    BalanceDelta public seedDelta;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function launch(bytes32 salt) external returns (FARMX, LiquidityMiningHook, PoolKey memory) {
        require(address(token) == address(0), "already launched");
        token = new FARMX();
        initialFactoryBalance = token.balanceOf(address(this));
        hook = new LiquidityMiningHook{salt: salt}(manager);
        key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(token)),
            LaunchParameters.FEE,
            LaunchParameters.TICK_SPACING,
            IHooks(address(hook))
        );
        manager.initialize(key, LaunchParameters.SQRT_PRICE_X96);
        seedDelta = abi.decode(
            manager.unlock(abi.encode(int256(uint256(LaunchParameters.SEED_LIQUIDITY)))), (BalanceDelta)
        );
        token.transfer(msg.sender, token.balanceOf(address(this)));
        return (token, hook, key);
    }

    function collectSeedFees() external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(int256(0))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                LaunchParameters.SEED_TICK_LOWER,
                LaunchParameters.SEED_TICK_UPPER,
                abi.decode(data, (int256)),
                bytes32(0)
            ),
            ""
        );
        // The launch has no ETH: even the initial seed must settle with currency1 alone.
        require(delta.amount0() >= 0, "seed required ETH");
        if (delta.amount0() > 0) manager.take(key.currency0, address(this), uint128(delta.amount0()));
        if (delta.amount1() < 0) {
            manager.sync(key.currency1);
            token.transfer(address(manager), uint256(-int256(delta.amount1())));
            manager.settle();
        } else if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint128(delta.amount1()));
        }
        return abi.encode(delta);
    }
}

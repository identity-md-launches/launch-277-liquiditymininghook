// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {FARMX} from "../../src/FARMX.sol";
import {LiquidityMiningHook} from "../../src/LiquidityMiningHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {LaunchParameters} from "../../script/LaunchParameters.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SettlementRouter} from "./SettlementRouter.sol";

abstract contract HookTestBase is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    FARMX internal token;
    IPoolManager internal manager;
    LiquidityMiningHook internal hook;
    SettlementRouter internal router;
    PoolKey internal key;
    PoolId internal id;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint256 internal constant D = 30 days;
    int24 internal constant LOWER = -887220;
    int24 internal constant UPPER = 887220;
    uint256 internal constant L = 1 ether;
    receive() external payable {}

    function setUp() public virtual {
        vm.warp(1_000_000);
        vm.deal(address(this), 1e30);
        manager = new PoolManager(address(this));
        token = new FARMX();
        hook = _deployHook();
        router = new SettlementRouter(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        id = key.toId();
        manager.initialize(key, LaunchParameters.SQRT_PRICE_X96);
    }

    function _deployHook() internal returns (LiquidityMiningHook deployed) {
        bytes32 hash =
            keccak256(abi.encodePacked(type(LiquidityMiningHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < 1_000_000; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash))))
            );
            if (HookFlags.matches(predicted, HookFlags.REQUIRED)) {
                deployed = new LiquidityMiningHook{salt: bytes32(i)}(manager);
                assertEq(address(deployed), predicted);
                return deployed;
            }
        }
        revert("mining exhausted");
    }

    function _pk(uint256 salt) internal view returns (bytes32) {
        return hook.positionKey(address(router), LOWER, UPPER, router.saltFor(address(this), bytes32(salt)));
    }

    function _add(uint256 salt, uint256 amount, bytes memory data) internal {
        router.modify{value: amount * 2}(
            key, ModifyLiquidityParams(LOWER, UPPER, int256(amount), bytes32(salt)), data
        );
    }

    function _remove(uint256 salt, uint256 amount) internal {
        router.modify(key, ModifyLiquidityParams(LOWER, UPPER, -int256(amount), bytes32(salt)), "");
    }

    function _fund(uint256 amount) internal {
        hook.fund(key, amount);
    }

    function _claim(address beneficiary, bytes32 pk) internal returns (uint256 result) {
        vm.prank(beneficiary);
        result = hook.claim(key, pk);
    }

    function _swap(bool zeroForOne, int256 amount) internal returns (BalanceDelta delta) {
        delta = router.swap{value: zeroForOne ? 100 ether : 0}(
            key,
            SwapParams(
                zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            false
        );
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function _assertCoverage(uint256 actualEarned) internal view {
        uint256 balance = token.balanceOf(address(hook));
        assertLe(actualEarned, hook.earnedReserve(id));
        assertGe(balance, actualEarned + hook.unstreamed(id) + hook.idle(id));
        assertEq(balance, hook.earnedReserve(id) + hook.unstreamed(id) + hook.idle(id));
        assertLe(hook.totalClaimed(id), hook.totalFunded(id));
    }
}

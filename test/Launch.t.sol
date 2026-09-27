// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {LaunchParameters} from "../script/LaunchParameters.sol";
import {LiquidityMiningHook} from "../src/LiquidityMiningHook.sol";
import {UnusedCallbacks} from "../src/UnusedCallbacks.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract LaunchTest is HookTestBase {
    using StateLibrary for IPoolManager;

    function test_factoryShapeRehearsalFirstBuyIntoEthlessPool() public {
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(key.fee, LaunchParameters.FEE);
        assertEq(key.tickSpacing, LaunchParameters.TICK_SPACING);
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, LaunchParameters.SQRT_PRICE_X96);
        BalanceDelta seed = router.modify(
            key,
            ModifyLiquidityParams(
                LaunchParameters.SEED_TICK_LOWER,
                LaunchParameters.SEED_TICK_UPPER,
                int256(uint256(LaunchParameters.SEED_LIQUIDITY)),
                bytes32(0)
            ),
            ""
        );
        assertEq(seed.amount0(), 0);
        assertLt(seed.amount1(), 0);
        assertEq(address(manager).balance, 0);
        assertGt(token.balanceOf(address(manager)), 0);
        assertEq(hook.totalStaked(id), 0);
        _fund(D * 1 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(hook.idle(id), 1 days * 1 ether);
        BalanceDelta firstBuy = _swap(true, -1 ether);
        assertEq(firstBuy.amount0(), -1 ether);
        assertGt(firstBuy.amount1(), 0);
        assertEq(address(manager).balance, 1 ether);
        assertEq(hook.totalStaked(id), 0);
        bytes32 seedKey = hook.positionKey(
            address(router),
            LaunchParameters.SEED_TICK_LOWER,
            LaunchParameters.SEED_TICK_UPPER,
            router.saltFor(address(this), bytes32(0))
        );
        assertEq(hook.earned(id, seedKey), 0);
        assertEq(hook.beneficiaryOf(id, seedKey), address(0));
        _add(1, L, abi.encode(alice));
        vm.warp(block.timestamp + 1 days);
        assertEq(hook.earned(id, _pk(1)), 1 days * 1 ether);
        _assertCoverage(hook.earned(id, _pk(1)));
    }

    function test_exactInAndOutBothDirectionsAndDust() public {
        _add(1, 10_000 ether, "");
        BalanceDelta d = _swap(true, -1 ether);
        assertEq(d.amount0(), -1 ether);
        assertGt(d.amount1(), 0);
        d = _swap(false, -1 ether);
        assertEq(d.amount1(), -1 ether);
        assertGt(d.amount0(), 0);
        d = _swap(true, 1 ether);
        assertEq(d.amount1(), 1 ether);
        assertLt(d.amount0(), 0);
        d = _swap(false, 1 ether);
        assertEq(d.amount0(), 1 ether);
        assertLt(d.amount1(), 0);
        _swap(true, -1);
        _swap(false, -1);
        d = _swap(true, 1);
        assertEq(d.amount1(), 1);
        d = _swap(false, 1);
        assertEq(d.amount0(), 1);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function testFuzz_swapSizes(bool direction, bool exactOut, uint96 size) public {
        _add(1, 10_000 ether, "");
        int256 amount = int256(bound(size, 1, 10 ether));
        BalanceDelta d = _swap(direction, exactOut ? amount : -amount);
        if (exactOut) assertEq(direction ? d.amount1() : d.amount0(), amount);
        else assertEq(direction ? d.amount0() : d.amount1(), -amount);
    }

    function test_nonEthPoolIsInert() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1_000_000 ether);
        other.approve(address(router), type(uint256).max);
        (address a, address b) = address(token) < address(other)
            ? (address(token), address(other))
            : (address(other), address(token));
        PoolKey memory k = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(hook)));
        manager.initialize(k, LaunchParameters.SQRT_PRICE_X96);
        router.modify(
            k, ModifyLiquidityParams(LOWER, UPPER, int256(L), bytes32(uint256(7))), abi.encode(alice)
        );
        assertEq(hook.totalStaked(k.toId()), 0);
        assertEq(hook.positionCount(alice), 0);
        router.swap(k, SwapParams(true, -1e10, TickMath.MIN_SQRT_PRICE + 1), false);
        router.modify(k, ModifyLiquidityParams(LOWER, UPPER, -int256(L), bytes32(uint256(7))), "");
        assertEq(hook.totalStaked(k.toId()), 0);
        vm.expectRevert(LiquidityMiningHook.UnsupportedPool.selector);
        hook.fund(k, 1);
        assertEq(hook.rewardPerLiquidity(k.toId()), 0);
        assertEq(hook.periodEnd(k.toId()), 0);
    }

    function test_failedSettlementRollsBackPoolAndHook() public {
        _add(1, 100 ether, abi.encode(alice));
        (uint160 beforePrice,,,) = manager.getSlot0(id);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), true);
        (uint160 afterPrice,,,) = manager.getSlot0(id);
        assertEq(afterPrice, beforePrice);
        token.approve(address(router), 0);
        vm.expectRevert();
        router.modify{value: 2 ether}(
            key, ModifyLiquidityParams(LOWER, UPPER, int256(L), bytes32(uint256(2))), abi.encode(bob)
        );
        assertEq(hook.beneficiaryOf(id, _pk(2)), address(0));
        assertEq(hook.totalStaked(id), 100 ether);
    }

    function test_permissionsAndConstructorValidation() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.afterAddLiquidity = true;
        expected.afterRemoveLiquidity = true;
        assertEq(abi.encode(p), abi.encode(expected));
        assertEq(uint160(address(hook)) & HookFlags.ALL, 0x0500);
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new LiquidityMiningHook(manager);
        vm.expectRevert(UnusedCallbacks.InvalidPoolManager.selector);
        new LiquidityMiningHook(IPoolManager(address(0)));
    }

    function test_allCallbacksRefuseDirectCalls() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams(LOWER, UPPER, int256(L), bytes32(0));
        SwapParams memory s = SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1);
        bytes[10] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (alice, key, uint160(1))),
            abi.encodeCall(IHooks.afterInitialize, (alice, key, uint160(1), int24(0))),
            abi.encodeCall(IHooks.beforeAddLiquidity, (alice, key, p, bytes(""))),
            abi.encodeCall(
                IHooks.afterAddLiquidity,
                (alice, key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), abi.encode(alice))
            ),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (alice, key, p, bytes(""))),
            abi.encodeCall(
                IHooks.afterRemoveLiquidity,
                (alice, key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), bytes(""))
            ),
            abi.encodeCall(IHooks.beforeSwap, (alice, key, s, bytes(""))),
            abi.encodeCall(IHooks.afterSwap, (alice, key, s, BalanceDelta.wrap(0), bytes(""))),
            abi.encodeCall(IHooks.beforeDonate, (alice, key, uint256(1), uint256(1), bytes(""))),
            abi.encodeCall(IHooks.afterDonate, (alice, key, uint256(1), uint256(1), bytes("")))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory result) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(UnusedCallbacks.OnlyPoolManager.selector));
        }
        assertEq(hook.totalStaked(id), 0);
    }

    function test_zeroHookDeltasAndDisabledCallback() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams(LOWER, UPPER, 0, bytes32(0));
        vm.prank(address(manager));
        (bytes4 selector, BalanceDelta d) =
            hook.afterAddLiquidity(alice, key, p, BalanceDelta.wrap(-1), BalanceDelta.wrap(0), "");
        assertEq(selector, IHooks.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(d), 0);
        vm.prank(address(manager));
        (selector, d) =
            hook.afterRemoveLiquidity(alice, key, p, BalanceDelta.wrap(-1), BalanceDelta.wrap(0), "");
        assertEq(selector, IHooks.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(d), 0);
        vm.prank(address(manager));
        vm.expectRevert(UnusedCallbacks.CallbackDisabled.selector);
        hook.beforeInitialize(alice, key, 1);
    }

    function test_invalidFundingAndETHRefusal() public {
        PoolKey memory other = key;
        other.fee = 100;
        vm.expectRevert(LiquidityMiningHook.PoolNotInitialized.selector);
        hook.fund(other, 0);
        other.hooks = IHooks(address(0));
        vm.expectRevert(LiquidityMiningHook.UnsupportedPool.selector);
        hook.fund(other, 0);
        token.approve(address(hook), 0);
        vm.expectRevert();
        _fund(1);
        assertEq(hook.totalFunded(id), 0);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(hook).call{value: 1}(abi.encodeCall(hook.fund, (key, 0)));
        assertFalse(ok);
    }

    function test_hookRuntimeHasNoEscapeOpcodes() public view {
        bytes memory code = address(hook).code;
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}

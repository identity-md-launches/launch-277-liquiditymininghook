// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {FactoryLaunchHarness} from "./helpers/FactoryLaunchHarness.sol";
import {SettlementRouter} from "./helpers/SettlementRouter.sol";
import {LiquidityMiningHook} from "../src/LiquidityMiningHook.sol";
import {LaunchParameters} from "../script/LaunchParameters.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract FactoryLifecycleTest is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    FactoryLaunchHarness internal factory;
    bytes32 internal seedKey;

    function setUp() public override {
        vm.warp(1_000_000);
        vm.deal(address(this), 1e30);
        manager = new PoolManager(address(this));
        factory = new FactoryLaunchHarness(manager);
        bytes32 initHash =
            keccak256(abi.encodePacked(type(LiquidityMiningHook).creationCode, abi.encode(manager)));
        address predicted;
        bytes32 salt;
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash))))
            );
            if (HookFlags.matches(predicted, HookFlags.REQUIRED)) break;
        }
        require(HookFlags.matches(predicted, HookFlags.REQUIRED), "mining exhausted");
        (token, hook, key) = factory.launch(salt);
        assertEq(address(hook), predicted);
        id = key.toId();
        router = new SettlementRouter(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
        seedKey = Position.calculatePositionKey(
            address(factory), LaunchParameters.SEED_TICK_LOWER, LaunchParameters.SEED_TICK_UPPER, bytes32(0)
        );
    }

    function test_atomicFactoryLaunchThroughFinalClaims() public {
        assertEq(factory.initialFactoryBalance(), 1_000_000_000 ether);
        assertEq(factory.seedDelta().amount0(), 0);
        assertEq(token.balanceOf(address(manager)), uint256(-int256(factory.seedDelta().amount1())));
        assertEq(address(manager).balance, 0);
        assertEq(address(factory).balance, 0);
        assertEq(manager.getPositionLiquidity(id, seedKey), LaunchParameters.SEED_LIQUIDITY);
        assertEq(hook.positionCount(address(factory)), 0);
        (uint160 initialPrice,,,) = manager.getSlot0(id);
        assertEq(initialPrice, LaunchParameters.SQRT_PRICE_X96);

        _fund(D * 6 ether);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 10 days);
        assertEq(hook.idle(id), 10 days * 6 ether);
        _assertCoverage(0);
        BalanceDelta firstBuy = _swap(true, -1 ether);
        assertEq(firstBuy.amount0(), -1 ether);
        assertGt(firstBuy.amount1(), 0);
        assertEq(address(manager).balance, 1 ether);
        _add(1, L, abi.encode(alice));
        vm.warp(start + 20 days);
        _add(2, 2 * L, abi.encode(bob));
        assertEq(hook.earned(id, _pk(1)), 10 days * 6 ether);
        assertEq(hook.earned(id, _pk(2)), 0);

        // Restart includes ten days of idle and ten days still unstreamed, but excludes Alice's earnings.
        _fund(D * 2 ether);
        assertEq(hook.rewardRate(id), 6 ether);
        assertEq(hook.idle(id), 0);
        vm.warp(start + 30 days);
        _swap(true, -1 ether);
        _remove(2, 0);
        assertEq(hook.staked(id, _pk(2)), 2 * L);
        assertEq(manager.getPositionLiquidity(id, _pk(2)), 2 * L);
        BalanceDelta fees = factory.collectSeedFees();
        assertGt(fees.amount0(), 0);
        assertEq(manager.getPositionLiquidity(id, seedKey), LaunchParameters.SEED_LIQUIDITY);
        assertEq(hook.totalStaked(id), 3 * L);
        assertEq(hook.staked(id, seedKey), 0);
        assertEq(hook.earned(id, seedKey), 0);
        vm.prank(address(factory));
        vm.expectRevert(LiquidityMiningHook.OnlyBeneficiary.selector);
        hook.claim(key, seedKey);

        _remove(2, L);
        assertEq(hook.staked(id, _pk(2)), L);
        assertEq(hook.totalStaked(id), 2 * L);
        vm.warp(start + 50 days);
        uint256 aliceReward = 140 days * 1 ether;
        uint256 bobReward = 100 days * 1 ether;
        assertEq(hook.earned(id, _pk(1)), aliceReward);
        assertEq(hook.earned(id, _pk(2)), bobReward);
        _assertCoverage(aliceReward + bobReward);
        _remove(1, L);
        _remove(2, L);
        assertEq(_claim(bob, _pk(2)), bobReward);
        assertEq(_claim(alice, _pk(1)), aliceReward);
        assertEq(token.balanceOf(alice), aliceReward);
        assertEq(token.balanceOf(bob), bobReward);
        assertEq(hook.totalClaimed(id), D * 8 ether);
        assertEq(hook.totalStaked(id), 0);
        assertEq(hook.earned(id, seedKey), 0);
        assertEq(hook.beneficiaryOf(id, seedKey), address(0));
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(_claim(alice, _pk(1)), 0);
        _assertCoverage(0);
    }

    function testFuzz_firstBuyAtProposedLaunchPrice(uint96 size, bool exactOut) public {
        assertEq(address(manager).balance, 0);
        uint256 amount = bound(size, 1, 10 ether);
        uint256 beforeTokens = token.balanceOf(address(this));
        uint256 beforeEth = address(this).balance;
        BalanceDelta delta = _swap(true, exactOut ? int256(amount) : -int256(amount));
        if (exactOut) assertEq(delta.amount1(), int256(amount));
        else assertEq(delta.amount0(), -int256(amount));
        assertEq(token.balanceOf(address(this)) - beforeTokens, uint128(delta.amount1()));
        assertEq(beforeEth - address(this).balance, uint256(-int256(delta.amount0())));
        assertEq(address(manager).balance, uint256(-int256(delta.amount0())));
        assertEq(hook.totalStaked(id), 0);
        assertEq(hook.earned(id, seedKey), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}

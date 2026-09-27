// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {LiquidityMiningHook} from "../src/LiquidityMiningHook.sol";
import {AdversarialToken} from "./mocks/AdversarialToken.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AdversarialTest is HookTestBase {
    AdversarialToken internal hostile;

    function setUp() public override {
        super.setUp();
        hostile = new AdversarialToken();
        hostile.approve(address(hook), type(uint256).max);
        hostile.approve(address(router), type(uint256).max);
        key.currency1 = Currency.wrap(address(hostile));
        id = key.toId();
        manager.initialize(key, 79228162514264337593543950336);
    }

    function test_feeOnTransferFundingUsesReceivedBalance() public {
        _add(1, L, abi.encode(alice));
        hostile.setTax(1000);
        uint256 amount = D * 1 ether;
        assertEq(hook.fund(key, amount), amount * 9 / 10);
        assertEq(hook.totalFunded(id), amount * 9 / 10);
        assertEq(hook.rewardRate(id), 0.9 ether);
        vm.warp(block.timestamp + D);
        uint256 claim = _claim(alice, _pk(1));
        assertEq(claim, amount * 9 / 10);
        assertEq(hostile.balanceOf(alice), claim * 9 / 10);
        assertEq(hostile.balanceOf(address(hook)), 0);
    }

    function test_failedFundingAndClaimRollBackAccounting() public {
        _add(1, L, abi.encode(alice));
        hostile.setFailure(true);
        vm.expectRevert();
        hook.fund(key, D * 1 ether);
        assertEq(hook.totalFunded(id), 0);
        assertEq(hook.periodEnd(id), 0);
        hostile.setFailure(false);
        _fund(D * 1 ether);
        vm.warp(block.timestamp + D);
        bytes32 pk = _pk(1);
        hostile.setFailure(true);
        vm.prank(alice);
        vm.expectRevert();
        hook.claim(key, pk);
        assertEq(hook.earned(id, pk), D * 1 ether);
        assertEq(hook.totalClaimed(id), 0);
        hostile.setFailure(false);
        assertEq(_claim(alice, pk), D * 1 ether);
    }

    function test_reentrantFundingIsBlocked() public {
        hostile.setAttack(address(hook), abi.encodeCall(hook.fund, (key, 0)));
        _fund(D * 1 ether);
        assertFalse(hostile.attackSucceeded());
        assertEq(
            hostile.attackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(hook.totalFunded(id), D * 1 ether);
    }

    function test_reentrantBeneficiaryCannotDoubleClaim() public {
        _add(1, L, abi.encode(address(hostile)));
        _fund(D * 1 ether);
        vm.warp(block.timestamp + D);
        bytes32 pk = _pk(1);
        hostile.setAttack(address(hook), abi.encodeCall(hook.claim, (key, pk)));
        assertEq(_claim(address(hostile), pk), D * 1 ether);
        assertFalse(hostile.attackSucceeded());
        assertEq(
            hostile.attackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(hook.totalClaimed(id), D * 1 ether);
        assertEq(hook.earned(id, pk), 0);
    }

    function test_accumulatorBoundaryAndLifetimeFundingLimit() public {
        _add(1, 1, abi.encode(alice));
        uint256 maximum = hook.MAX_FUNDED();
        _fund(maximum);
        vm.warp(block.timestamp + D);
        uint256 streamed = maximum / D * D;
        assertEq(hook.rewardPerLiquidity(id), streamed * 1e18);
        assertEq(_claim(alice, _pk(1)), streamed);
        assertEq(hook.idle(id), maximum % D);
        assertEq(hostile.balanceOf(address(hook)), maximum % D);
        vm.expectRevert(LiquidityMiningHook.FundingLimit.selector);
        _fund(1);
        assertEq(hook.totalFunded(id), maximum);
    }
}

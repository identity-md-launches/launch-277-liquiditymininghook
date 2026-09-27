// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {LiquidityMiningHook} from "../src/LiquidityMiningHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract RewardsTest is HookTestBase {
    function test_twoStakersLiquiditySecondsAndEvents() public {
        vm.expectEmit(true, true, true, true, address(hook));
        emit LiquidityMiningHook.Staked(id, _pk(1), alice, L);
        _add(1, L, abi.encode(alice));
        uint256 start = block.timestamp;
        vm.expectEmit(true, true, false, true, address(hook));
        emit LiquidityMiningHook.Funded(id, address(this), D * 1 ether, 1 ether, start + D);
        _fund(D * 1 ether);
        vm.warp(start + 10 days);
        _add(2, L, abi.encode(bob));
        vm.warp(start + D);
        assertEq(hook.earned(id, _pk(1)), 20 days * 1 ether);
        assertEq(hook.earned(id, _pk(2)), 10 days * 1 ether);
        _assertCoverage(hook.earned(id, _pk(1)) + hook.earned(id, _pk(2)));
        vm.expectEmit(true, true, true, true, address(hook));
        emit LiquidityMiningHook.Claimed(id, _pk(1), alice, 20 days * 1 ether);
        assertEq(_claim(alice, _pk(1)), 20 days * 1 ether);
        assertEq(_claim(bob, _pk(2)), 10 days * 1 ether);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(_claim(alice, _pk(1)), 0);
    }

    function test_emptyStreamFullyRestreamedIncludingRateDust() public {
        uint256 amount = D * 1 ether + 7;
        _fund(amount);
        vm.warp(block.timestamp + D + 7 days);
        assertEq(hook.idle(id), amount);
        assertEq(hook.unstreamed(id), 0);
        _assertCoverage(0);
        _fund(0);
        assertEq(hook.rewardRate(id), 1 ether);
        assertEq(hook.idle(id), 7);
        _add(1, L, abi.encode(alice));
        vm.warp(block.timestamp + D);
        assertEq(_claim(alice, _pk(1)), D * 1 ether);
        assertEq(token.balanceOf(address(hook)), 7);
        _assertCoverage(0);
    }

    function test_idleBeforeFirstStakeDoesNotBelongToFirstStaker() public {
        _fund(D * 1 ether);
        vm.warp(block.timestamp + 10 days);
        _add(1, L, abi.encode(alice));
        assertEq(hook.earned(id, _pk(1)), 0);
        assertEq(hook.idle(id), 10 days * 1 ether);
        vm.warp(block.timestamp + 20 days);
        assertEq(_claim(alice, _pk(1)), 20 days * 1 ether);
        _fund(20 days * 1 ether);
        assertEq(hook.rewardRate(id), 1 ether);
        assertEq(hook.idle(id), 0);
        vm.warp(block.timestamp + D);
        assertEq(_claim(alice, _pk(1)), D * 1 ether);
        _assertCoverage(0);
    }

    function test_midStreamTopUpIncludesRemainingAndExcludesEarned() public {
        _add(1, L, abi.encode(alice));
        _fund(D * 1 ether);
        vm.warp(block.timestamp + 10 days);
        _fund(10 days * 1 ether);
        assertEq(hook.rewardRate(id), 1 ether);
        assertEq(hook.earned(id, _pk(1)), 10 days * 1 ether);
        vm.warp(block.timestamp + D);
        assertEq(_claim(alice, _pk(1)), 40 days * 1 ether);
        _assertCoverage(0);
    }

    function test_unenrolledLiquidityNeverDilutesAndRemovalCapsStake() public {
        _add(1, 5 * L, "");
        _add(2, L, abi.encode(bob));
        _fund(D * 1 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(hook.earned(id, _pk(1)), 0);
        assertEq(hook.earned(id, _pk(2)), 1 days * 1 ether);
        _add(1, 2 * L, abi.encode(alice));
        assertEq(hook.staked(id, _pk(1)), 2 * L);
        assertEq(hook.earned(id, _pk(1)), 0);
        _add(1, 3 * L, "");
        assertEq(hook.staked(id, _pk(1)), 5 * L);
        _remove(1, 4 * L);
        assertEq(hook.staked(id, _pk(1)), 5 * L);
        vm.expectEmit(true, true, true, true, address(hook));
        emit LiquidityMiningHook.Unstaked(id, _pk(1), alice, L);
        _remove(1, 2 * L);
        assertEq(hook.staked(id, _pk(1)), 4 * L);
        assertEq(hook.totalStaked(id), 5 * L);
        _remove(1, 4 * L);
        assertEq(hook.staked(id, _pk(1)), 0);
        assertEq(hook.totalStaked(id), L);
    }

    function test_partialAndFullRemovalCheckpointBeforeChangingWeight() public {
        _add(1, 2 * L, abi.encode(alice));
        _add(2, L, abi.encode(bob));
        _fund(D * 3 ether);
        vm.warp(block.timestamp + 1 days);
        _remove(1, L);
        assertEq(hook.earned(id, _pk(1)), 2 days * 1 ether);
        vm.warp(block.timestamp + 2 days);
        _remove(1, L);
        assertEq(hook.earned(id, _pk(1)), 5 days * 1 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(_claim(alice, _pk(1)), 5 days * 1 ether);
        assertEq(hook.earned(id, _pk(2)), 7 days * 1 ether);
        _assertCoverage(hook.earned(id, _pk(2)));
    }

    function test_feeCollectionDoesNotUnstake() public {
        _add(1, L, abi.encode(alice));
        _fund(D * 1 ether);
        _swap(true, -0.1 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 balance = address(this).balance;
        _remove(1, 0);
        assertGt(address(this).balance, balance);
        assertEq(hook.staked(id, _pk(1)), L);
        assertEq(hook.totalStaked(id), L);
        assertEq(hook.earned(id, _pk(1)), 1 days * 1 ether);
    }

    function test_malformedDataDoesNotEnrollOrRevert() public {
        _add(1, L, "");
        _add(2, L, hex"01");
        _add(3, L, abi.encode(address(0)));
        _add(4, L, abi.encode(type(uint256).max));
        _add(5, L, abi.encode(alice, bob));
        assertEq(hook.totalStaked(id), 0);
        assertEq(hook.positionCount(alice), 0);
        _add(1, L, abi.encode(alice));
        _add(1, L, abi.encode(bob));
        _add(1, L, hex"abcd");
        assertEq(hook.beneficiaryOf(id, _pk(1)), alice);
        assertEq(hook.staked(id, _pk(1)), 3 * L);
        assertEq(hook.positionCount(bob), 0);
    }

    function test_beneficiaryNeverChangesIncludingAfterExit() public {
        _add(1, L, abi.encode(alice));
        _remove(1, L);
        _add(1, L, abi.encode(bob));
        _fund(D * 1 ether);
        vm.warp(block.timestamp + 1 days);
        bytes32 pk = _pk(1);
        vm.prank(bob);
        vm.expectRevert(LiquidityMiningHook.OnlyBeneficiary.selector);
        hook.claim(key, pk);
        assertEq(_claim(alice, _pk(1)), 1 days * 1 ether);
        LiquidityMiningHook.PositionRef[] memory refs = hook.positionsOf(alice);
        assertEq(refs.length, 1);
        assertEq(PoolId.unwrap(refs[0].poolId), PoolId.unwrap(id));
        assertEq(refs[0].positionKey, _pk(1));
        assertEq(hook.positionAt(alice, 0).positionKey, _pk(1));
    }

    function test_outOfRangeLiquidityEarns() public {
        bytes32 salt = bytes32(uint256(9));
        router.modify(key, ModifyLiquidityParams(-120, -60, int256(L), salt), abi.encode(alice));
        bytes32 pk = hook.positionKey(address(router), -120, -60, router.saltFor(address(this), salt));
        _fund(D * 1 ether);
        vm.warp(block.timestamp + D);
        assertEq(_claim(alice, pk), D * 1 ether);
    }

    function test_dustFundingIsIdleUntilEnoughToStream() public {
        _add(1, L, abi.encode(alice));
        _fund(D - 1);
        assertEq(hook.rewardRate(id), 0);
        assertEq(hook.idle(id), D - 1);
        vm.warp(block.timestamp + D);
        _fund(1);
        assertEq(hook.rewardRate(id), 1);
        vm.warp(block.timestamp + D);
        assertEq(_claim(alice, _pk(1)), D);
    }

    function test_fractionSurvivesRepeatedClaims() public {
        _add(1, 1, abi.encode(alice));
        _add(2, 2, abi.encode(bob));
        _fund(D);
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1);
            _claim(alice, _pk(1));
        }
        vm.warp(block.timestamp + 1);
        assertEq(_claim(alice, _pk(1)), 1);
        assertLe(_claim(bob, _pk(2)), 3);
        _assertCoverage(0);
    }

    function test_poolIsolationForSameRewardToken() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, 79228162514264337593543950336);
        router.modify{value: 2 ether}(
            other, ModifyLiquidityParams(LOWER, UPPER, int256(L), bytes32(uint256(1))), abi.encode(bob)
        );
        _add(1, L, abi.encode(alice));
        _fund(D * 1 ether);
        hook.fund(other, D * 2 ether);
        vm.warp(block.timestamp + D);
        assertEq(_claim(alice, _pk(1)), D * 1 ether);
        assertEq(hook.earned(other.toId(), _pk(1)), D * 2 ether);
        bytes32 pk = _pk(1);
        vm.prank(bob);
        assertEq(hook.claim(other, pk), D * 2 ether);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function testFuzz_proportionalRewardsNeverExceedFunded(uint96 a, uint96 b, uint96 funding) public {
        uint256 la = bound(a, 1, 100 ether);
        uint256 lb = bound(b, 1, 100 ether);
        uint256 amount = bound(funding, 0, 10_000_000 ether);
        _add(1, la, abi.encode(alice));
        _add(2, lb, abi.encode(bob));
        _fund(amount);
        vm.warp(block.timestamp + D);
        uint256 paid = _claim(alice, _pk(1)) + _claim(bob, _pk(2));
        assertLe(paid, amount);
        _assertCoverage(0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {LiquidityMiningHook} from "../src/LiquidityMiningHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract RewardBoundariesTest is HookTestBase {
    using StateLibrary for IPoolManager;

    struct Scenario {
        uint256 a;
        uint256 b;
        uint256 removed;
        uint256 join;
        uint256 exit;
        uint256 rate;
    }

    function testFuzz_staggeredEntryPartialExitAndClaimOrder(
        uint16 a,
        uint16 b,
        uint16 removed,
        uint32 join,
        uint32 exit,
        bool bobFirst
    ) public {
        Scenario memory s;
        s.a = bound(a, 2, 1000);
        s.b = bound(b, 1, 1000);
        s.removed = bound(removed, 1, s.a - 1);
        s.join = bound(join, 1, D - 2);
        s.exit = bound(exit, s.join + 1, D - 1);
        // Each interval's total weight divides the rate, giving an exact economic oracle
        // without copying the hook's accumulator or hiding a split error behind a tolerance.
        s.rate = s.a * (s.a + s.b) * (s.a - s.removed + s.b) * 1e8;
        uint256 start = vm.getBlockTimestamp();
        _add(1, s.a * 1e12, abi.encode(alice));
        _fund(D * s.rate);
        vm.warp(start + s.join);
        _add(2, s.b * 1e12, abi.encode(bob));
        assertEq(hook.earned(id, _pk(2)), 0, "late entry received past emissions");
        assertEq(hook.earned(id, _pk(1)), s.join * s.rate);
        uint256 earlyClaim = _claim(alice, _pk(1));
        vm.warp(start + s.exit);
        _remove(1, s.removed * 1e12);
        assertEq(hook.staked(id, _pk(1)), (s.a - s.removed) * 1e12);
        assertEq(manager.getPositionLiquidity(id, _pk(1)), (s.a - s.removed) * 1e12);

        uint256 aliceExpected = (s.exit - s.join) * s.rate * s.a / (s.a + s.b) + (D - s.exit) * s.rate
            * (s.a - s.removed) / (s.a - s.removed + s.b);
        uint256 bobExpected = (s.exit - s.join) * s.rate * s.b / (s.a + s.b) + (D - s.exit) * s.rate * s.b
            / (s.a - s.removed + s.b);
        vm.warp(start + D);
        assertEq(hook.earned(id, _pk(1)), aliceExpected);
        assertEq(hook.earned(id, _pk(2)), bobExpected);
        _assertCoverage(aliceExpected + bobExpected);
        if (bobFirst) {
            assertEq(_claim(bob, _pk(2)), bobExpected);
            assertEq(_claim(alice, _pk(1)), aliceExpected);
        } else {
            assertEq(_claim(alice, _pk(1)), aliceExpected);
            assertEq(_claim(bob, _pk(2)), bobExpected);
        }
        assertEq(earlyClaim + aliceExpected + bobExpected, D * s.rate);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), D * s.rate);
        vm.warp(start + 2 * D);
        assertEq(_claim(alice, _pk(1)) + _claim(bob, _pk(2)), 0);
        _assertCoverage(0);
    }

    function testFuzz_emptyFundingRestartsEveryTokenIncludingRemainder(
        uint96 first,
        uint96 second,
        uint32 elapsed
    ) public {
        uint256 initial = bound(first, 0, 1_000_000 ether);
        uint256 topUp = bound(second, 0, 1_000_000 ether);
        _fund(initial);
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 2 * D));
        assertEq(hook.idle(id) + hook.unstreamed(id), initial);
        _assertCoverage(0);
        _fund(topUp);
        uint256 budget = initial + topUp;
        assertEq(hook.rewardRate(id), budget / D);
        assertEq(hook.idle(id), budget % D);
        assertEq(hook.unstreamed(id), budget / D * D);
        _add(1, L, abi.encode(alice));
        assertEq(hook.earned(id, _pk(1)), 0);
        vm.warp(vm.getBlockTimestamp() + D);
        assertEq(_claim(alice, _pk(1)), budget / D * D);
        assertEq(token.balanceOf(address(hook)), budget % D);
        // Supply the exact complement: every remaining wei must become claimable next period.
        uint256 complement = (D - budget % D) % D;
        _fund(complement);
        vm.warp(vm.getBlockTimestamp() + D);
        assertEq(_claim(alice, _pk(1)), budget % D + complement);
        assertEq(token.balanceOf(alice), budget + complement);
        assertEq(token.balanceOf(address(hook)), 0);
        _assertCoverage(0);
    }

    function testFuzz_removalCapsOnlyEnrolledLiquidity(uint96 initial, uint96 enrolled, uint96 remove)
        public
    {
        uint256 unstaked = bound(initial, 1, 10 ether);
        uint256 stake = bound(enrolled, 1, 10 ether);
        uint256 removed = bound(remove, 0, unstaked + stake);
        _add(1, unstaked, "");
        _add(1, stake, abi.encode(alice));
        _remove(1, removed);
        uint256 remaining = unstaked + stake - removed;
        uint256 expected = remaining < stake ? remaining : stake;
        assertEq(manager.getPositionLiquidity(id, _pk(1)), remaining);
        assertEq(hook.staked(id, _pk(1)), expected);
        assertEq(hook.totalStaked(id), expected);
        assertEq(hook.beneficiaryOf(id, _pk(1)), alice);
        assertEq(hook.positionCount(alice), 1);
        // Once enrolled, even an empty-data addition after a full exit is eligible.
        _add(1, 1, "");
        assertEq(hook.staked(id, _pk(1)), expected + 1);
        assertEq(hook.positionCount(alice), 1);
    }

    function test_rejectedOperationsPreservePendingRewardsAndLiveSchedule() public {
        _add(1, L, abi.encode(alice));
        _add(2, L, abi.encode(bob));
        _fund(D * 2 ether + 7);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        bytes32 beforeState = _rewardState();
        uint256 beforeBalance = token.balanceOf(address(this));
        bytes32 aliceKey = _pk(1);
        vm.prank(bob);
        vm.expectRevert(LiquidityMiningHook.OnlyBeneficiary.selector);
        hook.claim(key, aliceKey);
        assertEq(_rewardState(), beforeState);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        _remove(1, L + 1);
        assertEq(_rewardState(), beforeState);
        assertEq(manager.getPositionLiquidity(id, aliceKey), L);

        token.approve(address(hook), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), uint256(0), uint256(1)
            )
        );
        hook.fund(key, 1);
        assertEq(_rewardState(), beforeState);
        assertEq(token.balanceOf(address(this)), beforeBalance);
        token.approve(address(hook), type(uint256).max);
        vm.warp(hook.periodEnd(id));
        assertEq(_claim(alice, aliceKey), D * 1 ether);
        assertEq(_claim(bob, _pk(2)), D * 1 ether);
        _assertCoverage(0);
    }

    function _rewardState() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.totalFunded(id),
                hook.totalClaimed(id),
                hook.rewardRate(id),
                hook.periodEnd(id),
                hook.rewardPerLiquidity(id),
                hook.earned(id, _pk(1)),
                hook.earned(id, _pk(2)),
                hook.totalStaked(id),
                hook.idle(id),
                hook.unstreamed(id),
                token.balanceOf(address(hook))
            )
        );
    }
}

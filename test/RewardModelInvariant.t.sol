// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {SettlementRouter} from "./helpers/SettlementRouter.sol";
import {FARMX} from "../src/FARMX.sol";
import {LiquidityMiningHook} from "../src/LiquidityMiningHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Direct per-position integration of rate * seconds * liquidity / totalLiquidity.
/// There is deliberately no model rewardPerLiquidity, paidAccumulator, or earnedReserve.
contract RewardModelHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    uint256 private constant DURATION = 30 days;
    uint256 private constant Q = 1e30;
    uint256 private constant CAP = 1e12;
    LiquidityMiningHook private immutable hook;
    SettlementRouter private immutable router;
    FARMX private immutable token;
    IPoolManager private immutable manager;
    PoolKey private key;
    PoolId private id;
    uint256[4] private liquidity;
    uint256[4] private stake;
    bool[4] private enrolled;
    int256[4] private entitlementQ;
    uint256[4] private paidTo;
    uint256 private total;
    uint256 private rate;
    uint256 private end;
    uint256 private updated;
    uint256 private idleTokens;
    uint256 private funded;
    uint256 private paid;

    constructor(LiquidityMiningHook h, SettlementRouter r, FARMX t, PoolKey memory k) {
        hook = h;
        router = r;
        token = t;
        manager = r.manager();
        key = k;
        id = k.toId();
        token.approve(address(hook), type(uint256).max);
        token.approve(address(router), type(uint256).max);
    }

    receive() external payable {}

    function advance(uint32 elapsed) public {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 2 * DURATION));
        _accrue();
    }

    function fund(uint96 amount_) public {
        _accrue();
        uint256 amount = bound(amount_, 0, 1000 ether);
        uint256 budget = amount + _remaining() + idleTokens;
        assertEq(hook.fund(key, amount), amount);
        rate = budget / DURATION;
        idleTokens = budget % DURATION;
        end = vm.getBlockTimestamp() + DURATION;
        updated = vm.getBlockTimestamp();
        funded += amount;
    }

    function add(uint8 slot_, uint96 amount_, bool enroll) public {
        _accrue();
        uint256 s = slot_ % 4;
        if (liquidity[s] == CAP) return;
        uint256 amount = bound(amount_, 1, CAP - liquidity[s]);
        router.modify{value: 2 * amount}(
            key,
            ModifyLiquidityParams(-887220, 887220, int256(amount), bytes32(s)),
            enroll ? abi.encode(_beneficiary(s)) : bytes("")
        );
        liquidity[s] += amount;
        enrolled[s] = enrolled[s] || enroll;
        if (enrolled[s]) {
            stake[s] += amount;
            total += amount;
        }
    }

    function remove(uint8 slot_, uint96 amount_) public {
        _accrue();
        uint256 s = slot_ % 4;
        if (liquidity[s] == 0) return;
        uint256 amount = bound(amount_, 0, liquidity[s]);
        _remove(s, amount);
    }

    function collect(uint8 slot_) external {
        _accrue();
        uint256 s = slot_ % 4;
        if (liquidity[s] != 0) _remove(s, 0);
    }

    function claim(uint8 slot_) public {
        _accrue();
        uint256 s = slot_ % 4;
        if (enrolled[s]) _claim(s);
    }

    function rejectedClaim(uint8 slot_) external {
        _accrue();
        bytes32 beforeState = _stateHash();
        bytes32 pk = _pk(slot_ % 4);
        vm.prank(address(0xBAD));
        vm.expectRevert(LiquidityMiningHook.OnlyBeneficiary.selector);
        hook.claim(key, pk);
        assertEq(_stateHash(), beforeState, "unauthorized claim changed state");
    }

    function rejectedRemoval(uint8 slot_, uint96 extra_) external {
        _accrue();
        uint256 s = slot_ % 4;
        bytes32 beforeState = _stateHash();
        uint256 amount = liquidity[s] + bound(extra_, 1, CAP);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        router.modify(key, ModifyLiquidityParams(-887220, 887220, -int256(amount), bytes32(s)), "");
        assertEq(_stateHash(), beforeState, "over-removal changed state");
        assertEq(manager.getPositionLiquidity(id, _pk(s)), liquidity[s]);
    }

    function rejectedFunding(uint96 amount_) external {
        _accrue();
        uint256 amount = bound(amount_, 1, 1000 ether);
        token.approve(address(hook), 0);
        bytes32 beforeState = _stateHash();
        uint256 beforeBalance = token.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), uint256(0), amount
            )
        );
        hook.fund(key, amount);
        assertEq(_stateHash(), beforeState, "failed transfer changed stream");
        assertEq(token.balanceOf(address(this)), beforeBalance);
        token.approve(address(hook), type(uint256).max);
    }

    function assertModel() public view {
        uint256 earned;
        for (uint256 s; s < 4; ++s) {
            bytes32 pk = _pk(s);
            uint256 actual = hook.earned(id, pk);
            earned += actual;
            // CAP bounds each position to 1e12 liquidity. A pool checkpoint loses < 1e-6
            // wei per position; at the configured 64 calls this is far below one wei.
            // The one-wei tolerance also covers flooring the independently integrated fraction.
            assertApproxEqAbs(int256(actual * Q), entitlementQ[s], Q, "incorrect liquidity-seconds share");
            assertEq(hook.staked(id, pk), stake[s]);
            assertEq(manager.getPositionLiquidity(id, pk), liquidity[s]);
            assertEq(hook.beneficiaryOf(id, pk), enrolled[s] ? _beneficiary(s) : address(0));
            assertEq(token.balanceOf(_beneficiary(s)), paidTo[s]);
            assertEq(hook.positionCount(_beneficiary(s)), enrolled[s] ? 1 : 0);
        }
        uint256 balance = token.balanceOf(address(hook));
        assertEq(hook.totalStaked(id), total);
        assertEq(hook.rewardRate(id), rate);
        assertEq(hook.periodEnd(id), end);
        assertEq(hook.idle(id), idleTokens);
        assertEq(hook.unstreamed(id), _remaining());
        assertEq(hook.totalFunded(id), funded);
        assertEq(hook.totalClaimed(id), paid);
        assertLe(paid, funded);
        assertEq(balance + paid, funded);
        assertGe(balance, earned + idleTokens + _remaining());
        assertEq(hook.earnedReserve(id), funded - paid - idleTokens - _remaining());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
    }

    /// @dev Called after every invariant sequence: exiting must preserve earned rewards, leave
    /// no stake, permit beneficiaries to claim, and make repeat claims pay zero.
    function finish() external {
        _accrue();
        for (uint256 s; s < 4; ++s) {
            if (liquidity[s] != 0) _remove(s, liquidity[s]);
        }
        advance(uint32(DURATION));
        for (uint256 s; s < 4; ++s) {
            if (!enrolled[s]) continue;
            _claim(s);
            uint256 beforePaid = paid;
            _claim(s);
            assertEq(paid, beforePaid, "repeat claim paid twice");
        }
        assertEq(total, 0);
        assertModel();
    }

    function _accrue() private {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 until = now_ < end ? now_ : end;
        uint256 emission = (until - updated) * rate;
        if (total == 0) {
            idleTokens += emission;
        } else {
            for (uint256 s; s < 4; ++s) {
                entitlementQ[s] += int256(emission * Q * stake[s] / total);
            }
        }
        updated = until;
    }

    function _remove(uint256 s, uint256 amount) private {
        router.modify(key, ModifyLiquidityParams(-887220, 887220, -int256(amount), bytes32(s)), "");
        liquidity[s] -= amount;
        uint256 newStake = stake[s] < liquidity[s] ? stake[s] : liquidity[s];
        total -= stake[s] - newStake;
        stake[s] = newStake;
    }

    function _claim(uint256 s) private {
        address beneficiary = _beneficiary(s);
        bytes32 pk = _pk(s);
        uint256 beforeBalance = token.balanceOf(beneficiary);
        vm.prank(beneficiary);
        uint256 amount = hook.claim(key, pk);
        assertEq(token.balanceOf(beneficiary) - beforeBalance, amount);
        entitlementQ[s] -= int256(amount * Q);
        paidTo[s] += amount;
        paid += amount;
    }

    function _remaining() private view returns (uint256) {
        uint256 now_ = vm.getBlockTimestamp();
        return now_ < end ? (end - now_) * rate : 0;
    }

    function _pk(uint256 s) private view returns (bytes32) {
        return Position.calculatePositionKey(
            address(router), -887220, 887220, keccak256(abi.encode(address(this), bytes32(s)))
        );
    }

    function _beneficiary(uint256 s) private pure returns (address) {
        return address(uint160(0xCAFE00 + s));
    }

    function _stateHash() private view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                hook.rewardRate(id),
                hook.periodEnd(id),
                hook.rewardPerLiquidity(id),
                hook.totalStaked(id),
                hook.totalFunded(id),
                hook.totalClaimed(id),
                hook.idle(id),
                hook.unstreamed(id),
                token.balanceOf(address(hook))
            )
        );
        for (uint256 s; s < 4; ++s) {
            result = keccak256(abi.encode(result, hook.earned(id, _pk(s)), hook.staked(id, _pk(s))));
        }
    }
}

contract RewardModelInvariantTest is HookTestBase {
    RewardModelHandler internal handler;

    function setUp() public override {
        super.setUp();
        // Permanent unenrolled liquidity supplies the pool without diluting the model's four stakers.
        _add(99, 100 ether, "");
        handler = new RewardModelHandler(hook, router, token, key);
        token.transfer(address(handler), 100_000_000 ether);
        vm.deal(address(handler), 1e25);
        // Every campaign starts with idle, staggered entry, and an actual positive claim.
        handler.fund(uint96(1000 ether));
        handler.advance(uint32(7 days));
        handler.add(0, uint96(1e12), true);
        handler.advance(uint32(7 days));
        handler.add(1, uint96(5e11), true);
        handler.advance(uint32(1 days));
        handler.claim(0);
        handler.assertModel();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = RewardModelHandler.advance.selector;
        selectors[1] = RewardModelHandler.fund.selector;
        selectors[2] = RewardModelHandler.add.selector;
        selectors[3] = RewardModelHandler.remove.selector;
        selectors[4] = RewardModelHandler.collect.selector;
        selectors[5] = RewardModelHandler.claim.selector;
        selectors[6] = RewardModelHandler.rejectedClaim.selector;
        selectors[7] = RewardModelHandler.rejectedRemoval.selector;
        selectors[8] = RewardModelHandler.rejectedFunding.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_rewardsMatchIndependentLiquiditySecondsAndRemainCovered() public view {
        handler.assertModel();
        assertEq(hook.staked(id, _pk(99)), 0);
        assertEq(hook.earned(id, _pk(99)), 0);
    }

    function afterInvariant() public {
        handler.finish();
    }
}

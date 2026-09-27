// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {Test} from "forge-std/Test.sol";
import {FARMX} from "../src/FARMX.sol";
import {LiquidityMiningHook} from "../src/LiquidityMiningHook.sol";
import {SettlementRouter} from "./helpers/SettlementRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract RewardHandler is Test {
    LiquidityMiningHook public immutable hook;
    SettlementRouter public immutable router;
    FARMX public immutable token;
    PoolKey[2] private keys;
    uint256[4][2] public liquidity;
    uint256[4][2] public expectedStake;
    address[4][2] public beneficiaries;
    uint256 public funded;
    uint256 public paid;
    uint256 public claims;
    uint256 public additions;
    uint256 public removals;
    uint256 public fundings;

    constructor(LiquidityMiningHook h, SettlementRouter r, FARMX t, PoolKey memory a, PoolKey memory b) {
        hook = h;
        router = r;
        token = t;
        keys[0] = a;
        keys[1] = b;
        t.approve(address(h), type(uint256).max);
        t.approve(address(r), type(uint256).max);
    }
    receive() external payable {}

    function pool(uint256 i) public view returns (PoolId) {
        return keys[i].toId();
    }

    function pk(uint256 i) public view returns (bytes32) {
        return hook.positionKey(address(router), -887220, 887220, router.saltFor(address(this), bytes32(i)));
    }

    function advance(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 45 days));
    }

    function fund(uint8 pool_, uint96 amount_) external {
        uint256 p = pool_ % 2;
        uint256 amount = bound(amount_, 0, 1000 ether);
        uint256 received = hook.fund(keys[p], amount);
        assertEq(received, amount);
        funded += received;
        ++fundings;
    }

    function add(uint8 pool_, uint8 slot_, uint96 amount_, bool enroll) external {
        uint256 p = pool_ % 2;
        uint256 s = slot_ % 4;
        uint256 amount = bound(amount_, 1, 10 ether);
        address b = address(uint160(0x100 + s));
        bytes memory data = enroll ? abi.encode(b) : bytes("");
        router.modify{value: amount * 2}(
            keys[p], ModifyLiquidityParams(-887220, 887220, int256(amount), bytes32(s)), data
        );
        liquidity[p][s] += amount;
        if (beneficiaries[p][s] == address(0) && enroll) beneficiaries[p][s] = b;
        if (beneficiaries[p][s] != address(0)) expectedStake[p][s] += amount;
        ++additions;
    }

    function remove(uint8 pool_, uint8 slot_, uint96 amount_) external {
        uint256 p = pool_ % 2;
        uint256 s = slot_ % 4;
        if (liquidity[p][s] == 0) return;
        uint256 amount = bound(amount_, 0, liquidity[p][s]);
        router.modify(keys[p], ModifyLiquidityParams(-887220, 887220, -int256(amount), bytes32(s)), "");
        liquidity[p][s] -= amount;
        if (expectedStake[p][s] > liquidity[p][s]) expectedStake[p][s] = liquidity[p][s];
        ++removals;
    }

    function claim(uint8 pool_, uint8 slot_) external {
        uint256 p = pool_ % 2;
        uint256 s = slot_ % 4;
        address beneficiary = beneficiaries[p][s];
        if (beneficiary == address(0)) return;
        bytes32 position = pk(s);
        uint256 beforeBalance = token.balanceOf(beneficiary);
        vm.prank(beneficiary);
        uint256 amount = hook.claim(keys[p], position);
        assertEq(token.balanceOf(beneficiary) - beforeBalance, amount);
        paid += amount;
        ++claims;
    }
}

contract SolvencyInvariantTest is HookTestBase {
    using StateLibrary for IPoolManager;
    RewardHandler internal handler;

    function setUp() public override {
        super.setUp();
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, 79228162514264337593543950336);
        handler = new RewardHandler(hook, router, token, key, other);
        token.transfer(address(handler), 100_000_000 ether);
        vm.deal(address(handler), 1e30);
        // Include a persistent seed without a beneficiary from the start.
        handler.add(0, 0, uint96(100 ether), false);
        handler.fund(0, uint96(30 days * 1 ether));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RewardHandler.advance.selector;
        selectors[1] = RewardHandler.fund.selector;
        selectors[2] = RewardHandler.add.selector;
        selectors[3] = RewardHandler.remove.selector;
        selectors[4] = RewardHandler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_currency1AlwaysCoversEarnedUnstreamedAndIdleAcrossPools() public view {
        uint256 earned;
        uint256 remaining;
        uint256 idleTokens;
        uint256 reserve;
        uint256 claimed;
        uint256 funded;
        for (uint256 p; p < 2; ++p) {
            PoolId poolId = handler.pool(p);
            for (uint256 s; s < 4; ++s) {
                earned += hook.earned(poolId, handler.pk(s));
            }
            remaining += hook.unstreamed(poolId);
            idleTokens += hook.idle(poolId);
            reserve += hook.earnedReserve(poolId);
            claimed += hook.totalClaimed(poolId);
            funded += hook.totalFunded(poolId);
        }
        uint256 balance = token.balanceOf(address(hook));
        assertGe(balance, earned + remaining + idleTokens);
        assertEq(balance, reserve + remaining + idleTokens);
        assertLe(earned, reserve);
        assertEq(claimed, handler.paid());
        assertEq(funded, handler.funded());
        assertLe(claimed, funded);
        assertEq(balance + claimed, funded);
    }

    function invariant_stakeMatchesIndependentEnrollmentAndRemovalModel() public view {
        for (uint256 p; p < 2; ++p) {
            PoolId poolId = handler.pool(p);
            uint256 total;
            for (uint256 s; s < 4; ++s) {
                bytes32 position = handler.pk(s);
                uint256 stake = hook.staked(poolId, position);
                assertEq(stake, handler.expectedStake(p, s));
                assertEq(hook.beneficiaryOf(poolId, position), handler.beneficiaries(p, s));
                assertEq(manager.getPositionLiquidity(poolId, position), handler.liquidity(p, s));
                assertLe(stake, handler.liquidity(p, s));
                total += stake;
            }
            assertEq(hook.totalStaked(poolId), total);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UnusedCallbacks} from "./UnusedCallbacks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Permissionless, per-pool currency1 rewards for explicitly enrolled native-ETH liquidity.
/// @dev Beneficiaries are immutable, unauthenticated hookData supplied by a position's controller.
///      Use an authenticated router such as PositionManager, never a public shared-position router.
contract LiquidityMiningHook is UnusedCallbacks, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 public constant DURATION = 30 days;
    uint256 public constant SCALE = 1e18;
    // Bounds the lifetime accumulator even with one unit of staked liquidity.
    uint256 public constant MAX_FUNDED = type(uint256).max / SCALE;

    struct Stream {
        uint256 rate;
        uint256 end;
        uint256 updated;
        uint256 accumulator;
        uint256 total;
        uint256 idleTokens;
        uint256 funded;
        uint256 allocated;
        uint256 claimed;
    }

    struct Stake {
        address beneficiary;
        uint256 liquidity;
        uint256 paidAccumulator;
        uint256 rewards;
        uint256 fraction;
    }

    struct PositionRef {
        PoolId poolId;
        bytes32 positionKey;
    }

    mapping(PoolId => Stream) private streams;
    mapping(PoolId => mapping(bytes32 => Stake)) private stakes;
    mapping(address => PositionRef[]) private beneficiaryPositions;

    error UnsupportedPool();
    error PoolNotInitialized();
    error OnlyBeneficiary();
    error FundingLimit();

    event Staked(
        PoolId indexed poolId, bytes32 indexed positionKey, address indexed beneficiary, uint256 liquidity
    );
    event Unstaked(
        PoolId indexed poolId, bytes32 indexed positionKey, address indexed beneficiary, uint256 liquidity
    );
    event Funded(
        PoolId indexed poolId, address indexed funder, uint256 received, uint256 rewardRate, uint256 periodEnd
    );
    event Claimed(
        PoolId indexed poolId, bytes32 indexed positionKey, address indexed beneficiary, uint256 amount
    );

    constructor(IPoolManager manager) UnusedCallbacks(manager) {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterAddLiquidity = true;
        p.afterRemoveLiquidity = true;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external onlyPoolManager nonReentrant returns (bytes4, BalanceDelta) {
        if (Currency.unwrap(key.currency0) == address(0) && params.liquidityDelta > 0) {
            PoolId id = key.toId();
            bytes32 pk = positionKey(sender, params.tickLower, params.tickUpper, params.salt);
            Stake storage s = stakes[id][pk];
            if (s.beneficiary == address(0)) {
                address beneficiary = _beneficiary(hookData);
                if (beneficiary == address(0)) {
                    return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
                }
                s.beneficiary = beneficiary;
                beneficiaryPositions[beneficiary].push(PositionRef(id, pk));
            }
            _checkpoint(id, s);
            uint256 added = uint256(params.liquidityDelta);
            s.liquidity += added;
            streams[id].total += added;
            emit Staked(id, pk, s.beneficiary, added);
        }
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, BalanceDelta) {
        if (Currency.unwrap(key.currency0) == address(0)) {
            PoolId id = key.toId();
            bytes32 pk = positionKey(sender, params.tickLower, params.tickUpper, params.salt);
            Stake storage s = stakes[id][pk];
            if (s.beneficiary != address(0)) {
                _checkpoint(id, s);
                uint256 remaining = poolManager.getPositionLiquidity(id, pk);
                if (remaining < s.liquidity) {
                    uint256 removed = s.liquidity - remaining;
                    s.liquidity = remaining;
                    streams[id].total -= removed;
                    emit Unstaked(id, pk, s.beneficiary, removed);
                }
            }
        }
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Replaces the stream with received tokens + remaining stream + idle, over 30 days.
    /// @dev Zero funding is allowed to restart idle funds. Division remainder stays in idle.
    function fund(PoolKey calldata key, uint256 amount) external nonReentrant returns (uint256 received) {
        PoolId id = _supportedPool(key);
        (uint160 price,,,) = poolManager.getSlot0(id);
        if (price == 0) revert PoolNotInitialized();
        _update(id);
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        uint256 beforeBalance = token.balanceOf(address(this));
        if (amount != 0) token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - beforeBalance;
        Stream storage p = streams[id];
        if (received > MAX_FUNDED - p.funded) revert FundingLimit();
        p.funded += received;
        uint256 budget = received + _unstreamed(p) + p.idleTokens;
        p.rate = budget / DURATION;
        p.idleTokens = budget % DURATION;
        p.end = block.timestamp + DURATION;
        p.updated = block.timestamp;
        emit Funded(id, msg.sender, received, p.rate, p.end);
    }

    /// @notice Pays only the immutable beneficiary, including after all liquidity is removed.
    function claim(PoolKey calldata key, bytes32 pk) external nonReentrant returns (uint256 amount) {
        PoolId id = _supportedPool(key);
        Stake storage s = stakes[id][pk];
        if (s.beneficiary != msg.sender) revert OnlyBeneficiary();
        _checkpoint(id, s);
        amount = s.rewards;
        s.rewards = 0;
        streams[id].claimed += amount;
        if (amount != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(msg.sender, amount);
        emit Claimed(id, pk, msg.sender, amount);
    }

    function positionKey(address sender, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return Position.calculatePositionKey(sender, tickLower, tickUpper, salt);
    }

    function beneficiaryOf(PoolId id, bytes32 pk) external view returns (address) {
        return stakes[id][pk].beneficiary;
    }

    function staked(PoolId id, bytes32 pk) external view returns (uint256) {
        return stakes[id][pk].liquidity;
    }

    function totalStaked(PoolId id) external view returns (uint256) {
        return streams[id].total;
    }

    function rewardRate(PoolId id) external view returns (uint256) {
        return streams[id].rate;
    }

    function periodEnd(PoolId id) external view returns (uint256) {
        return streams[id].end;
    }

    function totalFunded(PoolId id) external view returns (uint256) {
        return streams[id].funded;
    }

    function totalClaimed(PoolId id) external view returns (uint256) {
        return streams[id].claimed;
    }

    function positionsOf(address beneficiary) external view returns (PositionRef[] memory) {
        return beneficiaryPositions[beneficiary];
    }

    function positionCount(address beneficiary) external view returns (uint256) {
        return beneficiaryPositions[beneficiary].length;
    }

    function positionAt(address beneficiary, uint256 index) external view returns (PositionRef memory) {
        return beneficiaryPositions[beneficiary][index];
    }

    function rewardPerLiquidity(PoolId id) public view returns (uint256) {
        Stream storage p = streams[id];
        return p.accumulator + (p.total == 0 ? 0 : FullMath.mulDiv(_pending(p), SCALE, p.total));
    }

    function earned(PoolId id, bytes32 pk) public view returns (uint256) {
        Stake storage s = stakes[id][pk];
        uint256 delta = rewardPerLiquidity(id) - s.paidAccumulator;
        return s.rewards + FullMath.mulDiv(s.liquidity, delta, SCALE)
            + (mulmod(s.liquidity, delta, SCALE) + s.fraction) / SCALE;
    }

    function unstreamed(PoolId id) external view returns (uint256) {
        return _unstreamed(streams[id]);
    }

    function idle(PoolId id) external view returns (uint256) {
        Stream storage p = streams[id];
        return p.idleTokens + (p.total == 0 ? _pending(p) : 0);
    }

    /// @notice Conservative outstanding reward reserve, including accumulator rounding dust.
    function earnedReserve(PoolId id) external view returns (uint256) {
        Stream storage p = streams[id];
        return p.allocated - p.claimed + (p.total == 0 ? 0 : _pending(p));
    }

    function _checkpoint(PoolId id, Stake storage s) private {
        _update(id);
        uint256 accumulator = streams[id].accumulator;
        uint256 delta = accumulator - s.paidAccumulator;
        uint256 fraction = mulmod(s.liquidity, delta, SCALE) + s.fraction;
        s.rewards += FullMath.mulDiv(s.liquidity, delta, SCALE) + fraction / SCALE;
        s.fraction = fraction % SCALE;
        s.paidAccumulator = accumulator;
    }

    function _update(PoolId id) private {
        Stream storage p = streams[id];
        uint256 emission = _pending(p);
        if (p.total == 0) {
            p.idleTokens += emission;
        } else {
            p.accumulator += FullMath.mulDiv(emission, SCALE, p.total);
            p.allocated += emission;
        }
        p.updated = block.timestamp < p.end ? block.timestamp : p.end;
    }

    function _pending(Stream storage p) private view returns (uint256) {
        uint256 until = block.timestamp < p.end ? block.timestamp : p.end;
        return (until - p.updated) * p.rate;
    }

    function _unstreamed(Stream storage p) private view returns (uint256) {
        return block.timestamp < p.end ? (p.end - block.timestamp) * p.rate : 0;
    }

    function _supportedPool(PoolKey calldata key) private view returns (PoolId) {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)
                || address(key.hooks) != address(this)
        ) revert UnsupportedPool();
        return key.toId();
    }

    // Reject malformed ABI words without reverting a factory/router liquidity operation.
    function _beneficiary(bytes calldata data) private pure returns (address) {
        if (data.length != 32) return address(0);
        uint256 word;
        assembly ("memory-safe") { word := calldataload(data.offset) }
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only router: salts are scoped to the calling payer so positions are not shared.
contract SettlementRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;

    struct Request {
        bool swap;
        bool skipSettlement;
        address payer;
        PoolKey key;
        ModifyLiquidityParams liquidity;
        SwapParams trade;
        bytes data;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    receive() external payable {}

    function saltFor(address caller, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(caller, salt));
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory data)
        external
        payable
        returns (BalanceDelta)
    {
        params.salt = saltFor(msg.sender, params.salt);
        Request memory r;
        r.payer = msg.sender;
        r.key = key;
        r.liquidity = params;
        r.data = data;
        return _execute(r);
    }

    function swap(PoolKey memory key, SwapParams memory params, bool skipSettlement)
        external
        payable
        returns (BalanceDelta)
    {
        Request memory r;
        r.swap = true;
        r.skipSettlement = skipSettlement;
        r.payer = msg.sender;
        r.key = key;
        r.trade = params;
        return _execute(r);
    }

    function _execute(Request memory r) private returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(r)), (BalanceDelta));
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        Request memory r = abi.decode(data, (Request));
        BalanceDelta delta;
        if (r.swap) delta = manager.swap(r.key, r.trade, r.data);
        else (delta,) = manager.modifyLiquidity(r.key, r.liquidity, r.data);
        if (!r.skipSettlement) {
            _settle(r.key.currency0, delta.amount0(), r.payer);
            _settle(r.key.currency1, delta.amount1(), r.payer);
        }
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, payer, uint128(delta));
        }
    }
}

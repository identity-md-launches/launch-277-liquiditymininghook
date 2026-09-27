# ABI and integration

Machine-readable JSON ABI arrays:

- `docs/abi/FARMX.json`
- `docs/abi/LiquidityMiningHook.json`

Regenerate after source changes:

```sh
forge inspect FARMX abi --json > docs/abi/FARMX.json
forge inspect LiquidityMiningHook abi --json > docs/abi/LiquidityMiningHook.json
```

FARMX implements the OpenZeppelin ERC-20 interface: name, symbol, decimals, totalSupply, balanceOf,
allowance, approve, transfer and transferFrom, plus Transfer/Approval and standard ERC-20 errors.
Infinite allowances are not consumed. Zero-address transfers/approvals revert. Its constructor takes
no parameters, and no external mint or administrative function exists.

## Hook inputs and keys

`PoolKey` ABI field order is `(address currency0, address currency1, uint24 fee, int24 tickSpacing,
address hooks)`. Currency and PoolId are ABI-encoded as address and bytes32 respectively.
`positionKey(sender, tickLower, tickUpper, salt)` returns Uniswap's packed key hash. PositionManager
uses its own address as sender and `bytes32(tokenId)` as salt. Read ticks from the position's NFT/state.
Do not hash the wallet address in place of the position controller.

`hookData = abi.encode(beneficiary)` is exactly 32 bytes. It is not signed or authenticated by this hook.
A noncanonical word or zero address is treated as no enrollment. Once set, new data cannot change the
beneficiary. Neither NFT transfer nor NFT ownership grants claim rights.

| Function | Behavior / units |
| --- | --- |
| `getHookPermissions()` | 14 booleans; only afterAddLiquidity and afterRemoveLiquidity true |
| `poolManager()` | immutable authorized callback caller |
| `fund(key, amount) → received` | pull raw currency1 units; amount zero may restart idle/remaining tokens |
| `claim(key, positionKey) → amount` | beneficiary-only gross raw currency1 payout to caller; zero claims allowed |
| `earned(poolId, positionKey)` | immediately claimable raw currency1, including elapsed emissions |
| `beneficiaryOf(poolId, positionKey)` | permanent recipient, or zero if never enrolled |
| `staked(poolId, positionKey)` | reward-eligible liquidity units, not token amounts or active liquidity |
| `totalStaked(poolId)` | sum of enrolled position liquidity, including out-of-range liquidity |
| `rewardRate(poolId)` | raw currency1 units/second; stored rate remains readable after period end |
| `periodEnd(poolId)` | Unix seconds; emissions stop at this timestamp |
| `rewardPerLiquidity(poolId)` | elapsed-time-adjusted cumulative reward per liquidity, scaled by 1e18 |
| `positionsOf(beneficiary)` | historical `(bytes32 poolId, bytes32 positionKey)[]`, including withdrawn keys |
| `positionCount(beneficiary)` | historical reference count |
| `positionAt(beneficiary, index)` | one reference for bounded pagination; out-of-bounds reverts |
| `unstreamed(poolId)` | remaining time × rate, zero after end |
| `idle(poolId)` | accrued zero-stake emissions plus integer duration remainder, current as of call |
| `earnedReserve(poolId)` | conservative unclaimed reward allocation, including pool accumulator rounding dust |
| `totalFunded(poolId)` | lifetime tokens actually received via fund, excludes direct donations |
| `totalClaimed(poolId)` | lifetime gross claim transfers |
| `DURATION()`, `SCALE()`, `MAX_FUNDED()` | source constants documented in README |

`positionsOf` can be large; use `positionCount` and `positionAt` for large accounts. It appends only on
first enrollment of a pool/key pair and never removes entries. No transaction iterates that list.
Unknown pool and position views return zero/empty. Funding an uninitialized supported pool reverts.

Enabled liquidity callbacks accept the standard v4 arguments, authenticate the manager, and return
`(callback selector, BalanceDelta(0))`. No hook settlement is required. Other callbacks authenticate
and revert `CallbackDisabled`; their address permissions are disabled, so PoolManager will not call
them during normal operations. All methods are nonpayable; no payable receive/fallback exists.

## Events

All liquidity and reward amounts below are changes, not new totals.

```solidity
event Staked(bytes32 indexed poolId, bytes32 indexed positionKey, address indexed beneficiary, uint256 liquidity);
event Unstaked(bytes32 indexed poolId, bytes32 indexed positionKey, address indexed beneficiary, uint256 liquidity);
event Funded(bytes32 indexed poolId, address indexed funder, uint256 received, uint256 rewardRate, uint256 periodEnd);
event Claimed(bytes32 indexed poolId, bytes32 indexed positionKey, address indexed beneficiary, uint256 amount);
```

Staked fires for enrolled positive additions only. Unstaked fires only when the recorded stake actually
falls; removal of pre-enrollment liquidity and fee collection may therefore produce no hook event.
Funded reports net receipt and the newly computed schedule, including for amount zero. Claimed reports
the gross debit, including zero claims; a taxed currency1 may deliver less to the recipient. Failed
transactions have no committed events or changes.

Callers should handle `OnlyPoolManager`, `CallbackDisabled`, `InvalidPoolManager`, `UnsupportedPool`,
`PoolNotInitialized`, `OnlyBeneficiary`, `FundingLimit`, reentrancy and ERC-20 transfer errors. Deployment
at incorrect address bits reverts with Uniswap's `HookAddressNotValid`.

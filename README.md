# Farm / FARMX liquidity mining

Farm is a **Sepolia test toy**. FARMX and reward pots have no value; nothing here promises a return.

This contribution implements the fixed-supply token and liquidity-mining hook, exports their ABIs,
and rehearses the launch with a real Uniswap v4 PoolManager. The separate manifest and independent
review assignments, followed by publication, attestation, admission and deployment services, complete
the launch workflow. No transactions have been broadcast by this project.

## Build and check

```sh
forge build
forge test
forge fmt --check
```

Solidity **0.8.26**, Cancun, optimizer 200 runs, and `bytecode_hash = "none"` are pinned in
[foundry.toml](foundry.toml). All imported dependencies are ordinary files in `lib/`; no package
installation, submodules, environment variables, RPC, FFI, or filesystem cheatcodes are required.
The verifier supplies the pinned compiler. Vendored revisions and source licenses are recorded in
[docs/dependencies.json](docs/dependencies.json). Upstream library files are excluded from formatting.

## Contracts

- [FARMX](src/FARMX.sol): name `Farm`, symbol `FARMX`, 18 decimals. The zero-argument constructor
  mints exactly 1,000,000,000 FARMX to `msg.sender`. No further mint, burn, owner, admin or upgrade.
- [LiquidityMiningHook](src/LiquidityMiningHook.sol): one constructor argument, `IPoolManager`.
  No admin, setter, pause, sweep or upgrade. Only `afterAddLiquidity` and `afterRemoveLiquidity`
  permissions are enabled, validated by `Hooks.validateHookPermissions` during construction.
  The low 14 address bits must equal **0x0500**. Every callback authenticates the PoolManager;
  disabled callbacks revert if called. Enabled callbacks always return zero hook deltas.

The hook never takes swap fees, accepts ETH, creates ERC-6909 claims, or changes swap settlement.
The router pays PoolManager debt with `sync → transfer → settle` for ERC-20s, or `sync → settle{value}`
for native ETH, and withdraws credits with `take`. The hook holds currency1 rewards separately.

## Staking and rewards

All accounting is keyed by `PoolId = keccak256(abi.encode(poolKey))`. Only pools with native ETH as
currency0 are eligible. Other pools initialize and modify liquidity normally; callbacks return zero
deltas without touching reward accounting. Funding/claiming an unsupported key reverts. Funding also
requires an initialized pool and this hook in the pool key.

The position key is Uniswap's `keccak256(abi.encodePacked(sender, tickLower, tickUpper, salt))`.
For PositionManager, `sender` is PositionManager and `salt` is `bytes32(tokenId)`, **not** the wallet.

A positive addition enrolls a key only when `hookData` is exactly one canonical 32-byte ABI address
word containing a nonzero beneficiary. Missing, zero, short, long or noncanonical words are ignored
without reverting the addition. Only that addition's liquidity and future additions count. Earlier
liquidity, including the factory seed, never enters the reward denominator. Once enrolled, every
positive addition counts for the fixed beneficiary, even without hookData or with another address.

Before a stake change or claim, the hook checkpoints the pool accumulator, then the position. After
removal, its stake becomes `min(previousStake, positionLiquidityAfterRemoval)`, read from the real
PoolManager with `StateLibrary`. Consequently, un-enrolled liquidity is exhausted first. Delta-zero
fee collection does not unstake. Full withdrawal preserves accrued rewards and the beneficiary;
re-adding to the same key cannot replace that beneficiary. NFT transfer does not transfer rewards.
**Out-of-range liquidity earns at the same rate as in-range liquidity**, an intentional simplification.

Anyone may `fund(poolKey, amount)` after approving the hook for currency1. The hook counts the actual
balance increase, checkpoints elapsed time, and computes:

```text
budget = received + remainingSeconds * oldRate + idle
rate = floor(budget / 30 days)
periodEnd = now + 30 days
idle = budget modulo 30 days
```

Elapsed emissions with zero staked liquidity accumulate in idle. A subsequent fund call re-streams
those tokens; `fund(key, 0)` is permitted. Elapsed emissions while stakes exist increase
`rewardPerLiquidity` by `floor(emission * 1e18 / totalStaked)`. Claims are restricted to the immutable
beneficiary and pay that address, with effects applied before the token transfer and a reentrancy guard.
A failed transfer rolls back the accounting. Incoming fee-on-transfer rewards are credited net; an
outgoing transfer tax reduces the beneficiary's net receipt, while `Claimed.amount` reports the gross
amount debited from the hook.

## Assumptions and operational limits

- `hookData` is unauthenticated. The hook deliberately accepts any position controller rather than
  maintaining an owner-controlled router allowlist. A controller can select any beneficiary. Use
  Uniswap's published Sepolia PositionManager and check it has code. Never use the unguarded
  `PoolModifyLiquidityTest` for public positions: anyone able to modify a shared key can enroll its
  future liquidity first, add to it, or withdraw it. PositionManager's NFT authorization is tested.
- A beneficiary is permanent, including after burn/withdrawal. An accidental or inaccessible address
  permanently loses access to rewards. Beneficiaries that are contracts must be able to call `claim`.
- Permissionless funding can restart/extend the 30-day window, including with zero tokens. An attacker
  can repeatedly slow emissions; this follows the requested public restart semantics. There is no
  timelock or privileged operator that can override it.
- Integer rate remainder is retained in idle, and position-level fractional rewards survive claims
  and stake changes. Pool accumulator divisions round down at each checkpoint. That difference remains
  in the conservative earned reserve, cannot be swept, and is not silently recycled as somebody else's
  reward. For a checkpoint its loss is less than `totalStaked / 1e18` raw token units. Frequent checkpoints
  at a tiny reward-to-liquidity ratio can make this loss material; this is the specified 1e18-scaled
  Synthetix-style precision tradeoff. The invariant treats this as reserved surplus, not claimable earnings.
- Lifetime received funding per pool is bounded by `uint256.max / 1e18` raw units so that even a
  one-unit stake cannot overflow the accumulator. This is vastly above FARMX's fixed supply.
- Solvency assumes an honest ERC-20 balance implementation, no downward rebases, and no extra sender
  debit beyond the transfer amount. FARMX meets those assumptions. Arbitrary malicious/rebasing tokens
  are not made safe by the balance-difference funding check. A blocked/failed reward transfer leaves
  rewards claimable for retry; it does not block LP withdrawal.
- Send rewards using `fund`. Direct token donations are unaccounted surplus and cannot be recovered.
  Ordinary ETH sends revert; forced ETH cannot be prevented and has no recovery path.
- This is an offline implementation suite, not an independent audit or a live Sepolia factory fork.
  The numeric price and seed allocation were absent from the supplied workflow; the explicit proposed
  parameters in [script/LaunchParameters.sol](script/LaunchParameters.sol) must be aligned with the
  independently generated manifest. See [deployment handoff](docs/deployment.md).

## Verification coverage

`test/Launch.t.sol` mines and deploys the hook without replacing its code, initializes a real
PoolManager at the proposed manifest price, seeds currency1-only liquidity with empty hookData,
and executes the first buy while the pool initially holds zero ETH. It checks both directions of
exact-in/exact-out swaps, dust, fuzzed sizes, zero hook deltas, complete settlement, failed settlement
rollback, ERC-20/ERC-20 inertness, all callback caller checks, permission bits, constructor rejection,
ETH refusal and runtime escape opcodes.

`test/Rewards.t.sol` checks staggered and unequal stakes, checkpoint ordering, seed exclusion,
late enrollment, partial/full withdrawals, fee collection, immutable beneficiaries, invalid hookData,
idle re-streaming, top-ups, duration and fractional dust, out-of-range stakes, per-pool isolation,
events, views, authorization and fuzzed reward conservation.

`test/PositionManager.t.sol` uses the real vendored PositionManager for mint/increase/decrease,
delta-zero collection, burn with remaining liquidity, burn after full decrease, transfer and
unauthorized modifications. Its allowance-only Permit2 mock enforces caller-specific approvals and
expiration; it does not test signatures or production Permit2 bytecode. No WETH wrapping or descriptor
calls are exercised. Both placeholders are zero in this test fixture only.

`test/Adversarial.t.sol` checks net fee-on-transfer funding, failed funding/claims, reentrant funding
and claims, and the accumulator/funding boundary. `test/FARMX.t.sol` checks supply, transfer/allowance
semantics and absence of common privileged selectors.

`test/Invariant.t.sol` targets only a bounded action handler (128 runs × 64 calls, fail on revert).
It randomizes time, funding, adds, removals and claims across two pools sharing FARMX, including keys
with pre-enrollment liquidity. An independent model tracks stake enrollment/removal. At every step:

```text
hook balance >= sum(actual earned-but-unclaimed + unstreamed + idle)
hook balance == sum(conservative earnedReserve + unstreamed + idle)
hook balance + total claimed == total received funding
sum(position stakes) == totalStaked
position stake <= actual PoolManager position liquidity
```

The ABIs and integration descriptions are in [docs/abi](docs/abi) and [docs/interface.md](docs/interface.md).

# Deployment handoff

This contribution produces source, tests and ABI exports. The manifest assignment owns `launch.json`;
this project intentionally does not generate one. Independent reviewers inspect the accepted source and
manifest without changing them. Services publish source, attest, admit and deploy, then start frontend
work. Policy and signed artifact linkage belong to those services. The tests are not an independent
review and do not imply admission or deployment.

## Concrete contract parameters

| Item | Value |
| --- | --- |
| Chain | Sepolia, 11155111 |
| Token artifact | `src/FARMX.sol:FARMX` |
| Token constructor | zero arguments |
| Token name / symbol | Farm / FARMX |
| Decimals / supply | 18 / 1,000,000,000 FARMX (`1000000000000000000000000000` raw units) |
| Initial token holder | constructor `msg.sender`, expected launch factory |
| Hook artifact | `src/LiquidityMiningHook.sol:LiquidityMiningHook` |
| Hook constructor | one ABI-encoded address, `IPoolManager` |
| Sepolia PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Address permission mask | low 14 bits exactly `0x0500` |
| Pool currencies | currency0 `address(0)`; currency1 newly deployed FARMX |
| Fee / tick spacing | 3000 / 60 |
| Reward duration / scale | 2,592,000 seconds / 1e18 |
| Website label | `lab-liquidity-mining-hook` |

There is no `$owner`, `$token`, reward-rate, recipient, threshold, or window constructor argument.
The hook learns its reward token from each pool key. A different PoolManager is supplied only for
local testing; deployment services must enforce the Sepolia address and chain.

## Explicit price/seed assumptions

No manifest, numeric initial price, factory source or numeric seed allocation was supplied as an input.
The following proposal makes the rehearsal concrete and is recorded in `script/LaunchParameters.sol`:

| Parameter | Proposed value |
| --- | --- |
| `sqrtPriceX96` | `79228162514264337593543950336` (2^96) |
| Raw currency1/currency0 price | 1 (both FARMX and ETH use 18 decimal units) |
| Seed tick lower / upper | -887220 / 0 |
| Seed liquidity | `100000000000000000000000000` (100,000,000 × 1e18 liquidity units) |
| Seed hookData | empty |

At the upper boundary the seed requires only FARMX and zero ETH. An ETH-to-FARMX buy lowers the
price and enters that range. Seed liquidity units are not a token allocation: the actual required
FARMX is the rounded PoolManager delta. The offline rehearsal asserts both that delta0 is zero and
that PoolManager holds zero ETH immediately before the first buy. The test runner acts as the token
deployer; its settlement harness performs the factory-shaped seed operation. The harness is test
scaffolding, not the actual launch factory implementation.

The manifest producer must use matching numeric parameters or flag the concrete mismatch for review
and have the rehearsal updated. A live factory rehearsal must use the accepted manifest's exact price,
seed algorithm, allocation, and actual factory bytecode. This local test does not claim that a missing
factory artifact or a live fork has been verified.

## Deterministic hook placement

Compile with the pinned settings, then form:

```text
initCode = hookCreationBytecode || abi.encode(sepoliaPoolManager)
initCodeHash = keccak256(initCode)
predicted = last20(keccak256(0xff || actualCREATE2Deployer || salt32 || initCodeHash))
accept iff uint160(predicted) & 0x3fff == 0x0500
```

Mine against the **actual contract executing CREATE2**, not the transaction sender. Constructor
arguments, factory address, compiler settings and any source change alter the candidate address.
Use the final accepted artifacts and re-mine after any bytecode change. The constructor independently
checks the complete permission set; no test overrides that validation or etches hook runtime code.
`test/helpers/HookTestBase.sol` contains the bounded salt search used by all tests.

The factory must deploy FARMX with no arguments and receive the entire supply, deploy the mined hook
with the one PoolManager argument, initialize the native/FARMX pool, and settle its token-only seed
with empty hookData. Neither initialize callback is enabled. Its seed gets no beneficiary, stake or
rewards. An initial buy supplies the first ETH to the pool. Funding the reward stream is a separate
ERC-20 approval and `fund` transaction; seed tokens are not reward tokens.

## Responsibility after acceptance

The independent adversarial reviewer should inspect accumulator ordering, PositionManager increase /
decrease / burn / zero-delta paths, shared-key enrollment, idle and rounding behavior, incoming transfer
taxes, the lifetime funding bound and per-token solvency across pools. `README.md` discloses the
permissionless restart and precision tradeoffs; review findings should include exact triggering calls.

Deployment services select and verify the published Sepolia PositionManager, Permit2 and StateView,
check their code and chain, run the accepted factory rehearsal, and link their signed artifacts and
policy decisions. The website assignment produces `dist/index.html` after deployment using the real
addresses. It reads views/events and StateView, uses authenticated PositionManager actions, and mints
only full-range positions (-887220 to 887220) with `abi.encode(connectedWallet)` as hookData. The seed's
one-sided range is intentionally different from this user-facing full-range mint form.

Funders approve the hook and choose when to fund/restart streams. LP controllers choose the immutable
beneficiary and manage their NFTs; only that beneficiary claims. There is no operator that can rescue
funds, move beneficiaries, pause withdrawals, alter rates outside public funding, or upgrade either
contract. Monitor stream ends, idle amounts and balance coverage using the exported views and events.

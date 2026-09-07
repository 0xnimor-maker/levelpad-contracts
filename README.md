# LEVELPAD StockFeeHook — routing review package

Source and reproducible, read-only evidence for the deployed LEVELPAD Uniswap v4
hook on **Robinhood Chain mainnet (chain ID 4663)**. Website:
[levelpad.live](https://levelpad.live).

The deployed hook has **verified source with an exact bytecode match** on
[Robinhood Blockscout](https://robinhoodchain.blockscout.com/address/0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC?tab=contract)
and [Sourcify](https://repo.sourcify.dev/4663/0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC).
This is a routing compatibility submission package. Source verification does
not imply Uniswap routing approval, an independent security audit, or endorsement.

## Deployment under review

| Component | Address |
| --- | --- |
| StockFeeHook | `0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC` |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| UniversalRouter | `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` |
| Official Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| UniswapV4LaunchFactory | `0xD694E7FeeE14b7685dCf6894f0430a7434152728` |
| UniswapV4MarketDeployer | `0xf4d33cFe8166De89606cd693b028fb6AAe177267` |
| StockRegistry | `0x588ac3EBEAADfEB22c94090825D491C1cCCA4583` |

The hook's deployed runtime hash is
`0xe8abee375bccff5335840677cca23433f59c26f08a83b98030e05680a3a028e9`
(6,665 bytes). The matching compiler is **Solidity 0.8.30+commit.73712a01**, with
optimizer enabled, 200 runs, `viaIR: true`, and `evmVersion: shanghai`.

The creation bytecode, constructor argument, CREATE2 deployment input, complete
runtime, immutable manager slots, and Solidity metadata were checked against
chain data. See [source verification evidence](verification/source-verification.json),
[Blockscout verification](verification/SOURCE-VERIFICATION.md), and
[Sourcify exact-match evidence](verification/sourcify-verification.json).
The self-contained standard JSON contains all 19 hook compilation source files.
The related contracts in `contracts/` provide review context; the bytecode-match
claim here is specifically for **StockFeeHook**, not every dependency contract.

## Fee behavior and routing restrictions

The hook charges a fixed **1% platform fee**, plus a per-pool creator fee selected
at registration (**0–10% per direction**). Both use the pool's stock/quote asset.
Pool configuration cannot be changed through a hook administrator: the hook has
no owner setter, upgrade proxy, or mutable fee setter. The supported key uses LP
fee **3000 (0.30%)** and tick spacing **60**. LP fees are separate from hook fees.

Hook callbacks are `beforeInitialize`, `beforeSwap`, and `afterSwap`, including
before/after swap return deltas. Registration is bound to the token's launcher;
initialization is restricted to the registered liquidity lock. The hook itself
does not limit registrations to the particular platform factory above.

Creator fees are transferred to the per-pool liquidity lock. Its fixed split can
fund creator receipts, holder dividends, token burns and added liquidity.
`previewFee` and `accrueFees` are external calls to that registered processor.
The supplied official lock's `previewFee` returns the nominal fee; the hook does
not independently enforce that behavior on arbitrary third-party processors.

**Important execution-order requirement:** token-to-stock sells must settle the
input tokens to PoolManager **before** calling swap. Otherwise the hook reverts
with `SellInputMustBeSettled`. This ensures seller token balances are updated
before the sale's dividend accounting. The immutable official Quoter is exempt
for its reverting simulations; its code hash is checked at construction.

The working UniversalRouter v4 actions are:

```
SETTLE -> SWAP_EXACT_IN_SINGLE -> TAKE_ALL
actions: 0x0b060f; UniversalRouter command: 0x10
```

The alternative `SWAP_EXACT_IN_SINGLE -> SETTLE_ALL -> TAKE_ALL` (`0x060c0f`)
failed in the recorded full-router sell simulation. **Allowlisting alone must
not be assumed to make that execution order compatible.** The simulation uses
the Robinhood router's deployed swap tuple, including `minHopPriceX36 = 0`.
The optional per-hop bound is disabled, while a positive output minimum remains.
No custom hook data is required (`0x`).

Only exact-input swaps are accepted. Partial fills are rejected. Very small
trades can fail `TradeBelowFeePrecision` when the platform fee rounds to zero.
Stock transfers must credit/debit exactly the expected amount; paused or
otherwise incompatible underlying assets can therefore stop swaps. Supporting
every multi-hop route or wallet's native swap interface has not been verified.

## Example pool: TEST_ON_LEVEL / NVDA

| Field | Value |
| --- | --- |
| Symbol | TEST |
| Token | `0x15A577539bcE757325F244cE21CC1d6E087E9587` |
| Stock / currency1 | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` (NVDA) |
| Sale | `0x274a15a17F8AbA1863D60525ACDa793543C67259` |
| Liquidity lock | `0xdfbce8B28EB5D623edf887E824E9875f044cB227` |
| Creator fee | 1% buy; 1% sell, plus the fixed 1% platform fee |
| Snapshot block | 56965787 |
| Active liquidity | 8660254037844386467637, nonzero |

Pool ID:

```
0xb08d965341dd33120179c219b7e4ab85f8c2b319db8a41c6ff3390ad38b3df09
```

The snapshot recorded approximately 432,605,353.4322 TEST and
0.173368173567341048 NVDA in the lock's position. These are historical amounts,
not a current price or liquidity guarantee. The pool has two successful buys
and two successful sells through the official UniversalRouter in the recorded
evidence. Representative transactions:

- [Initialization](https://robinhoodchain.blockscout.com/tx/0xaf866fd67efc79494e2b36b3842b4eaa4cdcd539a7528a6373e6ea4c5226b247)
- [Successful buy](https://robinhoodchain.blockscout.com/tx/0x2573ef2829b71b2818821f5c2cd3cf58fcf6ceba4473b4133d16501521564366)
- [Successful sell](https://robinhoodchain.blockscout.com/tx/0xfe509fa2326c6fb0d01d360725a0115d09c65b75b19235b31ad9e3dd439aeb8a)

The same account sold 1,000,000 TEST in two **read-only simulations** at the same
block, using its actual balance and allowances with no state overrides. The
settle-first route passed; the swap-first route reverted as described above.
Full amounts, logs, receipts and revert data are in [evidence/test-pool.json](evidence/test-pool.json).
The historical successful transactions already existed on chain; the verification
scripts do not submit transactions.

## Reproduce checks

Use Node.js 22.13.0 or newer:

```sh
npm ci --ignore-scripts
npm run compile
npm run verify
```

`compile` recompiles the self-contained hook input and all included related
contracts against pinned dependencies. It writes only ignored local artifacts.
`verify` recompiles the hook, compares its full runtime with on-chain code,
checks the CREATE2 deployment input, Pool ID/key, liquidity and recorded
receipts, then simulates both sell orders when the recorded account still has
sufficient balance and allowances. It uses only read RPC methods, never a
private key, wallet connection or transaction broadcast.

The default endpoint is the public Robinhood mainnet RPC. A reviewer may supply
`RPC_URL` through the environment, without changing repository files. Do not
commit authenticated endpoints. The script suppresses raw provider error text.
Set `VERIFY_BLOCK=56965787` to repeat the historical snapshot simulations with
an archive-capable RPC. By default it checks a current block; account balances,
allowances and quotes can change, and insufficient current allowance causes the
simulation section to be skipped rather than fabricating a successful result.

This package contains application evidence and source only. It contains no
deployment tools, signing keys, private RPC configuration, server access files,
or application contact details. See [third-party notices](THIRD-PARTY-NOTICES.md).

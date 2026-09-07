# Sourcify exact-match verification

Public source verification is confirmed for LEVELPAD's deployed StockFeeHook on
Robinhood Chain, chain ID **4663**:

- Address: `0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC`.
- Overall, creation and runtime match: **`exact_match`**.
- Verification timestamp: `2026-09-07T16:40:35Z`.
- Sourcify match ID: `47245666`.
- Contract: `contracts/StockFeeHook.sol:StockFeeHook`.
- Compiler: `0.8.30+commit.73712a01`, optimizer 200 runs, viaIR, Shanghai.
- Runtime code hash: `0xe8abee375bccff5335840677cca23433f59c26f08a83b98030e05680a3a028e9`.
- All 19 verified Solidity files exactly match `StockFeeHook.standard-input.json`.

[Public verified contract](https://repo.sourcify.dev/4663/0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC)

[Read-only verification API](https://sourcify.dev/server/v2/contract/4663/0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC?fields=all)

The exact-match response and per-source comparison are recorded in
`sourcify-verification.json`. This result was inspected through a GET request;
the response does not identify who originally submitted verification.

The official [Robinhood Blockscout contract page](https://robinhoodchain.blockscout.com/address/0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC?tab=contract)
was also confirmed to display verified source with an exact match. See
`SOURCE-VERIFICATION.md` for that observation and the preserved compiler inputs.

Source verification confirms that published code matches a deployed contract.
It does not imply Uniswap routing approval, an independent security audit, or
approval of every possible execution order.

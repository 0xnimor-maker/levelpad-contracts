# LEVELPAD StockFeeHook source verification

The deployed hook's source verification is confirmed on Robinhood Blockscout and Sourcify. This package preserves the exact compiler input and read-only reproduction evidence. Its verification scripts do not send blockchain transactions.

## Exact deployed contract match

- Chain: Robinhood Chain mainnet, chain ID `4663`.
- Contract: `0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC`.
- Solidity identifier: `contracts/StockFeeHook.sol:StockFeeHook`.
- Compiler: `v0.8.30+commit.73712a01`.
- Optimizer: enabled, 200 runs. `viaIR: true`. EVM version: `shanghai`.
- Constructor: one `address manager`, `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
- SPDX license of StockFeeHook: MIT.
- Source input: `StockFeeHook.standard-input.json`, including all 19 required source files.
- Constructor arguments, ABI-encoded without `0x`: `constructor-arguments.txt`.
- Deployment transaction: `0xc5297a0dfdd97d1d91fa417bee05d4de4cfcf3cc4c79c5ccae48a8fc6f11f934`, block `56790590`.
- Runtime code hash: `0xe8abee375bccff5335840677cca23433f59c26f08a83b98030e05680a3a028e9`, 6,665 bytes.

At block `56980779`, the locally compiled creation bytecode exactly matched the archived deployment artifact and the init code in the actual CREATE2 deployment transaction. The complete runtime matched on-chain code byte for byte after substituting all immutable `poolManager` slots; this includes Solidity metadata. The standalone standard JSON input was separately recompiled with no import callback and produced the same creation bytecode. See `source-verification.json` for the machine-readable evidence.

## Blockscout status

The official Blockscout contract page visibly displays **verified source with an exact match**. The browser check confirmed compiler `v0.8.30+commit.73712a01`, EVM `shanghai`, optimizer 200 runs, source path `contracts/StockFeeHook.sol`, and the correct constructor manager. The page's verification timestamp was displayed as **Sep 8, 2026, 00:40:47**; this is the UI timestamp as observed, without inferring an unlabelled timezone.

Official contract page:

https://robinhoodchain.blockscout.com/address/0x21a4CF32F7Ff2dC8c88A2fb7cD12Ad25bD2fA0cC?tab=contract

Sourcify independently reports `exact_match` for both creation and runtime bytecode, with verification timestamp `2026-09-07T16:40:35Z` and match ID `47245666`. Its 19 source files match this package's standard JSON input byte for byte. See `SOURCIFY-VERIFICATION.md` and `sourcify-verification.json`.

These confirmations apply to this exact hook address and chain. Source verification establishes a code match; it does not establish routing approval or a security-audit result.

## Preserved verification submission parameters

Blockscout documents the Etherscan-compatible endpoint:

`POST https://robinhoodchain.blockscout.com/api?module=contract&action=verifysourcecode`

Use multipart form fields from `blockscout-verification-fields.json`, replacing the helper `sourceCodeFile` field with `sourceCode` containing the complete text of `StockFeeHook.standard-input.json`. The compiler settings are embedded in that file. The constructor arguments are the single ABI-encoded manager address, **not** the CREATE2 salt. If the instance requests autodetection, the CREATE2 init code is recorded in the deployment transaction above.

The documented PRO API is an alternative when an authorized Blockscout API key is available:

`POST https://api.blockscout.com/v2/api?chain_id=4663&module=contract&action=verifysourcecode&apikey=<API_KEY>`

This package contains no API key. Do not put private RPC credentials in the verification payload, GitHub repository, or application.

On acceptance, Blockscout returns a request GUID. Poll its documented `action=checkverifystatus&guid=<GUID>` endpoint, then re-open the public contract page to confirm success. A request GUID alone is not evidence that verification passed.

Official references:

- https://docs.blockscout.com/devs/verification/blockscout-smart-contract-verification-api
- https://docs.robinhood.com/chain/connecting/
- https://github.com/blockscout/docs/blob/main/robinhood-api.mdx

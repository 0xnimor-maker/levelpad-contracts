# Third-party source notices

LEVELPAD Solidity source files retain their original MIT SPDX identifiers.

The self-contained `verification/StockFeeHook.standard-input.json` includes
MIT-licensed Uniswap v4 interfaces, types and helper libraries from
`@uniswap/v4-core` 1.0.2, and MIT-licensed OpenZeppelin interfaces and
ReentrancyGuard from `@openzeppelin/contracts` 5.4.0. Their source notices
remain intact. Full license notices are in `licenses/Uniswap-MIT.txt` and
`licenses/OpenZeppelin-MIT.txt`.

The related LEVELPAD contracts also import pinned Uniswap v4 core/periphery
and OpenZeppelin packages. Those dependencies retain their own licenses;
this repository's MIT license does not relicense third-party files. In
particular, v4-core has per-file licensing, so consult each dependency's SPDX
header and package license files. Dependencies are installed through npm,
not republished as a complete vendor directory.

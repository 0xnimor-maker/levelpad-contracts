// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ManagedDividendToken} from "./ManagedDividendToken.sol";
import {StockFeeHook} from "./StockFeeHook.sol";
import {UniswapV4LiquidityLock} from "./UniswapV4LiquidityLock.sol";
import {DevTax} from "./DevTax.sol";
contract UniswapV4MarketDeployer {
    address public immutable executor;
    address public immutable poolManager;
    StockFeeHook public immutable feeHook;
    constructor(address manager, address hook, address executor_) {
        require(manager.code.length > 0 && address(StockFeeHook(hook).poolManager()) == manager, "InvalidV4Configuration");
        require(executor_ != address(0), "InvalidExecutor"); executor = executor_; poolManager = manager; feeHook = StockFeeHook(hook);
    }
    function deploy(string memory name, string memory symbol, uint256 supply, address stock, address recipient, uint16 buy, uint16 sell, DevTax.Split memory split)
        external returns(ManagedDividendToken token, UniswapV4LiquidityLock lock)
    {
        // Binding both deployment addresses to the recipient prevents choosing a
        // predictable CREATE nonce address to block a future project's launch.
        // The sale is also bound, so another caller cannot occupy its addresses.
        bytes32 salt = keccak256(abi.encode(msg.sender, recipient));
        token = new ManagedDividendToken{salt: salt}(name, symbol, supply, msg.sender, stock, poolManager, address(feeHook));
        (address c0, address c1) = address(token) < stock ? (address(token), stock) : (stock, address(token));
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(feeHook)));
        lock = new UniswapV4LiquidityLock{salt: salt}(poolManager, msg.sender, key, stock, recipient, executor, split);
        require(recipient != msg.sender && recipient != address(token) && recipient != address(lock), "InvalidRecipient");
        feeHook.register(key, address(token), stock, address(lock), recipient, buy, sell);
    }
}

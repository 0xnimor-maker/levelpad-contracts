// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDevTaxProcessor} from "./DevTax.sol";
interface ILaunchedToken { function launcher() external view returns(address); }

/// @notice Fixed platform fee and immutable per-pool developer fees, paid in the stock currency.
/// @dev No swap entry point, administrator, fee changes, custody, or holder dividends.
contract StockFeeHook is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    IPoolManager public immutable poolManager;
    address public constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address public constant PLATFORM = 0x552264783f4c07f26b4bB2321d38Ed1e8Fdf6962;
    uint16 public constant PLATFORM_BPS = 100;
    uint160 public constant FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    struct Config { address stock; address devRecipient; address liquidityLock; uint16 buyBps; uint16 sellBps; }
    mapping(PoolId => Config) public configs;
    mapping(PoolId => uint256) private currentBuyFee;
    event FeesPaid(PoolId indexed id, address indexed stock, address indexed devRecipient, bool buy, uint256 platformAmount, uint256 devAmount);
    constructor(address manager) {
        require(manager.code.length > 0, "InvalidManager");
        require(QUOTER.codehash == 0xd707b1da8cb165e5ea35a3b4450d971eb562ec171e23492aa117036b78a868f6, "InvalidOfficialQuoter");
        require(uint160(address(this)) & ((1 << 14) - 1) == FLAGS, "InvalidHookFlags");
        poolManager = IPoolManager(manager);
    }
    modifier onlyManager() { require(msg.sender == address(poolManager), "OnlyPoolManager"); _; }
    function register(PoolKey calldata key, address token, address stock, address lock, address recipient, uint16 buy, uint16 sell) external nonReentrant {
        require(ILaunchedToken(token).launcher() == msg.sender, "OnlyTokenLauncher");
        require(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1) && address(key.hooks) == address(this)
            && key.fee == 3000 && key.tickSpacing == 60, "InvalidPoolKey");
        require((Currency.unwrap(key.currency0) == token && Currency.unwrap(key.currency1) == stock)
            || (Currency.unwrap(key.currency1) == token && Currency.unwrap(key.currency0) == stock), "InvalidCurrencies");
        require(stock != address(0) && lock.code.length > 0 && recipient != address(0) && recipient != address(this)
            && recipient != address(poolManager) && recipient != stock, "InvalidFeeRecipient");
        require(buy <= 1000 && sell <= 1000, "InvalidDevFee");
        PoolId id = key.toId(); require(configs[id].stock == address(0), "PoolAlreadyRegistered");
        configs[id] = Config(stock, recipient, lock, buy, sell);
    }
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyManager returns(bytes4) {
        require(sender == configs[key.toId()].liquidityLock && sender != address(0), "OnlyInitialLiquidityLock");
        return this.beforeInitialize.selector;
    }
    function feeAmounts(uint256 gross, uint16 devBps) public pure returns(uint256 platformFee, uint256 devFee) {
        require(gross <= uint256(uint128(type(int128).max)) && devBps <= 1000, "FeeAmountLimit");
        return (gross * PLATFORM_BPS / 10000, gross * devBps / 10000);
    }
    function _pay(PoolId id, Config memory c, bool buy, uint256 gross, bool internalSwap) private returns(uint256 total) {
        (uint256 platformFee, uint256 devFee) = feeAmounts(gross, internalSwap ? 0 : buy ? c.buyBps : c.sellBps);
        uint256 nominal = devFee;
        if (devFee > 0) devFee = IDevTaxProcessor(c.liquidityLock).previewFee(devFee);
        require(platformFee > 0, "TradeBelowFeePrecision");
        _takeExact(c.stock, PLATFORM, platformFee);
        if (devFee > 0) { _takeExact(c.stock, c.liquidityLock, devFee); IDevTaxProcessor(c.liquidityLock).accrueFees(nominal, devFee); }
        emit FeesPaid(id, c.stock, c.devRecipient, buy, platformFee, devFee);
        return platformFee + devFee;
    }
    function _takeExact(address stock, address recipient, uint256 amount) private {
        uint256 beforeRecipient = IERC20(stock).balanceOf(recipient);
        uint256 beforeManager = IERC20(stock).balanceOf(address(poolManager));
        poolManager.take(Currency.wrap(stock), recipient, amount);
        require(IERC20(stock).balanceOf(recipient) == beforeRecipient + amount
            && IERC20(stock).balanceOf(address(poolManager)) + amount == beforeManager, "UnsupportedStockTransfer");
    }
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external onlyManager nonReentrant returns(bytes4, BeforeSwapDelta, uint24)
    {
        require(params.amountSpecified < 0 && params.amountSpecified >= -int256(type(int128).max), "ExactInputOnly");
        PoolId id = key.toId(); Config memory c = configs[id]; require(c.stock != address(0), "UnknownPool");
        address input = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        // Record dividends only after the seller has paid the input tokens.
        // The immutable official Quoter always reverts its simulated swap.
        if (input != c.stock && sender != QUOTER) {
            // Same slot encoding as v4-core TransientStateLibrary.currencyDelta.
            int256 inputCredit = int256(uint256(poolManager.exttload(keccak256(abi.encode(sender, input)))));
            require(inputCredit >= -params.amountSpecified, "SellInputMustBeSettled");
        }
        uint256 fee = input == c.stock ? _pay(id, c, true, uint256(-params.amountSpecified), sender == c.liquidityLock && IDevTaxProcessor(c.liquidityLock).processing()) : 0;
        currentBuyFee[id] = fee;
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external onlyManager nonReentrant returns(bytes4, int128)
    {
        PoolId id = key.toId(); Config memory c = configs[id]; require(c.stock != address(0), "UnknownPool");
        bool stock0 = Currency.unwrap(key.currency0) == c.stock;
        int128 stockDelta = stock0 ? delta.amount0() : delta.amount1();
        uint256 gross = uint256(-params.amountSpecified);
        if (params.zeroForOne == stock0) {
            uint256 paidFee = currentBuyFee[id]; delete currentBuyFee[id];
            require(int256(stockDelta) == -int256(gross - paidFee), "PartialSwapNotSupported");
            return (this.afterSwap.selector, 0);
        }
        int128 tokenDelta = stock0 ? delta.amount1() : delta.amount0();
        require(int256(tokenDelta) == -int256(gross) && stockDelta > 0, "PartialSwapNotSupported");
        return (this.afterSwap.selector, int128(int256(_pay(id, c, false, uint256(uint128(stockDelta)), false))));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ExactStock} from "./ExactStock.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ManagedDividendToken} from "./ManagedDividendToken.sol";
import {DevTax} from "./DevTax.sol";

/// @notice One immutable full-range position in the official v4 PoolManager.
/// @dev No liquidity removal or arbitrary withdrawals. Executor can only buy/burn or add locked liquidity within stock budgets.
contract UniswapV4LiquidityLock is ReentrancyGuard {
    error BurnBudget();
    error BuybackSlippage();
    error CallbackForbidden();
    error FeeAccountingMismatch();
    error IncompleteSwap();
    error InitializeForbidden();
    error InitialPriceRange();
    error InvalidExecutionBounds();
    error InvalidExecutor();
    error InvalidInitialAmounts();
    error InvalidLiquidity();
    error InvalidOperation();
    error InvalidSeedDelta();
    error LiquidityBudget();
    error LiquidityBudgetExceeded();
    error LiquiditySlippage();
    error NothingToClaim();
    error OnlyExecutor();
    error OnlyFeeHook();
    error OnlyPlatform();
    error SeedBudgetExceeded();
    error SettlementMismatch();
    error SwapLimit();
    error UnfundedTax();
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using ExactStock for IERC20;
    int24 public constant LOWER = -887220;
    int24 public constant UPPER = 887220;
    address public constant PLATFORM = 0x552264783f4c07f26b4bB2321d38Ed1e8Fdf6962;
    IPoolManager public immutable poolManager;
    address public immutable sale;
    PoolKey public poolKey;
    PoolId public immutable poolId;
    uint128 public liquidity;
    bool public initialized;
    bool private bootstrapping;
    IERC20 public immutable stock;
    ManagedDividendToken public immutable token;
    address public immutable devRecipient;
    address public immutable executor;
    DevTax.Split public taxSplit;
    uint256 public creatorStock;
    uint256 public burnStock;
    uint256 public liquidityStock;
    uint256 public liquidityTokens;
    uint256 public platformDividendStock;
    bool public processing;
    uint8 private operation;
    event TaxAllocated(uint256 creator, uint256 burn, uint256 dividend, uint256 liquidity);
    event TaxProcessed(uint8 indexed kind, uint256 stockAmount, uint256 tokenAmount, uint128 addedLiquidity);
    event PlatformDividendAccrued(uint256 amount);
    event PlatformDividendClaimed(address indexed recipient, uint256 amount);
    constructor(address manager, address sale_, PoolKey memory key, address stock_, address recipient_, address executor_, DevTax.Split memory split_) {
        require(executor_ != address(0), InvalidExecutor()); DevTax.validate(split_);
        poolManager = IPoolManager(manager); sale = sale_; poolKey = key; poolId = key.toId();
        stock = IERC20(stock_); token = ManagedDividendToken(Currency.unwrap(key.currency0) == stock_ ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0));
        devRecipient = recipient_; executor = executor_; taxSplit = split_;
    }
    function previewFee(uint256 nominal) public pure returns(uint256) {
        // Unallocatable dividends accrue to the platform; dust cannot waive tax.
        return nominal;
    }
    function accrueFees(uint256 nominal, uint256 paid) external {
        require(msg.sender == address(poolKey.hooks), OnlyFeeHook());
        uint256 burn = nominal * taxSplit.burn / 10000;
        uint256 dividend = nominal * taxSplit.dividend / 10000;
        uint256 lp = nominal * taxSplit.liquidity / 10000;
        uint256 creator = nominal - burn - dividend - lp;
        require(paid == nominal, FeeAccountingMismatch());
        require(creator + burn + dividend + lp == paid, FeeAccountingMismatch());
        require(stock.balanceOf(address(this)) >= creatorStock + burnStock + liquidityStock + platformDividendStock + creator + burn + dividend + lp, UnfundedTax());
        creatorStock += creator; burnStock += burn; liquidityStock += lp;
        if (dividend > 0) {
            if (!token.canFundDividends(dividend)) {
                platformDividendStock += dividend;
                emit PlatformDividendAccrued(dividend);
            } else {
                stock.forceApprove(address(token), dividend); token.fundDividends(dividend);
            }
        }
        // Recipient restrictions cannot freeze the market. Its credit remains claimable.
        if (creatorStock > 0) { try this.claimCreator{gas: 100000}() {} catch {} }
        emit TaxAllocated(creator, burn, dividend, lp);
    }
    function claimCreator() external nonReentrant {
        uint256 amount = creatorStock; require(amount > 0, NothingToClaim());
        creatorStock = 0; stock.push(devRecipient, amount);
    }
    function claimPlatformDividend() external nonReentrant {
        require(msg.sender == PLATFORM, OnlyPlatform());
        uint256 amount = platformDividendStock; require(amount > 0, NothingToClaim());
        platformDividendStock = 0;
        stock.push(PLATFORM, amount);
        emit PlatformDividendClaimed(PLATFORM, amount);
    }
    function processTax(uint8 kind, uint256 amount, uint256 minTokens, uint128 minLiquidity, uint256 deadline_)
        external nonReentrant returns(uint256 bought, uint128 added)
    {
        require(msg.sender == executor && initialized && !processing, OnlyExecutor());
        require(deadline_ >= block.timestamp && deadline_ <= block.timestamp + 120 && amount > 1 && minTokens > 0, InvalidExecutionBounds());
        require(kind == 1 || kind == 2, InvalidOperation());
        if (kind == 1) { require(amount <= burnStock, BurnBudget()); burnStock -= amount; }
        else { require(amount <= liquidityStock && minLiquidity > 0, LiquidityBudget()); liquidityStock -= amount; }
        operation = kind; processing = true;
        (bought, added) = abi.decode(poolManager.unlock(abi.encode(amount, minTokens, minLiquidity)), (uint256, uint128));
        processing = false; operation = 0;
        emit TaxProcessed(kind, amount, bought, added);
    }
    function _process(bytes calldata data) private returns(bytes memory) {
        (uint256 amount, uint256 minTokens, uint128 minLiquidity) = abi.decode(data, (uint256, uint256, uint128));
        PoolKey memory key = poolKey;
        bool stock0 = Currency.unwrap(key.currency0) == address(stock);
        uint256 swapAmount = operation == 1 ? amount : amount / 2;
        require(swapAmount <= uint256(uint128(type(int128).max)), SwapLimit());
        BalanceDelta delta = poolManager.swap(key, SwapParams(stock0, -int256(swapAmount), stock0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        int128 stockDelta = stock0 ? delta.amount0() : delta.amount1();
        int128 tokenDelta = stock0 ? delta.amount1() : delta.amount0();
        require(int256(stockDelta) == -int256(swapAmount) && tokenDelta > 0, IncompleteSwap());
        uint256 bought = uint256(uint128(tokenDelta)); require(bought >= minTokens, BuybackSlippage());
        _settle(Currency.wrap(address(stock)), swapAmount);
        poolManager.take(Currency.wrap(address(token)), address(this), bought);
        if (operation == 1) { token.burn(bought); return abi.encode(bought, uint128(0)); }
        uint256 availableStock = amount - swapAmount;
        uint256 availableToken = bought + liquidityTokens;
        (uint160 price,,,) = poolManager.getSlot0(poolId);
        uint128 added = LiquidityAmounts.getLiquidityForAmounts(price, TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), stock0 ? availableStock : availableToken, stock0 ? availableToken : availableStock);
        require(added >= minLiquidity && uint256(liquidity) + added <= uint128(type(int128).max), LiquiditySlippage());
        (BalanceDelta change,) = poolManager.modifyLiquidity(key, ModifyLiquidityParams(LOWER, UPPER, int256(uint256(added)), bytes32(0)), "");
        int128 sd = stock0 ? change.amount0() : change.amount1();
        int128 td = stock0 ? change.amount1() : change.amount0();
        liquidityStock += _applyDelta(Currency.wrap(address(stock)), sd, availableStock);
        liquidityTokens = _applyDelta(Currency.wrap(address(token)), td, availableToken);
        liquidity += added;
        return abi.encode(bought, added);
    }
    function _applyDelta(Currency currency, int128 delta, uint256 budget) private returns(uint256 remaining) {
        if (delta < 0) { uint256 owed = uint256(-int256(delta)); require(owed <= budget, LiquidityBudgetExceeded()); _settle(currency, owed); return budget - owed; }
        uint256 fees = uint256(uint128(delta));
        if (fees > 0) poolManager.take(currency, address(this), fees);
        return budget + fees;
    }
    function initialPrice(uint256 amount0, uint256 amount1) public pure returns(uint160) {
        require(amount0 > 0 && amount1 > 0 && amount0 <= type(uint112).max && amount1 <= type(uint112).max, InvalidInitialAmounts());
        uint256 price = amount1 / amount0 > type(uint64).max
            ? Math.sqrt(Math.mulDiv(amount1, 1 << 128, amount0)) << 32
            : Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0));
        require(price > TickMath.getSqrtPriceAtTick(LOWER) && price < TickMath.getSqrtPriceAtTick(UPPER), InitialPriceRange());
        return uint160(price);
    }
    function initialize(uint256 amount0, uint256 amount1) external {
        require(msg.sender == sale && !initialized, InitializeForbidden());
        initialized = true; bootstrapping = true;
        uint160 price = initialPrice(amount0, amount1);
        poolManager.initialize(poolKey, price);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(price, TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), amount0, amount1);
        require(liquidity > 0 && liquidity <= uint128(type(int128).max), InvalidLiquidity());
        poolManager.unlock(abi.encode(amount0, amount1));
        bootstrapping = false;
    }
    function _settle(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).push(address(poolManager), amount);
        require(poolManager.settle() == amount, SettlementMismatch());
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory) {
        require(msg.sender == address(poolManager) && (bootstrapping || processing), CallbackForbidden());
        if (processing) return _process(data);
        (uint256 amount0, uint256 amount1) = abi.decode(data, (uint256, uint256));
        PoolKey memory key = poolKey;
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, ModifyLiquidityParams(LOWER, UPPER, int256(uint256(liquidity)), bytes32(0)), "");
        require(delta.amount0() <= 0 && delta.amount1() <= 0, InvalidSeedDelta());
        uint256 paid0 = uint256(-int256(delta.amount0()));
        uint256 paid1 = uint256(-int256(delta.amount1()));
        require(paid0 <= amount0 && paid1 <= amount1, SeedBudgetExceeded());
        _settle(key.currency0, paid0); _settle(key.currency1, paid1);
        // All remaining rounding units enter the same locked position as donated fees.
        if (paid0 < amount0 || paid1 < amount1) {
            poolManager.donate(key, amount0 - paid0, amount1 - paid1, "");
            _settle(key.currency0, amount0 - paid0); _settle(key.currency1, amount1 - paid1);
        }
        return "";
    }
    function positionAmounts() external view returns(uint256 amount0, uint256 amount1, uint160 price) {
        (price,,,) = poolManager.getSlot0(poolId);
        if (price == 0) return (0, 0, 0);
        uint160 low = TickMath.getSqrtPriceAtTick(LOWER);
        uint160 high = TickMath.getSqrtPriceAtTick(UPPER);
        uint160 current = price < low ? low : price > high ? high : price;
        amount0 = SqrtPriceMath.getAmount0Delta(current, high, liquidity, false);
        amount1 = SqrtPriceMath.getAmount1Delta(low, current, liquidity, false);
    }
}

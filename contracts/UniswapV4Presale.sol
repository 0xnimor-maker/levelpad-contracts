// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {WalletRecipient} from "./WalletRecipient.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StockOracle} from "./StockOracle.sol";
import {UniswapV4MarketDeployer} from "./UniswapV4MarketDeployer.sol";
import {ManagedDividendToken} from "./ManagedDividendToken.sol";
import {UniswapV4LiquidityLock} from "./UniswapV4LiquidityLock.sol";
import {ExactStock} from "./ExactStock.sol";

import {DevTax} from "./DevTax.sol";

contract UniswapV4Presale is ReentrancyGuard {
    using ExactStock for IERC20;
    using SafeERC20 for IERC20;
    uint8 public constant devTaxVersion = 2;
    uint8 public constant contributionLimitVersion = 2;
    address public constant platformRecipient = 0x552264783f4c07f26b4bB2321d38Ed1e8Fdf6962;
    DevTax.Split public taxSplit;
    string public constant marketProtocol = "uniswap-v4";
    uint16 public constant platformTaxBps = 100;
    enum State { Funding, Succeeded, Live, Refunding }
    struct Config {
        string name; string symbol; string description; address stock;
        uint16 presaleBps; uint256 targetStock; uint64 duration;
        uint16 buyTaxBps; uint16 sellTaxBps; address devRecipient; DevTax.Split taxSplit;
    }
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant FINALIZE_GRACE = 7 days;
    address public immutable devRecipient;
    address public immutable creator;
    address public immutable factory;
    IERC20 public immutable stock;
    StockOracle public immutable oracle;
    UniswapV4MarketDeployer public immutable marketDeployer;
    uint8 public immutable stockDecimals;
    uint256 public immutable targetStock;
    uint256 public immutable stockStep;
    uint256 public immutable deadline;
    uint256 public immutable presaleSupply;
    uint16 public immutable presaleBps;
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    string public name;
    string public symbol;
    string public description;
    State public state;
    uint256 public totalStock;
    uint256 public contributorCount;
    uint256 public remainingClaims;
    uint256 public remainingTokens;
    uint256 public successAt;
    uint256 public successPriceUsd18;
    uint256 public refundedStock;
    ManagedDividendToken public token;
    UniswapV4LiquidityLock public pool;
    mapping(address => uint256) public contributions;
    mapping(address => bool) public claimed;
    mapping(address => bool) public refunded;

    event AutoLaunchDeferred(bytes reason);
    event Contributed(address indexed account, uint256 stockAmount, uint256 totalStock, uint256 priceUsd18);
    event GoalReached(uint256 totalStock, uint256 priceUsd18, uint256 timestamp);
    event Launched(address indexed token, address indexed pool, uint256 presaleTokens, uint256 liquidityTokens, uint256 stockAmount);
    event RefundsOpened(bool launchTimedOut);
    event TokensClaimed(address indexed account, uint256 amount);
    event Refunded(address indexed account, uint256 stockAmount);
    event ContributionDiverted(address indexed account, uint256 stockAmount, address indexed recipient);
    event UncreditedStockForwarded(uint256 stockAmount);
    event DirectEthForwarded(address indexed sender, uint256 amount);

    constructor(Config memory config, address creator_, address oracle_, uint8 stockDecimals_, address deployer_) {
        require(creator_ != address(0), "InvalidCreator");
        require(uint160(config.devRecipient) > 0xffff && WalletRecipient.isWallet(config.devRecipient)
            && config.devRecipient != address(this), "InvalidFeeRecipient");
        require(stockDecimals_ >= 3 && stockDecimals_ <= 18, "InvalidStockDecimals");
        stockStep = 10 ** (stockDecimals_ - 3);
        require(config.targetStock > 0 && config.targetStock <= type(uint112).max && config.targetStock % stockStep == 0, "InvalidStockTarget");
        DevTax.validateV1(config.taxSplit, config.presaleBps); taxSplit = config.taxSplit; devRecipient = config.devRecipient; creator = creator_; factory = msg.sender;
        stock = IERC20(config.stock); oracle = StockOracle(oracle_);
        marketDeployer = UniswapV4MarketDeployer(deployer_); stockDecimals = stockDecimals_;
        name = config.name; symbol = config.symbol; description = config.description;
        targetStock = config.targetStock; deadline = block.timestamp + config.duration;
        presaleBps = config.presaleBps; presaleSupply = TOTAL_SUPPLY * config.presaleBps / 10_000;
        buyTaxBps = config.buyTaxBps; sellTaxBps = config.sellTaxBps;
    }

    function status() public view returns (State) {
        if (state == State.Funding && block.timestamp >= deadline) return State.Refunding;
        return state;
    }

    function valuation() external view returns (uint256 valueUsd18, uint256 priceUsd18, uint256 updatedAt) {
        (priceUsd18, updatedAt) = oracle.read();
        valueUsd18 = Math.mulDiv(totalStock, priceUsd18, 10 ** stockDecimals);
    }

    function quoteContribution(uint256 maxStock) public view returns (uint256 accepted, uint256 priceUsd18, uint256 goalStock) {
        require(state == State.Funding && block.timestamp < deadline, "SaleClosed");
        goalStock = targetStock;
        // Funding uses stock units only. A missing or paused price feed cannot
        // change the goal, wallet allowance, or ability to contribute.
        priceUsd18 = 0;
        accepted = totalStock >= targetStock ? 0 : Math.min(maxStock, targetStock - totalStock);
    }

    function contributionLimits(address account) external view returns (uint256 limitStock, uint256 usedStock, uint256 availableStock) {
        limitStock = account == creator ? type(uint256).max : targetStock / 20;
        usedStock = contributions[account];
        availableStock = _walletStockCap(account);
    }

    function _walletStockCap(address account) private view returns (uint256 cap) {
        if (account == creator) return targetStock - totalStock;
        uint256 limit = targetStock / 20;
        uint256 used = contributions[account];
        if (used >= limit) return 0;
        cap = (limit - used) / stockStep * stockStep;
    }

    /// @notice A non-step amount or ordinary-wallet over-limit payment is
    /// transferred in full to the platform without presale credit. Previously
    /// credited contributions and refund rights remain unchanged.
    function contributeStock(uint256 maxStock, uint256 minAccepted)
        external nonReentrant returns (uint256 accepted)
    {
        return _contribute(msg.sender, msg.sender, maxStock, minAccepted);
    }

    /// @notice The official UI binds its observed cumulative credit. A parallel
    /// pending purchase cannot turn an in-limit preview into a forfeiture.
    function contributeStockChecked(uint256 maxStock, uint256 minAccepted, uint256 expectedStock)
        external nonReentrant returns (uint256)
    {
        require(contributions[msg.sender] == expectedStock, "WalletAllowanceChanged");
        return _contribute(msg.sender, msg.sender, maxStock, minAccepted);
    }

    /// @dev Only this sale's factory can credit its immutable creator during
    /// atomic creation. There is no arbitrary payer or beneficiary interface.
    function contributeForCreator(uint256 maxStock, uint256 minAccepted)
        external nonReentrant returns (uint256)
    {
        require(msg.sender == factory, "OnlyFactory");
        return _contribute(msg.sender, creator, maxStock, minAccepted);
    }

    function _contribute(address payer, address account, uint256 maxStock, uint256 minAccepted)
        private returns (uint256 accepted)
    {
        require(maxStock > 0, "ZeroContribution");
        (accepted,,) = quoteContribution(maxStock);
        require(accepted > 0, "CheckpointRequired");
        if (maxStock % stockStep != 0 || (account != creator && maxStock > _walletStockCap(account))) {
            stock.pull(payer, maxStock);
            stock.push(platformRecipient, maxStock);
            emit ContributionDiverted(account, maxStock, platformRecipient);
            return 0;
        }
        require(accepted >= minAccepted, "ContributionChanged");
        stock.pull(payer, accepted);
        if (contributions[account] == 0) contributorCount++;
        contributions[account] += accepted; totalStock += accepted;
        emit Contributed(account, accepted, totalStock, 0);
        if (totalStock >= targetStock) _succeed(0);
    }

    /// @notice Direct ERC20 transfers do not execute recipient code. Anyone can
    /// forward only the uncredited surplus; all refundable escrow is reserved.
    function forwardUncreditedStock() external nonReentrant returns (uint256 amount) {
        uint256 reserved = state == State.Live ? 0 : totalStock - refundedStock;
        uint256 balance = stock.balanceOf(address(this));
        require(balance >= reserved, "EscrowBalanceMismatch");
        amount = balance - reserved;
        stock.push(platformRecipient, amount);
        emit UncreditedStockForwarded(amount);
    }

    receive() external payable nonReentrant {
        (bool sent,) = platformRecipient.call{value: msg.value}("");
        require(sent, "PlatformTransferFailed");
        emit DirectEthForwarded(msg.sender, msg.value);
    }

    /// @notice Only credited stock can satisfy this fixed stock target.
    function checkpoint() external nonReentrant returns (bool) {
        require(state == State.Funding && block.timestamp < deadline, "SaleClosed");
        if (totalStock >= targetStock) {
            _succeed(0); return true;
        }
        return false;
    }

    function _succeed(uint256 price) private {
        state = State.Succeeded; successAt = block.timestamp; successPriceUsd18 = price;
        emit GoalReached(totalStock, price, block.timestamp);
        require(gasleft() >= 8_000_000, "AutoLaunchGasRequired");
        try this.autoFinalize{gas: 7_500_000}() {} catch(bytes memory reason) { emit AutoLaunchDeferred(reason); }
    }

    /// @notice Creates the ERC20 and LP atomically. There is no token before success.
    function finalize() external nonReentrant { _finalize(); }
    function autoFinalize() external { require(msg.sender == address(this), "OnlySelf"); _finalize(); }
    function _finalize() private {
        require(state == State.Succeeded, "NotSucceeded");
        require(block.timestamp < successAt + FINALIZE_GRACE, "LaunchGraceExpired");
        state = State.Live;
        (token, pool) = marketDeployer.deploy(name, symbol, TOTAL_SUPPLY, address(stock), devRecipient, buyTaxBps, sellTaxBps, taxSplit);
        uint256 liquidityTokens = TOTAL_SUPPLY - presaleSupply;
        remainingClaims = contributorCount; remainingTokens = presaleSupply;
        token.bootstrap(address(pool), liquidityTokens);
        stock.push(address(pool), totalStock);
        bool tokenFirst = address(token) < address(stock);
        pool.initialize(tokenFirst ? liquidityTokens : totalStock, tokenFirst ? totalStock : liquidityTokens);
        emit Launched(address(token), address(pool), presaleSupply, liquidityTokens, totalStock);
    }

    function openRefunds() public {
        bool expired = state == State.Funding && block.timestamp >= deadline;
        bool launchTimedOut = state == State.Succeeded && block.timestamp >= successAt + FINALIZE_GRACE;
        require(expired || launchTimedOut, "RefundsUnavailable");
        state = State.Refunding;
        emit RefundsOpened(launchTimedOut);
    }

    function refund() external { refundFor(msg.sender); }

    function refundFor(address account) public nonReentrant {
        if (state != State.Refunding) openRefunds();
        uint256 amount = contributions[account];
        require(amount > 0 && !refunded[account], "NothingToRefund");
        refunded[account] = true; refundedStock += amount;
        stock.push(account, amount);
        emit Refunded(account, amount);
    }

    function claimableTokens(address account) public view returns (uint256) {
        if (state != State.Live || claimed[account] || contributions[account] == 0) return 0;
        // The last claimant receives sub-wei-per-participant integer rounding dust.
        return remainingClaims == 1 ? remainingTokens : Math.mulDiv(presaleSupply, contributions[account], totalStock);
    }

    function claim() external { claimFor(msg.sender); }

    function claimFor(address account) public nonReentrant {
        require(state == State.Live && !claimed[account] && contributions[account] > 0, "NothingToClaim");
        uint256 amount = claimableTokens(account);
        claimed[account] = true; remainingClaims--; remainingTokens -= amount;
        token.releasePresale(account, amount);
        emit TokensClaimed(account, amount);
    }
}

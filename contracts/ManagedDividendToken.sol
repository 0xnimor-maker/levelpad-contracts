// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ExactStock} from "./ExactStock.sol";

/// @notice Fixed-supply token with exact, pull-based stock dividend accounting.
/// @dev No owner, mint, tax-change, blacklist, rescue or upgrade function exists.
contract ManagedDividendToken is ERC20, ReentrancyGuard {
    error InvalidDividendState();
    using ExactStock for IERC20;
    uint256 public constant MAGNITUDE = 2 ** 128;
    uint256 public constant MAX_TOTAL_DIVIDENDS = type(uint112).max;
    address public constant DEAD = address(0xdead);
    address public immutable sale;
    address public immutable launcher;
    address public immutable manager;
    address public immutable hook;
    IERC20 public immutable stock;
    uint256 public immutable maxDividendPerShare;
    uint256 public immutable minDividendSupply;
    address public pool;
    uint256 public eligibleSupply;
    uint256 public dividendPerShare;
    uint256 public totalDistributed;
    uint256 public totalWithdrawn;
    mapping(address => int256) private corrections;
    mapping(address => uint256) public withdrawnDividends;
    bool private inheritingPresale;

    event DividendsFunded(address indexed sender, uint256 stockAmount, uint256 dividendPerShare);
    event DividendClaimed(address indexed account, uint256 stockAmount);
    event PoolBound(address indexed pool, uint256 tokenAmount);
    event PresaleReleased(address indexed beneficiary, uint256 tokenAmount);

    constructor(string memory name_, string memory symbol_, uint256 supply_, address sale_, address stock_, address manager_, address hook_)
        ERC20(name_, symbol_)
    {
        require(supply_ > 0 && supply_ <= 1e33 && sale_ != address(0), InvalidDividendState());
        sale = sale_; launcher = msg.sender; manager = manager_; hook = hook_;
        stock = IERC20(stock_);
        maxDividendPerShare = uint256(type(int256).max) / supply_ / 2;
        // For every accepted funding ai at supply Ei >= this floor:
        // sum(floor(ai * MAGNITUDE / Ei)) <= MAX_TOTAL_DIVIDENDS * MAGNITUDE / floor.
        // Thus a tiny balance cannot consume capacity needed after circulation recovers.
        minDividendSupply = Math.mulDiv(MAX_TOTAL_DIVIDENDS, MAGNITUDE, maxDividendPerShare, Math.Rounding.Ceil);
        _mint(sale_, supply_);
    }

    function isEligible(address account) public view returns (bool) {
        return account != address(0) && account != pool && account != manager && account != hook && account != address(this) && account != DEAD;
    }

    function bootstrap(address pool_, uint256 liquidityTokens) external {
        require(msg.sender == sale && pool == address(0), InvalidDividendState());
        require(pool_.code.length > 0 && balanceOf(pool_) == 0, InvalidDividendState());
        require(liquidityTokens > 0 && liquidityTokens < totalSupply(), InvalidDividendState());
        pool = pool_;
        _transfer(sale, pool_, liquidityTokens);
        emit PoolBound(pool_, liquidityTokens);
    }

    /// @notice Transfers original presale tokens together with their historical
    /// dividend entitlement. The sale's remaining balance always dates to genesis.
    function releasePresale(address beneficiary, uint256 amount) external {
        require(msg.sender == sale && pool != address(0), InvalidDividendState());
        require(isEligible(beneficiary) && beneficiary != sale, InvalidDividendState());
        inheritingPresale = true;
        _transfer(sale, beneficiary, amount);
        inheritingPresale = false;
        emit PresaleReleased(beneficiary, amount);
    }

    function fundDividends(uint256 amount) external nonReentrant {
        require(amount > 0 && canFundDividends(amount), InvalidDividendState());
        stock.pull(msg.sender, amount);
        // Recheck after the external stock transfer, including any token callback.
        require(canFundDividends(amount), InvalidDividendState());
        dividendPerShare += amount * MAGNITUDE / eligibleSupply;
        totalDistributed += amount;
        emit DividendsFunded(msg.sender, amount, dividendPerShare);
    }

    /// @notice Guards both lifetime funding and per-share precision capacity.
    /// A fixed minimum share supply reserves enough precision for all lifetime funding.
    /// Below the threshold, tax is temporarily waived; circulating shares can recover.
    function canFundDividends(uint256 amount) public view returns (bool) {
        if (pool == address(0) || eligibleSupply < minDividendSupply || amount > MAX_TOTAL_DIVIDENDS - totalDistributed) return false;
        uint256 increase = amount * MAGNITUDE / eligibleSupply;
        return increase <= maxDividendPerShare - dividendPerShare;
    }

    function accumulativeDividendOf(address account) public view returns (uint256) {
        uint256 shares = isEligible(account) ? balanceOf(account) : 0;
        int256 magnified = int256(dividendPerShare * shares) + corrections[account];
        return magnified <= 0 ? 0 : uint256(magnified) / MAGNITUDE;
    }

    function withdrawableDividendOf(address account) public view returns (uint256) {
        return accumulativeDividendOf(account) - withdrawnDividends[account];
    }

    function claimDividend() external returns (uint256) { return claimDividendFor(msg.sender); }

    /// @notice Anyone may pay gas, but stock always goes to the entitled holder.
    function claimDividendFor(address account) public nonReentrant returns (uint256 amount) {
        require(account != sale && account != address(0) && account != address(this), InvalidDividendState());
        amount = withdrawableDividendOf(account);
        require(amount > 0, InvalidDividendState());
        withdrawnDividends[account] += amount;
        totalWithdrawn += amount;
        stock.push(account, amount);
        emit DividendClaimed(account, amount);
    }

    function burn(uint256 amount) external { _burn(msg.sender, amount); }

    function _update(address from, address to, uint256 amount) internal override {
        require(to != sale || from == address(0), InvalidDividendState());
        bool fromEligible = isEligible(from);
        bool toEligible = isEligible(to);
        super._update(from, to, amount);
        if (fromEligible) eligibleSupply -= amount;
        if (toEligible) eligibleSupply += amount;
        if (!inheritingPresale) {
            int256 correction = int256(dividendPerShare * amount);
            if (fromEligible) corrections[from] += correction;
            if (toEligible) corrections[to] -= correction;
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StockRegistry} from "./StockRegistry.sol";
import {UniswapV4Presale} from "./UniswapV4Presale.sol";
import {UniswapV4MarketDeployer} from "./UniswapV4MarketDeployer.sol";

import {DevTax} from "./DevTax.sol";
import {ExactStock} from "./ExactStock.sol";
import {WalletRecipient} from "./WalletRecipient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract UniswapV4LaunchFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ExactStock for IERC20;
    uint8 public constant contributionLimitVersion = 2;
    uint256 public constant launchFee = 0.0005 ether;
    address public constant platformRecipient = 0x552264783f4c07f26b4bB2321d38Ed1e8Fdf6962;
    StockRegistry public immutable registry;
    address public immutable marketDeployer;
    address[] public sales;
    mapping(address => bool) public isSale;
    event SaleCreated(address indexed sale, address indexed creator, address indexed stock,
        string name, string symbol, uint256 targetStock, uint256 deadline);
    event CreatorPurchased(address indexed sale, address indexed creator, uint256 stockAmount, uint256 acceptedStock);
    event LaunchFeePaid(address indexed creator, uint256 amount);

    constructor(address registry_, address deployer_) {
        require(registry_.code.length > 0 && deployer_.code.length > 0, "InvalidFactoryConfig");
        registry = StockRegistry(registry_); marketDeployer = deployer_;
    }

    function createStockSale(UniswapV4Presale.Config calldata config) external payable nonReentrant returns (address sale) {
        return _createSale(config);
    }

    function createStockSaleWithPurchase(UniswapV4Presale.Config calldata config, uint128 stockAmount)
        external payable nonReentrant returns (address sale)
    {
        require(stockAmount > 0 && stockAmount <= config.targetStock, "InvalidCreatorPurchase");
        sale = _createSale(config);
        IERC20(config.stock).pull(msg.sender, stockAmount);
        uint256 accepted = _creditCreator(sale, config.stock, stockAmount);
        emit CreatorPurchased(sale, msg.sender, stockAmount, accepted);
    }

    function _creditCreator(address sale, address stock, uint256 amount) private returns (uint256 accepted) {
        IERC20(stock).forceApprove(sale, amount);
        accepted = UniswapV4Presale(payable(sale)).contributeForCreator(amount, amount);
        IERC20(stock).forceApprove(sale, 0);
    }

    function _createSale(UniswapV4Presale.Config calldata config) private returns (address sale) {
        require(msg.value == launchFee, "IncorrectLaunchFee");
        require(uint160(config.devRecipient) > 0xffff && WalletRecipient.isWallet(config.devRecipient)
            && config.devRecipient != address(this), "InvalidFeeRecipient");
        DevTax.validateV1(config.taxSplit, config.presaleBps);
        require(bytes(config.name).length > 0 && bytes(config.name).length <= 64, "InvalidName");
        bytes memory symbol = bytes(config.symbol);
        require(symbol.length > 0 && symbol.length <= 12, "InvalidSymbol");
        for (uint256 i; i < symbol.length; ++i) {
            require((symbol[i] >= 0x41 && symbol[i] <= 0x5a) || (symbol[i] >= 0x30 && symbol[i] <= 0x39), "InvalidSymbol");
        }
        require(bytes(config.description).length <= 600, "DescriptionTooLong");
        require(config.duration >= 60 && config.duration <= 30 days, "InvalidDuration");
        require(config.buyTaxBps <= 1000 && config.sellTaxBps <= 1000 && config.devRecipient != address(0), "InvalidTax");
        require(config.devRecipient != config.stock && config.devRecipient != UniswapV4MarketDeployer(marketDeployer).poolManager()
            && config.devRecipient != address(UniswapV4MarketDeployer(marketDeployer).feeHook()), "InvalidFeeRecipient");
        (address oracle, uint8 d, bool enabled) = registry.assets(config.stock);
        require(enabled, "UnsupportedStock");
        // The presale validates the target against the stock's .001 unit step.
        sale = address(new UniswapV4Presale(config, msg.sender, oracle, d, marketDeployer));
        sales.push(sale); isSale[sale] = true;
        emit SaleCreated(sale, msg.sender, config.stock, config.name, config.symbol, config.targetStock, UniswapV4Presale(payable(sale)).deadline());
        (bool sent,) = platformRecipient.call{value: launchFee}("");
        require(sent, "LaunchFeeTransferFailed");
        emit LaunchFeePaid(msg.sender, launchFee);
    }

    function saleCount() external view returns (uint256) { return sales.length; }
}

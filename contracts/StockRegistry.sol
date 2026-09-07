// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StockOracle} from "./StockOracle.sol";

/// @notice Catalog of verified stock tokens. Existing sales snapshot their adapter.
contract StockRegistry is Ownable2Step {
    struct Asset { address oracle; uint8 decimals; bool enabled; }
    mapping(address => Asset) public assets;
    address[] public stocks;
    event StockRegistered(address indexed stock, address indexed oracle, uint8 decimals);
    event StockEnabled(address indexed stock, bool enabled);

    constructor(address owner_) Ownable(owner_) {}

    function register(address stock, address oracle) external onlyOwner {
        require(stock.code.length > 0 && oracle.code.length > 0, "InvalidAsset");
        require(StockOracle(oracle).stock() == stock, "OracleStockMismatch");
        uint8 d = IERC20Metadata(stock).decimals();
        require(d <= 18, "UnsupportedStockDecimals");
        // Registration verifies configuration, not current market availability.
        // Presale reads the adapter before accepting funds or recording success.
        if (assets[stock].oracle == address(0)) stocks.push(stock);
        assets[stock] = Asset(oracle, d, true);
        emit StockRegistered(stock, oracle, d);
    }

    function setEnabled(address stock, bool enabled) external onlyOwner {
        require(assets[stock].oracle != address(0), "UnknownStock");
        assets[stock].enabled = enabled;
        emit StockEnabled(stock, enabled);
    }

    function stockCount() external view returns (uint256) { return stocks.length; }
}

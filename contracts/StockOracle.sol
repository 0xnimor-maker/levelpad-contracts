// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Immutable per-stock Chainlink adapter. Price is USD per raw ERC20 token.
/// @dev Robinhood feeds already incorporate uiMultiplier: never multiply again.
contract StockOracle {
    address public immutable stock;
    IAggregatorV3 public immutable feed;
    IAggregatorV3 public immutable sequencer;
    /// @notice Zero accepts the feed's last published valid round, including closed sessions.
    uint256 public immutable maxAge;
    uint256 public immutable gracePeriod;
    uint8 public immutable feedDecimals;
    bool public immutable checkStockPause;

    constructor(address stock_, address feed_, address sequencer_, uint256 maxAge_, uint256 gracePeriod_, bool checkStockPause_) {
        require(stock_.code.length > 0 && feed_.code.length > 0, "InvalidOracleAddress");
        require(maxAge_ <= 7 days, "InvalidMaxAge");
        require(sequencer_ == address(0) || sequencer_.code.length > 0, "InvalidSequencer");
        uint8 d = IAggregatorV3(feed_).decimals();
        require(d <= 18, "UnsupportedFeedDecimals");
        stock = stock_;
        feed = IAggregatorV3(feed_);
        sequencer = IAggregatorV3(sequencer_);
        maxAge = maxAge_;
        gracePeriod = gracePeriod_;
        feedDecimals = d;
        checkStockPause = checkStockPause_;
    }

    function read() public view returns (uint256 priceUsd18, uint256 updatedAt) {
        if (address(sequencer) != address(0)) {
            (, int256 sequencerAnswer, uint256 startedAt, , ) = sequencer.latestRoundData();
            require(sequencerAnswer == 0 && startedAt != 0 && startedAt <= block.timestamp, "SequencerUnavailable");
            require(block.timestamp - startedAt > gracePeriod, "SequencerGracePeriod");
        }
        // Legacy assets must explicitly opt out at deployment. An expected pause
        // interface failing or returning malformed data must never fail open.
        if (checkStockPause) {
            (bool ok, bytes memory data) = stock.staticcall(abi.encodeWithSignature("oraclePaused()"));
            require(ok && data.length == 32, "StockPauseUnavailable");
            uint256 paused = abi.decode(data, (uint256));
            require(paused <= 1, "StockPauseUnavailable");
            require(paused == 0, "StockOraclePaused");
        }
        (uint80 round, int256 answer, , uint256 timestamp, uint80 answeredInRound) = feed.latestRoundData();
        require(answer > 0 && round > 0 && answeredInRound >= round, "InvalidOracleRound");
        require(timestamp != 0 && timestamp <= block.timestamp, "InvalidOracleTimestamp");
        require(maxAge == 0 || block.timestamp - timestamp <= maxAge, "StaleOracle");
        require(uint256(answer) <= 1e30, "OraclePriceOutOfRange");
        return (uint256(answer) * 10 ** (18 - feedDecimals), timestamp);
    }
}

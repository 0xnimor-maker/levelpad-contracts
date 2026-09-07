// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Only standard, non-rebasing, non-fee-on-transfer stock tokens are supported.
library ExactStock {
    using SafeERC20 for IERC20;

    function pull(IERC20 token, address from, uint256 amount) internal {
        require(from != address(this), "SelfStockTransfer");
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeSender = token.balanceOf(from);
        token.safeTransferFrom(from, address(this), amount);
        require(beforeSender >= amount && token.balanceOf(from) == beforeSender - amount
            && token.balanceOf(address(this)) == beforeBalance + amount, "NonExactStockTransfer");
    }

    function push(IERC20 token, address to, uint256 amount) internal {
        if (amount == 0) return;
        require(to != address(this), "SelfStockTransfer");
        uint256 beforeBalance = token.balanceOf(to);
        uint256 beforeSender = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        require(beforeSender >= amount && token.balanceOf(address(this)) == beforeSender - amount
            && token.balanceOf(to) == beforeBalance + amount, "NonExactStockTransfer");
    }
}

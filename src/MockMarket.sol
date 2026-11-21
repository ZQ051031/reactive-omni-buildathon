// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol, address recipient, uint256 supply) ERC20(name, symbol) {
        _mint(recipient, supply);
    }
}

contract MockMarket {
    using SafeERC20 for IERC20;

    error NotReporter();
    error InvalidMarket();
    error ZeroOutput();

    event PriceUpdated(uint256 indexed sequence, uint256 price, uint256 timestamp);
    event Sold(address indexed seller, address indexed recipient, uint256 baseIn, uint256 quoteOut, uint256 price);

    IERC20 public immutable base;
    IERC20 public immutable quote;
    address public immutable reporter;
    uint256 public price;
    uint256 public sequence;

    constructor(IERC20 base_, IERC20 quote_, address reporter_, uint256 initialPrice) {
        if (
            address(base_).code.length == 0 || address(quote_).code.length == 0 || base_ == quote_
                || reporter_ == address(0)
        ) revert InvalidMarket();
        base = base_;
        quote = quote_;
        reporter = reporter_;
        _publish(initialPrice);
    }

    function publishPrice(uint256 newPrice) external {
        if (msg.sender != reporter) revert NotReporter();
        _publish(newPrice);
    }

    function sell(uint256 amount, address recipient) external returns (uint256 quoteOut) {
        uint256 settlementPrice = price;
        quoteOut = Math.mulDiv(amount, settlementPrice, 1e18);
        if (quoteOut == 0) revert ZeroOutput();

        base.safeTransferFrom(msg.sender, address(this), amount);
        quote.safeTransfer(recipient, quoteOut);
        emit Sold(msg.sender, recipient, amount, quoteOut, settlementPrice);
    }

    function _publish(uint256 newPrice) private {
        if (newPrice == 0) revert InvalidMarket();
        price = newPrice;
        emit PriceUpdated(++sequence, newPrice, block.timestamp);
    }
}

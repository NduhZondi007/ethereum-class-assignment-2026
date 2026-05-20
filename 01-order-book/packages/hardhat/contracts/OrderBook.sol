// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Order book DEX — trades tokenA (PNPT) against tokenB (FNBT)
contract OrderBook {
    using SafeERC20 for IERC20;

    error InvalidAmount();
    error InvalidPrice();
    error PriceMismatch();
    error UnauthorizedCancellation();

    event OrderPlaced(
        uint256 orderId,
        address creator,
        uint256 orderIndex,
        address tokenGiven,
        address tokenReceived,
        uint256 amount,
        uint256 price
    );
    event OrderMatched(uint256 buyOrderId, uint256 sellOrderId);
    event OrderCanceled(uint256 orderId);

    struct Order {
        address creator;
        uint256 amount;
        uint256 filled;
        uint256 price;
        bool isBuyOrder;
        bool isOpen;
    }

    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    uint256 private _orderCounter;
    mapping(uint256 => Order) private _orders;

    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();
        orderId = _orderCounter++;
        tokenB.safeTransferFrom(msg.sender, address(this), amount * price);
        _orders[orderId] = Order({ creator: msg.sender, amount: amount, filled: 0, price: price, isBuyOrder: true, isOpen: true });
        emit OrderPlaced(orderId, msg.sender, orderId, address(tokenB), address(tokenA), amount, price);
    }

    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();
        orderId = _orderCounter++;
        tokenA.safeTransferFrom(msg.sender, address(this), amount);
        _orders[orderId] = Order({ creator: msg.sender, amount: amount, filled: 0, price: price, isBuyOrder: false, isOpen: true });
        emit OrderPlaced(orderId, msg.sender, orderId, address(tokenA), address(tokenB), amount, price);
    }

    // Match a buy order with a sell order. Handles partial fills automatically.
    // fillAmount = min(buyRemaining, sellRemaining) so neither order overfills.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder  = _orders[buyOrderId];
        Order storage sellOrder = _orders[sellOrderId];

        // Buyer must be willing to pay at least the seller's asking price
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        uint256 buyRemaining  = buyOrder.amount  - buyOrder.filled;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled;
        uint256 fillAmount    = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;

        // Update state before transfers (checks-effects-interactions)
        buyOrder.filled  += fillAmount;
        sellOrder.filled += fillAmount;

        if (buyOrder.filled  == buyOrder.amount)  buyOrder.isOpen  = false;
        if (sellOrder.filled == sellOrder.amount) sellOrder.isOpen = false;

        // Deliver tokenA to buyer and tokenB to seller
        tokenA.safeTransfer(buyOrder.creator,  fillAmount);
        tokenB.safeTransfer(sellOrder.creator, fillAmount * buyOrder.price);

        emit OrderMatched(buyOrderId, sellOrderId);
    }

    function cancelOrder(uint256 orderId) external {}
    function remaining(uint256 orderId) external view returns (uint256) {}
    function isOpen(uint256 orderId) external view returns (bool) {}
}

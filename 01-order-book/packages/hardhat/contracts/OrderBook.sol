// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder  = _orders[buyOrderId];
        Order storage sellOrder = _orders[sellOrderId];
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();
        uint256 buyRemaining  = buyOrder.amount  - buyOrder.filled;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled;
        uint256 fillAmount    = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;
        buyOrder.filled  += fillAmount;
        sellOrder.filled += fillAmount;
        if (buyOrder.filled  == buyOrder.amount)  buyOrder.isOpen  = false;
        if (sellOrder.filled == sellOrder.amount) sellOrder.isOpen = false;
        tokenA.safeTransfer(buyOrder.creator,  fillAmount);
        tokenB.safeTransfer(sellOrder.creator, fillAmount * buyOrder.price);
        emit OrderMatched(buyOrderId, sellOrderId);
    }

    // Cancel and refund the unspent portion back to the creator
    function cancelOrder(uint256 orderId) external {
        Order storage order = _orders[orderId];
        if (order.creator != msg.sender) revert UnauthorizedCancellation();
        order.isOpen = false;
        uint256 unfilled = order.amount - order.filled;
        if (order.isBuyOrder) {
            // Refund the tokenB that was locked but not used
            tokenB.safeTransfer(msg.sender, unfilled * order.price);
        } else {
            tokenA.safeTransfer(msg.sender, unfilled);
        }
        emit OrderCanceled(orderId);
    }

    function remaining(uint256 orderId) external view returns (uint256) {
        Order storage order = _orders[orderId];
        return order.amount - order.filled;
    }

    function isOpen(uint256 orderId) external view returns (bool) {
        return _orders[orderId].isOpen;
    }
}

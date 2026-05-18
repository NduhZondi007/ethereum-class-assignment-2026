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

    // Pull the full tokenB quote upfront so funds are locked until matched or cancelled
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        orderId = _orderCounter++;
        // Lock amount * price tokenB from the buyer
        tokenB.safeTransferFrom(msg.sender, address(this), amount * price);

        _orders[orderId] = Order({
            creator: msg.sender,
            amount: amount,
            filled: 0,
            price: price,
            isBuyOrder: true,
            isOpen: true
        });

        emit OrderPlaced(orderId, msg.sender, orderId, address(tokenB), address(tokenA), amount, price);
    }

    // Pull the tokenA from the seller upfront
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        orderId = _orderCounter++;
        // Lock seller's tokenA in the contract
        tokenA.safeTransferFrom(msg.sender, address(this), amount);

        _orders[orderId] = Order({
            creator: msg.sender,
            amount: amount,
            filled: 0,
            price: price,
            isBuyOrder: false,
            isOpen: true
        });

        emit OrderPlaced(orderId, msg.sender, orderId, address(tokenA), address(tokenB), amount, price);
    }

    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {}
    function cancelOrder(uint256 orderId) external {}
    function remaining(uint256 orderId) external view returns (uint256) {}
    function isOpen(uint256 orderId) external view returns (bool) {}
}

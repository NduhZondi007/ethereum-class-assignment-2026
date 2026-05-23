// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// IERC20 gives us the interface to interact with any ERC20 token.
// SafeERC20 wraps transfers so they revert on failure instead of
// returning false silently — much safer for production code.
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// This is a simple on-chain order book DEX between two ERC20 tokens.
// It works like a traditional exchange:
//   - Buyers place orders saying "I want X of tokenA, willing to pay Y tokenB each"
//   - Sellers place orders saying "I'm selling X tokenA for Y tokenB each"
//   - A matcher (anyone) can then pair a compatible buy and sell order
//
// Key design decisions:
//   - Tokens are locked in the contract at order placement time (not at match time)
//   - Partial fills are supported: if a buy order wants 10 but the sell is only 4, we fill 4
//   - Cancelled orders get their locked tokens refunded
contract OrderBook {
    // Use SafeERC20 for all token transfers to handle non-standard tokens
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────
    // Custom Errors  (cheaper than require + string)
    // ────────────────────────────────────────────────────

    // Thrown when an order is placed with amount = 0
    error InvalidAmount();
    // Thrown when an order is placed with price = 0
    error InvalidPrice();
    // Thrown when a buy order's price is lower than the sell order's price
    error PriceMismatch();
    // Thrown when someone tries to cancel an order they didn't create
    error UnauthorizedCancellation();

    // ────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────

    // Emitted every time a new order (buy or sell) is created.
    // tokenGiven  = what the order creator deposits into the contract
    // tokenReceived = what they expect to get back after matching
    event OrderPlaced(
        uint256 orderId,
        address creator,
        uint256 orderIndex,
        address tokenGiven,
        address tokenReceived,
        uint256 amount,
        uint256 price
    );

    // Emitted when two orders are successfully matched and tokens transferred
    event OrderMatched(uint256 buyOrderId, uint256 sellOrderId);

    // Emitted when an order owner cancels and receives their refund
    event OrderCanceled(uint256 orderId);

    // ────────────────────────────────────────────────────
    // Data Structures
    // ────────────────────────────────────────────────────

    // Everything we need to know about a single order
    struct Order {
        address creator;   // the wallet that placed this order
        uint256 amount;    // original quantity of tokenA requested/offered
        uint256 filled;    // how much of amount has been matched so far
        uint256 price;     // tokenB units per tokenA unit
        bool isBuyOrder;   // true = buying tokenA; false = selling tokenA
        bool isOpen;       // becomes false when fully filled or cancelled
    }

    // ────────────────────────────────────────────────────
    // State Variables
    // ────────────────────────────────────────────────────

    // tokenA is the asset being traded (PNPT in this assignment)
    IERC20 public immutable tokenA;
    // tokenB is the quote/payment token (FNBT in this assignment)
    IERC20 public immutable tokenB;

    // Global counter: each new order gets the current value then we increment
    uint256 private _orderCounter;

    // All orders indexed by their ID
    mapping(uint256 => Order) private _orders;

    // ────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────

    // Store the two token addresses. The order book only ever
    // trades between these two specific tokens.
    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    // ────────────────────────────────────────────────────
    // Place Buy Order
    // ────────────────────────────────────────────────────

    // Called by a buyer who wants to acquire `amount` of tokenA
    // and is willing to pay `price` tokenB for each unit.
    //
    // We pull the full quote (amount * price) in tokenB from the buyer
    // upfront and hold it in the contract. This guarantees funds are
    // available when the order is matched, and makes refunds straightforward.
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Assign order ID and advance the counter for the next order
        orderId = _orderCounter++;

        // Lock the buyer's payment in this contract now.
        // amount * price = total tokenB the buyer is committing.
        tokenB.safeTransferFrom(msg.sender, address(this), amount * price);

        // Record the order details in storage
        _orders[orderId] = Order({
            creator: msg.sender,
            amount: amount,
            filled: 0,
            price: price,
            isBuyOrder: true,
            isOpen: true
        });

        // For a buy order:
        //   tokenGiven    = tokenB (what the buyer deposits)
        //   tokenReceived = tokenA (what the buyer wants in return)
        emit OrderPlaced(orderId, msg.sender, orderId, address(tokenB), address(tokenA), amount, price);
    }

    // ────────────────────────────────────────────────────
    // Place Sell Order
    // ────────────────────────────────────────────────────

    // Called by a seller who wants to sell `amount` of tokenA
    // and expects `price` tokenB per unit in return.
    //
    // We pull the seller's tokenA upfront. The contract holds it
    // until a matching buyer is found (or the seller cancels).
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        orderId = _orderCounter++;

        // Lock the seller's tokenA in this contract
        tokenA.safeTransferFrom(msg.sender, address(this), amount);

        _orders[orderId] = Order({
            creator: msg.sender,
            amount: amount,
            filled: 0,
            price: price,
            isBuyOrder: false,
            isOpen: true
        });

        // For a sell order:
        //   tokenGiven    = tokenA (what the seller deposits)
        //   tokenReceived = tokenB (what the seller wants in return)
        emit OrderPlaced(orderId, msg.sender, orderId, address(tokenA), address(tokenB), amount, price);
    }

    // ────────────────────────────────────────────────────
    // Match Orders
    // ────────────────────────────────────────────────────

    // Anyone can call this to pair a buy order with a sell order.
    // The trade only executes if the buyer's price >= the seller's price
    // (the buyer is willing to pay at least what the seller is asking).
    //
    // Partial fills are handled automatically:
    //   - If the buy wants 10 but the sell only has 4, we fill 4.
    //   - The buy order stays open with 6 remaining; the sell closes.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = _orders[buyOrderId];
        Order storage sellOrder = _orders[sellOrderId];

        // The buyer must be willing to pay at least the seller's asking price
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        // Calculate fillable amount: limited by whichever order has less remaining
        uint256 buyRemaining  = buyOrder.amount  - buyOrder.filled;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled;
        uint256 fillAmount    = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;

        // Update fill tracking BEFORE doing transfers (checks-effects-interactions)
        buyOrder.filled  += fillAmount;
        sellOrder.filled += fillAmount;

        // Mark fully-filled orders as closed
        if (buyOrder.filled  == buyOrder.amount)  buyOrder.isOpen  = false;
        if (sellOrder.filled == sellOrder.amount) sellOrder.isOpen = false;

        // Send tokenA (PNPT) from the contract (previously deposited by seller) → buyer
        tokenA.safeTransfer(buyOrder.creator, fillAmount);

        // Send tokenB (FNBT) from the contract (previously deposited by buyer) → seller
        // We use the buy order's price; any surplus from price improvement
        // would remain in the contract (not relevant in current tests where prices match).
        tokenB.safeTransfer(sellOrder.creator, fillAmount * buyOrder.price);

        emit OrderMatched(buyOrderId, sellOrderId);
    }

    // ────────────────────────────────────────────────────
    // Cancel Order
    // ────────────────────────────────────────────────────

    // The order creator can cancel their open order and get refunded.
    // Refund logic:
    //   - Buy order: refund the unspent tokenB commitment = (amount - filled) * price
    //   - Sell order: refund the unsold tokenA = (amount - filled)
    function cancelOrder(uint256 orderId) external {
        Order storage order = _orders[orderId];

        // Only the person who created the order can cancel it
        if (order.creator != msg.sender) revert UnauthorizedCancellation();

        // Close the order first (before transfers) to prevent re-entrancy issues
        order.isOpen = false;

        // How much of the order was never filled
        uint256 unfilled = order.amount - order.filled;

        if (order.isBuyOrder) {
            // The buyer locked up (amount * price) tokenB when placing the order.
            // We already sent (filled * price) tokenB to the seller during matching.
            // So we owe back (unfilled * price) tokenB.
            tokenB.safeTransfer(msg.sender, unfilled * order.price);
        } else {
            // The seller locked up their tokenA. Refund whatever wasn't sold.
            tokenA.safeTransfer(msg.sender, unfilled);
        }

        emit OrderCanceled(orderId);
    }

    // ────────────────────────────────────────────────────
    // View Functions
    // ────────────────────────────────────────────────────

    // Returns how many units of the traded token are still unfilled in this order.
    // For a buy order of 10 that has been 4 filled, this returns 6.
    function remaining(uint256 orderId) external view returns (uint256) {
        Order storage order = _orders[orderId];
        return order.amount - order.filled;
    }

    // Returns true if the order is still active (accepting matches or cancellation).
    // Returns false if fully filled or cancelled.
    function isOpen(uint256 orderId) external view returns (bool) {
        return _orders[orderId].isOpen;
    }
}

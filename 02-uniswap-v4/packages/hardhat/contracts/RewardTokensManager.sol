// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// ─── Uniswap v4 Core imports ───────────────────────────────────────────────
// IPoolManager: the central contract in v4 that manages all pools
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// IHooks: interface for pool hooks (we're using no hooks, so address(0))
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// Currency: a value type wrapping an address (represents a token in v4)
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
// PoolKey: struct that uniquely identifies a v4 pool
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
// PoolId + library: bytes32 identifier derived from a PoolKey
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
// StateLibrary: helper to read pool state (like current sqrtPriceX96) from storage
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
// TickMath: converts between tick numbers and sqrtPriceX96 values
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

// ─── Uniswap v4 Periphery imports ─────────────────────────────────────────
// LiquidityAmounts: calculates how much liquidity corresponds to token amounts
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
// Actions: byte constants used to encode instructions for PositionManager
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
// IPositionManager: interface to mint/burn/modify concentrated liquidity positions
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

// ─── OpenZeppelin ──────────────────────────────────────────────────────────
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Local interface extensions for PositionManager functions not in IPositionManager
// ─────────────────────────────────────────────────────────────────────────────

// Uniswap's IPositionManager doesn't expose permit2 or nextTokenId in the base
// interface, but the concrete PositionManager has them as public fields.
// I'm extending the interface here so I can call them from this contract.
interface IPositionManagerExt is IPositionManager {
    // The Permit2 contract address used by PositionManager to pull tokens
    function permit2() external view returns (address);
    // Auto-incrementing NFT token ID — tells us what ID the next mint will get
    function nextTokenId() external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// RewardTokensManager
// ─────────────────────────────────────────────────────────────────────────────
//
// This contract manages a Uniswap v4 concentrated liquidity pool for the two
// reward tokens: PNPT (PnP points) and FNBT (FNB eBucks).
//
// Assignment pricing context:
//   1 FNBT = R0.10  (10 eBucks per Rand)
//   1 PNPT = R0.01  (100 points per Rand)
//   → Exchange rate: 1 FNBT = 10 PNPT
//
// The contract does two main things:
//   1. createPool()       — initialises the v4 pool at price 1:1 and stores the key
//   2. mintLiquidity()    — adds a concentrated liquidity position around the
//                           assignment-implied price (1 FNBT = 10 PNPT)
//
contract RewardTokensManager {
    // Attach PoolIdLibrary so I can call key.toId() on a PoolKey
    using PoolIdLibrary for PoolKey;
    // Attach StateLibrary so I can call poolManager.getSlot0(poolId)
    using StateLibrary for IPoolManager;

    // ────────────────────────────────────────────────────
    // Pool Configuration Constants
    // ────────────────────────────────────────────────────

    // 0.3% fee tier — standard for most volatile pairs in Uniswap
    uint24 public constant FEE_TIER = 3000;

    // Tick spacing 60 matches the 0.3% fee tier in Uniswap v4.
    // All tick boundaries must be multiples of this value.
    int24 public constant TICK_SPACING = 60;

    // No hooks for this pool — we keep it simple
    address public constant HOOKS = address(0);

    // ────────────────────────────────────────────────────
    // Target Tick Constants
    // ────────────────────────────────────────────────────
    //
    // From the assignment: 1 FNBT = 10 PNPT
    //
    // In Uniswap v4, price = amount_of_currency1 / amount_of_currency0.
    // The canonical ordering puts the lower address as currency0.
    //
    // Case A — PNPT < FNBT (PNPT is currency0, FNBT is currency1):
    //   price = FNBT / PNPT = 0.10 / 0.01 = 0.1  →  tick ≈ -23028
    //   formula: tick = floor(log(0.1) / log(1.0001))
    //
    // Case B — FNBT < PNPT (FNBT is currency0, PNPT is currency1):
    //   price = PNPT / FNBT = 0.01 / 0.10 = 10   →  tick ≈  23027
    //   formula: tick = floor(log(10) / log(1.0001))
    //
    int24 private constant TICK_PNPT_IS_C0 = -23028; // when PNPT address < FNBT address
    int24 private constant TICK_FNBT_IS_C0 =  23027; // when FNBT address < PNPT address

    // ────────────────────────────────────────────────────
    // Immutable State (set once in constructor)
    // ────────────────────────────────────────────────────

    IPoolManager          public immutable poolManager;
    IPositionManagerExt   public immutable positionManager;
    address               public immutable pnpToken;
    address               public immutable fnbToken;

    // permit2 is the intermediary contract PositionManager uses to move tokens.
    // We read its address from the PositionManager at construction time.
    address private immutable _permit2;

    // ────────────────────────────────────────────────────
    // Mutable State
    // ────────────────────────────────────────────────────

    // The PoolKey and its bytes32 ID, set once createPool() is called
    PoolKey  private _poolKey;
    bytes32  private _poolId;

    // Tracks which pools this contract has created (keyed by poolId)
    mapping(bytes32 => bool) public createdPools;

    // ────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────

    // Emitted after a new pool is successfully initialised
    event PoolCreated(
        bytes32 poolId,
        address currency0,
        address currency1,
        uint24  fee,
        int24   tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    // Emitted after liquidity is minted into the pool
    event LiquidityMinted(
        bytes32 poolId,
        uint256 positionId,
        address owner,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    );

    // ────────────────────────────────────────────────────
    // Errors
    // ────────────────────────────────────────────────────

    // Thrown if the tick range supplied to mintLiquidity doesn't span the
    // assignment-implied price of 1 FNBT = 10 PNPT
    error TickRangeDoesNotCoverAssignmentPrice();

    // ────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────

    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) {
        poolManager    = IPoolManager(_poolManager);
        positionManager = IPositionManagerExt(_positionManager);
        pnpToken       = _pnpToken;
        fnbToken       = _fnbToken;

        // Grab the permit2 address from the PositionManager.
        // Permit2 is the contract that pulls tokens from us when we mint liquidity.
        _permit2 = IPositionManagerExt(_positionManager).permit2();
    }

    // ────────────────────────────────────────────────────
    // Public Helpers
    // ────────────────────────────────────────────────────

    // Returns the canonical (sorted) currency addresses for this pool.
    // Uniswap v4 requires currency0 < currency1 (by address value).
    function getCanonicalCurrencies() public view returns (address currency0, address currency1) {
        if (pnpToken < fnbToken) {
            return (pnpToken, fnbToken);
        } else {
            return (fnbToken, pnpToken);
        }
    }

    // Returns the stored pool ID (bytes32).
    // This is only valid after createPool() has been called.
    function getPoolId() public view returns (bytes32) {
        return _poolId;
    }

    // Returns the tick that corresponds to the assignment-implied exchange rate.
    // The tick is determined at runtime based on which token ends up as currency0,
    // because token addresses are only known after deployment.
    function getTargetTick() public view returns (int24) {
        (address c0, ) = getCanonicalCurrencies();
        // If PNPT is currency0, the Uniswap price = FNBT/PNPT = 0.1 → tick -23028
        // If FNBT is currency0, the Uniswap price = PNPT/FNBT = 10  → tick 23027
        return (c0 == pnpToken) ? TICK_PNPT_IS_C0 : TICK_FNBT_IS_C0;
    }

    // ────────────────────────────────────────────────────
    // Create Pool
    // ────────────────────────────────────────────────────

    // Initialises a new Uniswap v4 pool with:
    //   - Currency pair: PNPT / FNBT (sorted by address)
    //   - Fee: 0.3%  |  Tick spacing: 60  |  Hooks: none
    //   - Starting price: sqrtPriceX96 (passed by caller)
    //
    // Returns the bytes32 pool ID.
    function createPool(uint160 sqrtPriceX96) external returns (bytes32 poolId) {
        // Step 1: determine canonical token ordering
        (address c0addr, address c1addr) = getCanonicalCurrencies();

        // Step 2: build the PoolKey struct.
        // PoolKey uniquely identifies the pool; hashing it gives the poolId.
        _poolKey = PoolKey({
            currency0:   Currency.wrap(c0addr),
            currency1:   Currency.wrap(c1addr),
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(HOOKS)
        });

        // Step 3: derive the pool ID (deterministic hash of the key)
        poolId   = PoolId.unwrap(_poolKey.toId());
        _poolId  = poolId;

        // Step 4: record this pool as created so mintLiquidity can verify it
        createdPools[poolId] = true;

        // Step 5: initialise the pool in the PoolManager at the given starting price.
        // initialize() sets the sqrtPriceX96 and stores pool state on-chain.
        poolManager.initialize(_poolKey, sqrtPriceX96);

        // Step 6: emit the event with all pool parameters
        emit PoolCreated(poolId, c0addr, c1addr, FEE_TIER, TICK_SPACING, HOOKS, sqrtPriceX96);
    }

    // ────────────────────────────────────────────────────
    // Mint Liquidity
    // ────────────────────────────────────────────────────

    // Adds a concentrated liquidity position to the pool between tickLower and tickUpper.
    //
    // The tick range MUST span the assignment-implied price (getTargetTick()).
    // If it doesn't, the position would provide zero liquidity at the current price,
    // which defeats the purpose of the assignment.
    //
    // Flow:
    //   1. Validate that the tick range covers the assignment price
    //   2. Compute the optimal liquidity amount from the desired token amounts
    //   3. Pull tokens from the caller into this contract
    //   4. Approve Permit2 so PositionManager can move tokens on our behalf
    //   5. Encode and send MINT_POSITION + SETTLE_PAIR actions to PositionManager
    //   6. Return any unused (dust) tokens to the caller
    //   7. Emit LiquidityMinted event
    function mintLiquidity(
        int24   tickLower,
        int24   tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId) {
        // ── Step 1: Validate tick range covers assignment price ──────────
        // If the range doesn't include the target tick, revert immediately.
        // This guards against depositing liquidity at a useless price point.
        int24 targetTick = getTargetTick();
        if (tickLower > targetTick || tickUpper < targetTick) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        // ── Step 2: Resolve pool ─────────────────────────────────────────
        poolId = _poolId;
        PoolId pid = PoolId.wrap(poolId);

        // ── Step 3: Compute liquidity from desired amounts ───────────────
        // Read the current pool price from on-chain state
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(pid);

        // Convert tick boundaries to sqrtPrice for the liquidity formula
        uint160 sqrtPriceA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtPriceAtTick(tickUpper);

        // getLiquidityForAmounts tells us the maximum liquidity achievable
        // given the desired token amounts and the price range.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceA,
            sqrtPriceB,
            amount0Desired,
            amount1Desired
        );

        // ── Step 4: Pull tokens from caller into this contract ───────────
        // The caller must have approved this contract before calling mintLiquidity.
        Currency currency0 = _poolKey.currency0;
        Currency currency1 = _poolKey.currency1;
        address  c0addr    = Currency.unwrap(currency0);
        address  c1addr    = Currency.unwrap(currency1);

        if (amount0Desired > 0) {
            IERC20(c0addr).transferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(c1addr).transferFrom(msg.sender, address(this), amount1Desired);
        }

        // ── Step 5: Approve Permit2 ──────────────────────────────────────
        // PositionManager moves tokens through Permit2.
        // We need to give Permit2 permission to spend our token balances.
        IERC20(c0addr).approve(_permit2, type(uint256).max);
        IERC20(c1addr).approve(_permit2, type(uint256).max);

        // ── Step 6: Encode and execute mint actions ──────────────────────
        // PositionManager uses a compact bytecode encoding: each byte is an action
        // and a parallel array holds the ABI-encoded parameters for each action.

        // We need two actions:
        //   MINT_POSITION — creates the NFT position with our liquidity
        //   SETTLE_PAIR   — tells the PositionManager to pull the tokens from us
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);

        // MINT_POSITION params: key, tickLower, tickUpper, liquidity,
        //                       amount0Max, amount1Max, recipient, hookData
        // We set the recipient to msg.sender so the NFT goes directly to the caller.
        params[0] = abi.encode(
            _poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0Desired), // max we're willing to spend on currency0
            uint128(amount1Desired), // max we're willing to spend on currency1
            msg.sender,              // the NFT owner — not this contract
            bytes("")                // no hook data needed
        );

        // SETTLE_PAIR params: which two currencies to settle the token delta for
        params[1] = abi.encode(currency0, currency1);

        // Capture the next token ID before minting so we know the positionId
        positionId = positionManager.nextTokenId();

        // Execute the mint via PositionManager.
        // deadline = block.timestamp means it must execute in this same block.
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp
        );

        // ── Step 7: Return any leftover (dust) tokens to the caller ─────
        // getLiquidityForAmounts may not use all of amount0Desired / amount1Desired.
        // We send any remainder back so the caller isn't over-charged.
        uint256 dust0 = IERC20(c0addr).balanceOf(address(this));
        uint256 dust1 = IERC20(c1addr).balanceOf(address(this));
        if (dust0 > 0) IERC20(c0addr).transfer(msg.sender, dust0);
        if (dust1 > 0) IERC20(c1addr).transfer(msg.sender, dust1);

        // ── Step 8: Emit event ───────────────────────────────────────────
        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, liquidity);
    }
}

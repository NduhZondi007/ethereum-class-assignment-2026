// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Extends IPositionManager with functions not in the base interface
interface IPositionManagerExt is IPositionManager {
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
}

// Manages a Uniswap v4 pool for PNPT/FNBT reward tokens.
// Assignment pricing: 1 FNBT = R0.10, 1 PNPT = R0.01, so 1 FNBT = 10 PNPT.
contract RewardTokensManager {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Pool configuration
    uint24 public constant FEE_TIER     = 3000; // 0.3%
    int24  public constant TICK_SPACING = 60;
    address public constant HOOKS       = address(0);

    IPoolManager         public immutable poolManager;
    IPositionManagerExt  public immutable positionManager;
    address              public immutable pnpToken;
    address              public immutable fnbToken;
    address              private immutable _permit2;

    PoolKey  private _poolKey;
    bytes32  private _poolId;
    mapping(bytes32 => bool) public createdPools;

    event PoolCreated(
        bytes32 poolId,
        address currency0,
        address currency1,
        uint24  fee,
        int24   tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    event LiquidityMinted(
        bytes32 poolId,
        uint256 positionId,
        address owner,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    );

    error TickRangeDoesNotCoverAssignmentPrice();

    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) {
        poolManager     = IPoolManager(_poolManager);
        positionManager = IPositionManagerExt(_positionManager);
        pnpToken        = _pnpToken;
        fnbToken        = _fnbToken;
        _permit2        = IPositionManagerExt(_positionManager).permit2();
    }

    // Returns the canonical (sorted by address) currency pair for this pool.
    // Uniswap v4 requires currency0 < currency1 by address.
    function getCanonicalCurrencies() public view returns (address currency0, address currency1) {
        if (pnpToken < fnbToken) {
            return (pnpToken, fnbToken);
        } else {
            return (fnbToken, pnpToken);
        }
    }

    function getPoolId() public view returns (bytes32) {
        return _poolId;
    }

    function getTargetTick() public view returns (int24) {}

    // Initialises the pool in Uniswap v4 PoolManager with 0.3% fee, tick spacing 60, no hooks.
    // sqrtPriceX96 sets the starting price of the pool.
    function createPool(uint160 sqrtPriceX96) external returns (bytes32 poolId) {
        (address c0addr, address c1addr) = getCanonicalCurrencies();

        _poolKey = PoolKey({
            currency0:   Currency.wrap(c0addr),
            currency1:   Currency.wrap(c1addr),
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(HOOKS)
        });

        // The pool ID is a deterministic hash of the pool key
        poolId  = PoolId.unwrap(_poolKey.toId());
        _poolId = poolId;
        createdPools[poolId] = true;

        // Initialise the pool in PoolManager at the given starting price
        poolManager.initialize(_poolKey, sqrtPriceX96);

        emit PoolCreated(poolId, c0addr, c1addr, FEE_TIER, TICK_SPACING, HOOKS, sqrtPriceX96);
    }

    function mintLiquidity(
        int24   tickLower,
        int24   tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId) {}
}

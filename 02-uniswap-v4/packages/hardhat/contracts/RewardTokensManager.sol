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

interface IPositionManagerExt is IPositionManager {
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
}

contract RewardTokensManager {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 public constant FEE_TIER     = 3000;
    int24  public constant TICK_SPACING = 60;
    address public constant HOOKS       = address(0);

    // Assignment pricing: 1 FNBT = 10 PNPT
    // Uniswap price = currency1 / currency0
    // If PNPT < FNBT: price = FNBT/PNPT = 0.1, tick = floor(log(0.1)/log(1.0001)) = -23028
    // If FNBT < PNPT: price = PNPT/FNBT = 10,  tick = floor(log(10)/log(1.0001))  =  23027
    int24 private constant TICK_PNPT_IS_C0 = -23028;
    int24 private constant TICK_FNBT_IS_C0 =  23027;

    IPoolManager         public immutable poolManager;
    IPositionManagerExt  public immutable positionManager;
    address              public immutable pnpToken;
    address              public immutable fnbToken;
    address              private immutable _permit2;

    PoolKey  private _poolKey;
    bytes32  private _poolId;
    mapping(bytes32 => bool) public createdPools;

    event PoolCreated(bytes32 poolId, address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96);
    event LiquidityMinted(bytes32 poolId, uint256 positionId, address owner, int24 tickLower, int24 tickUpper, uint128 liquidity);

    error TickRangeDoesNotCoverAssignmentPrice();

    constructor(address _poolManager, address _positionManager, address _pnpToken, address _fnbToken) {
        poolManager     = IPoolManager(_poolManager);
        positionManager = IPositionManagerExt(_positionManager);
        pnpToken        = _pnpToken;
        fnbToken        = _fnbToken;
        _permit2        = IPositionManagerExt(_positionManager).permit2();
    }

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

    // Returns the tick that corresponds to the assignment exchange rate (1 FNBT = 10 PNPT).
    // The tick depends on which token ends up as currency0 (determined by address ordering).
    // We compute this at runtime because token addresses are only known post-deployment.
    function getTargetTick() public view returns (int24) {
        (address c0, ) = getCanonicalCurrencies();
        // If PNPT is the lower address it becomes currency0, price = FNBT/PNPT = 0.1 → tick -23028
        // If FNBT is the lower address it becomes currency0, price = PNPT/FNBT = 10  → tick  23027
        return (c0 == pnpToken) ? TICK_PNPT_IS_C0 : TICK_FNBT_IS_C0;
    }

    function createPool(uint160 sqrtPriceX96) external returns (bytes32 poolId) {
        (address c0addr, address c1addr) = getCanonicalCurrencies();

        _poolKey = PoolKey({
            currency0:   Currency.wrap(c0addr),
            currency1:   Currency.wrap(c1addr),
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(HOOKS)
        });

        poolId  = PoolId.unwrap(_poolKey.toId());
        _poolId = poolId;
        createdPools[poolId] = true;

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

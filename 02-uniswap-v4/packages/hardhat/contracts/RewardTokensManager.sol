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
        return pnpToken < fnbToken ? (pnpToken, fnbToken) : (fnbToken, pnpToken);
    }

    function getPoolId() public view returns (bytes32) { return _poolId; }

    function getTargetTick() public view returns (int24) {
        (address c0, ) = getCanonicalCurrencies();
        return (c0 == pnpToken) ? TICK_PNPT_IS_C0 : TICK_FNBT_IS_C0;
    }

    function createPool(uint160 sqrtPriceX96) external returns (bytes32 poolId) {
        (address c0addr, address c1addr) = getCanonicalCurrencies();
        _poolKey = PoolKey({
            currency0: Currency.wrap(c0addr), currency1: Currency.wrap(c1addr),
            fee: FEE_TIER, tickSpacing: TICK_SPACING, hooks: IHooks(HOOKS)
        });
        poolId  = PoolId.unwrap(_poolKey.toId());
        _poolId = poolId;
        createdPools[poolId] = true;
        poolManager.initialize(_poolKey, sqrtPriceX96);
        emit PoolCreated(poolId, c0addr, c1addr, FEE_TIER, TICK_SPACING, HOOKS, sqrtPriceX96);
    }

    // Add concentrated liquidity to the pool within [tickLower, tickUpper].
    // The range must cover getTargetTick() — the assignment-implied 1 FNBT = 10 PNPT price.
    function mintLiquidity(
        int24   tickLower,
        int24   tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId) {
        // Revert if the tick range doesn't include the assignment price point
        int24 targetTick = getTargetTick();
        if (tickLower > targetTick || tickUpper < targetTick) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        poolId = _poolId;

        // Read current pool price from on-chain state
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(PoolId.wrap(poolId));

        // Compute max liquidity we can get from the desired token amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        Currency currency0 = _poolKey.currency0;
        Currency currency1 = _poolKey.currency1;
        address  c0addr    = Currency.unwrap(currency0);
        address  c1addr    = Currency.unwrap(currency1);

        // Pull tokens from caller into this contract
        if (amount0Desired > 0) IERC20(c0addr).transferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) IERC20(c1addr).transferFrom(msg.sender, address(this), amount1Desired);

        // Give Permit2 permission to move tokens on behalf of this contract to PoolManager
        IERC20(c0addr).approve(_permit2, type(uint256).max);
        IERC20(c1addr).approve(_permit2, type(uint256).max);

        // Encode MINT_POSITION + SETTLE_PAIR actions for PositionManager
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        // Mint the NFT position directly to msg.sender (not this contract)
        params[0] = abi.encode(_poolKey, tickLower, tickUpper, uint256(liquidity),
            uint128(amount0Desired), uint128(amount1Desired), msg.sender, bytes(""));
        params[1] = abi.encode(currency0, currency1);

        // Capture the next token ID before minting
        positionId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Return any unspent tokens (dust) back to the caller
        uint256 dust0 = IERC20(c0addr).balanceOf(address(this));
        uint256 dust1 = IERC20(c1addr).balanceOf(address(this));
        if (dust0 > 0) IERC20(c0addr).transfer(msg.sender, dust0);
        if (dust1 > 0) IERC20(c1addr).transfer(msg.sender, dust1);

        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, liquidity);
    }
}

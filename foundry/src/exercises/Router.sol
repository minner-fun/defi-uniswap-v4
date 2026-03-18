// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// import {console} from "forge-std/Test.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {SwapParams} from "../types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {CurrencyLib} from "../libraries/CurrencyLib.sol";
import {MIN_SQRT_PRICE, MAX_SQRT_PRICE} from "../Constants.sol";
import {TStore} from "../TStore.sol";

contract Router is TStore, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;
    using CurrencyLib for address;

    // Actions
    uint256 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 private constant SWAP_EXACT_IN = 0x07;
    uint256 private constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 private constant SWAP_EXACT_OUT = 0x09;

    IPoolManager public immutable poolManager;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMin;
        bytes hookData;
    }

    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMax;
        bytes hookData;
    }

    struct PathKey {
        address currency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct ExactInputParams {
        address currencyIn;
        // First element + currencyIn determines the first pool to swap
        // Last element + previous path element's currency determines the last pool to swap
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMin;
    }

    struct ExactOutputParams {
        address currencyOut;
        // Last element + currencyOut determines the last pool to swap
        // First element + second path element's currency determines the first pool to swap
        PathKey[] path;
        uint128 amountOut;
        uint128 amountInMax;
    }

    error UnsupportedAction(uint256 action);

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data)
        external
        onlyPoolManager
        returns (bytes memory)
    {
        uint256 action = _getAction();
        // Write your code here
        if (action == SWAP_EXACT_IN_SINGLE){
            (address msgSender, ExactInputSingleParams memory params) = 
                abi.decode(data, (address, ExactInputSingleParams));
            (int128 amount0, int128 amount1) = _swap(
                params.poolKey,
                params.zeroForOne,
                -(params.amountIn.toInt256()),
                params.hookData
            );
            (
                address currencyIn,
                address currencyOut,
                uint256 amountIn,
                uint256 amountOut
            ) = params.zeroForOne
                ? (
                    params.poolKey.currency0,
                    params.poolKey.currency1,
                    (-amount0).toUint256(),
                    amount1.toUint256()
                )
                : (
                    params.poolKey.currency1,
                    params.poolKey.currency0,
                    (-amount1).toUint256(),
                    amount0.toUint256()
                );
            require(amountOut > params.amountOutMin, "amount out too min");
            _takeAndSettle({
                dst: msgSender,
                currencyIn: currencyIn,
                currencyOut: currencyOut,
                amountIn: amountIn,
                amountOut: amountOut
            });
            return abi.encode(amountOut);
        }else if (action == SWAP_EXACT_OUT_SINGLE){
            (address msgSender, ExactOutputSingleParams memory params) = abi.decode(data, (address, ExactOutputSingleParams));
            (int128 amount0, int128 amount1) = _swap(
                params.poolKey,
                params.zeroForOne,
                params.amountOut.toInt256(),   // 在swap的内部，通过判断amountSpecified的正负，来断定指定金额是输入还是输出
                params.hookData
            );
            (
                address currencyIn,
                address currencyOut,
                uint256 amountIn,
                uint256 amountOut
            ) = params.zeroForOne
                ? (
                    params.poolKey.currency0,
                    params.poolKey.currency1,
                    (-amount0).toUint256(),
                    amount1.toUint256()
                )
                : (
                    params.poolKey.currency1,
                    params.poolKey.currency0,
                    (-amount1).toUint256(),
                    amount0.toUint256()
                );
            require(amountIn <= params.amountInMax, "amount in > max");

            _takeAndSettle({
                dst: msgSender,
                currencyIn: currencyIn,
                currencyOut: currencyOut,
                amountIn: amountIn,
                amountOut: amountOut
            });
            return abi.encode(amountIn);
        }

        revert UnsupportedAction(action);
    }

    function swapExactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_IN_SINGLE)
        returns (uint256 amountOut)
    {
        // Write your code here
        address currencyIn = params.zeroForOne
            ? params.poolKey.currency0
            : params.poolKey.currency1;
        currencyIn.transferIn(msg.sender, params.amountIn);
        bytes memory res = poolManager.unlock(abi.encode(msg.sender, params));
        amountOut = abi.decode(res, (uint256));
        _refund(currencyIn, msg.sender);
    }

    function swapExactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_OUT_SINGLE)
        returns (uint256 amountIn)
    {
        // Write your code here
        address currencyIn = params.zeroForOne
            ? params.poolKey.currency0
            : params.poolKey.currency1;
        currencyIn.transferIn(msg.sender, params.amountInMax);
        poolManager.unlock(abi.encode(msg.sender, params));
        uint256 refunded = _refund(currencyIn, msg.sender);
        if (refunded < params.amountInMax){
            return params.amountInMax - refunded;
        }
        return 0;
    }

    function swapExactInput(ExactInputParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_IN)
        returns (uint256 amountOut)
    {
        // Write your code here
    }

    function swapExactOutput(ExactOutputParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_OUT)
        returns (uint256 amountIn)
    {
        // Write your code here
    }

    function _swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData
    ) private returns (int128 amount0, int128 amount1){
        int256 d = poolManager.swap({
            key:key,
            params: SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            hookData: hookData
        });
        BalanceDelta delta = BalanceDelta.wrap(d);
        return (delta.amount0(), delta.amount1());
    }

    function _takeAndSettle(
        address dst,
        address currencyIn,
        address currencyOut,
        uint256 amountIn,
        uint256 amountOut
    )private {
        poolManager.take(currencyOut, dst, amountOut);
        poolManager.sync(currencyIn);
        if (currencyIn == address(0)){
            poolManager.settle{value: amountIn}();
        }else{
            IERC20(currencyIn).transfer(address(poolManager), amountIn);
            poolManager.settle();
        }
    }

    function _refund(address currency, address dst) private returns(uint256){
        uint256 bal = currency.balanceOf(address(this));
        if(bal > 0){
            currency.transferOut(dst, bal);
        }
        return bal;
    }
}

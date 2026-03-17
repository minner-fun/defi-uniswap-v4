// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// import {console} from "forge-std/Test.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {CurrencyLib} from "../libraries/CurrencyLib.sol";
import {console2} from "forge-std/console2.sol";
// import {Test, console} from "forge-std/Test.sol";

contract Flash is IUnlockCallback {
    using CurrencyLib for address;

    IPoolManager public immutable poolManager;
    // Contract address to test flash loan
    address private immutable tester;

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(address _poolManager, address _tester) {
        poolManager = IPoolManager(_poolManager);
        tester = _tester;
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data)
        external
        onlyPoolManager
        returns (bytes memory)
    {
        // Write your code here

        (address currency, uint256 amount) = abi.decode(data, (address, uint256));  // 回调第一步先把参数解出来，

        poolManager.take(currency, address(this), amount);                         // 直接从poolManager哪里拿钱

        (bool success, ) = tester.call("");
        require(success, 'test fail');
        uint256 tmp_number = IERC20(currency).balanceOf(address(this));             // 现在已经拿到了
        console2.log('tmp_number: %e', tmp_number);
        
        // 这里做任何套利的行文

        poolManager.sync(currency);                                                 // 还钱之前先sync同步

        if (currency == address(0)){                               
            poolManager.settle{value:amount}();                                     // 如果是eth就用value还
        }else{
            IERC20(currency).transfer(address(poolManager), amount);                // 如果是erc20，就直接给poolManager转账，然后再调用settle
            poolManager.settle();
        }

        tmp_number = IERC20(currency).balanceOf(address(this));
        console2.log('tmp_number: %e', tmp_number);
        

        return "";                                                                  // 结束
    }

    function flash(address currency, uint256 amount) external {
        // Write your code here
        bytes memory data = abi.encode(currency, amount);  // 将要借的代币币种和数量encode
        poolManager.unlock(data);                        // 调用unlocl解锁，开始流程
    }
}

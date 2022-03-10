// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

contract GPOStructs {
    event TokensSwaped(
        address indexed purchaser,
        uint256 amountIn,
        uint256 amountOut,
        bool direction // false: GPO-X, true: X-GPO
    );

    event ReserveTokenTransfer(
        address indexed to,
        uint256 amount
    );

    event WalletWhitelistChanged(
        address indexed wallet,
        bool whitelist
    );

    event PoolParametersChanged(
        address token,
        uint24 poolFee
    );

    event FreeTradeChanged(
        bool freeTrade
    );

    event SwapPermChanged(
        bool swapPerm
    );

    event FeeSplitsChanged(
        uint256 length,
        FeeSplit[] feeSplitsArray
    );

    event WalletLockChanged(
        address indexed wallet,
        uint256 lockValue
    );

    // FeeSplit stores the "recipient" wallet address and the respective percentage of the feeOnSwap which are to be sent to it.  
    struct FeeSplit {
        address recipient;
        uint16 fee;
    }
}
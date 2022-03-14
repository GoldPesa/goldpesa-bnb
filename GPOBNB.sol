
// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "./BaseGPO.sol";
import "./utils/IPinkAntiBot.sol";
import "pancakeswap-peripheral/contracts/interfaces/IPancakeRouter02.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

/**
____________________________
Description:
GoldPesa Option Mini Contract (GPOm) - 1 GPOm represents a fraction of a GPO (GoldPesa Option), the option to purchase 1 GPX at spot PAXG price + 1 %.
__________________________________
 */
contract GPOBNB is BaseGPO {

    // Event to be emitted when enabling/disabling the Pink anti-bot
    event AntiBotChanged(
        bool antiBotEnabled
    );

    // PancakeSwap Router Address
    IPancakeRouter02 public immutable swapRouter;
    // Pink anti-bot instance
    IPinkAntiBot public pinkAntiBot;

    // Pink anti-bot flag
    bool public antiBotEnabled = false;

    constructor(IPancakeRouter02 _swapRouter, uint256 _walletsTimelockedUntil, address _pinkAntiBot) BaseGPO(_walletsTimelockedUntil, true) {
        swapRouter = _swapRouter;
        
        pinkAntiBot = IPinkAntiBot(_pinkAntiBot);
        if (antiBotEnabled) 
            pinkAntiBot.setTokenOwner(msg.sender);
    }

    // _transfer override to implement the 10% fee on transfer
    // as well as automatic swapping and fee distribution to the
    // different GoldPesa wallets
    function _transfer(address from, address to, uint256 amount) internal virtual override {        
        address owner = from; // from
        if (!freeTrade && !whitelistedWallets[from]) { 
            uint256 difference = calculateFeeOnSwap(amount);
            super._transfer(owner, to, amount - difference);
            super._transfer(owner, address(this), difference);

            if (from != authorizedPool && to != authorizedPool) {
                performSwapAndDistribute();
            }
        } else {
            super._transfer(owner, to, amount);
        }
    }

    // Protected function, callable from inside the contract or the authorized owner, which
    // swaps the current balance of the GPOm smart contract and redistributes it to
    // the feeSplits array of wallets
    function performSwapAndDistribute() public onlyOwner {
        uint256 currBalance = balanceOf(address(this));
        approve(address(swapRouter), currBalance);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = addrUSDC;
        swapRouter.swapExactTokensForETH(currBalance, 0, path, address(this), block.timestamp);
        distributeFeeBNB(address(this).balance);
    }

    // Default function to receive ETH from the swap 
    receive() external payable {}

    // Function that enables/disables the Pink anti-bot
    function toggleAntiBotEnabled() external onlyOwner {
        antiBotEnabled = !antiBotEnabled;
        emit AntiBotChanged(antiBotEnabled);
    }

    // Override the Ownable._transferOwnership so it can set the token owner for the Pink anti-bot's intnernal mechanisms
    function _transferOwnership(address newOwner) internal override {
        Ownable._transferOwnership(newOwner);
        if (antiBotEnabled) 
            pinkAntiBot.setTokenOwner(newOwner);
    }
    
    // Distributes the feeOnSwap amount collected during any swap transaction to the addresses defined in the "feeSplits" array
    function distributeFeeBNB(uint256 amount) internal {
        uint256 grandTotal = 0;
        for (uint256 i = 0; i < feeSplits.length; i++) {
            FeeSplit storage f = feeSplits[i];
            uint256 distributeAmount = amount * f.fee / 100;
            TransferHelper.safeTransferETH(f.recipient, distributeAmount);
            grandTotal += distributeAmount;
        }
        if (grandTotal != amount && feeSplits.length > 0) {
            FeeSplit storage f = feeSplits[0];
            TransferHelper.safeTransferETH(f.recipient, amount - grandTotal);
        }
    }

    // Calculates the contract address of the swapping pool from the other token 
    // address and accordingly includes it in the whitelistedWallets mapping
    function setPoolParameters(address WBNB) external onlyOwner {
        require(WBNB != address(0x0));

        addrUSDC = WBNB;
        whitelistedWallets[authorizedPool] = false;
    
        authorizedPool = address(0x00);
        address token0 = address(this);
        address token1 = WBNB;
        if (token0 > token1) (token0, token1) = (token1, token0);

        authorizedPool = address(uint160(uint256(keccak256(abi.encodePacked(
                hex'ff',
                0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73,
                keccak256(abi.encodePacked(token0, token1)),
                hex'00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5' // init code hash
        )))));
    
        whitelistedWallets[authorizedPool] = true;
        emit PoolParametersChanged(WBNB, 0);
    }
    
    // Override hardCapOnToken to match the GPOm => GPO mapping
    function hardCapOnToken() public override view returns (uint256) {
        return fixedSupply * 1000 * (10**(uint256(decimals())));
    }

    // Custom capOnWallet field as the inherited one from BaseGPO is constant
    uint256 private capOnWalletCustom = 100_000;

    // Changes the hard cap on wallet
    function setHardCapOnWallet(uint256 _capOnWalletCustom) public  {
        capOnWalletCustom = _capOnWalletCustom;
    }

    // Override hardCapOnWallet to match the GPOm => GPO mapping, as well as include a post-depeloyment customizable cap
    function hardCapOnWallet() public override view returns (uint256) {
        return capOnWalletCustom * 1000 * (10**(uint256(decimals())));
    }

    // Pink anti-bot protection implementation
    function _beforeTokenTransferAdditional(address from, address to, uint256 amount) internal override {
        if (antiBotEnabled)
            pinkAntiBot.onPreTransferCheck(from, to, amount);
    }

    // BEP20-specific function to get the owner
    function getOwner() external view returns (address) {
        return owner();
    }

}
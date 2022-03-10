
// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "./BaseGPO.sol";
import "./utils/IPinkAntiBot.sol";
import "pancakeswap-peripheral/contracts/interfaces/IPancakeRouter02.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

/**
____________________________
Description:
GoldPesa Option Contract (GPO) - 1 GPO represents the option to purchase 1 GPX at spot gold price + 1 %.
__________________________________
 */
contract GPOBNB is BaseGPO {

    event AntiBotChanged(
        bool antiBotEnabled
    );

    // PancakeSwap Router Address
    IPancakeRouter02 public immutable swapRouter;
    IPinkAntiBot public pinkAntiBot;

    bool public antiBotEnabled = false;

    constructor(IPancakeRouter02 _swapRouter, uint256 _walletsTimelockedUntil, address _pinkAntiBot) BaseGPO(_walletsTimelockedUntil, true) {
        swapRouter = _swapRouter;
        
        pinkAntiBot = IPinkAntiBot(_pinkAntiBot);
        if (antiBotEnabled) 
            pinkAntiBot.setTokenOwner(msg.sender);
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender(); // from
        
        if (!freeTrade && ((owner == authorizedPool && !whitelistedWallets[to]) || (to == authorizedPool && !whitelistedWallets[owner]))) { 
            uint256 difference = calculateFeeOnSwap(amount);
            _transfer(owner, to, amount - difference);

            _transfer(owner, address(this), difference);

            approve(address(swapRouter), difference);
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = addrUSDC;
            uint[] memory amounts = swapRouter.swapExactTokensForETH(difference, 0, path, address(this), block.timestamp + 20*60);
            distributeFeeBNB(amounts[amounts.length - 1]);
            return true;
        } else {
            _transfer(owner, to, amount);
            return true;
        }
    }

    function toggleAntiBotEnabled() external onlyOwner {
        antiBotEnabled = !antiBotEnabled;
        emit AntiBotChanged(antiBotEnabled);
    }

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
    
    function hardCapOnToken() public override view returns (uint256) {
        return fixedSupply * 1000 * (10**(uint256(decimals())));
    }

    function hardCapOnWallet() public override view returns (uint256) {
        return capOnWallet * 1000 * (10**(uint256(decimals())));
    }

    function _beforeTokenTransferAdditional(address from, address to, uint256 amount) internal override {
        if (antiBotEnabled)
            pinkAntiBot.onPreTransferCheck(from, to, amount);
    }

    function getOwner() external view returns (address) {
        return owner();
    }

}
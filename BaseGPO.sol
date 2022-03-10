// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./GPOStructs.sol";

/**
____________________________
Description:
GoldPesa Option Contract (GPO) - 1 GPO represents the option to purchase 1 GPX at spot gold price + 1 %.
__________________________________
 */
abstract contract BaseGPO is ERC20, Pausable, Ownable, AccessControl, GPOStructs {
    
//     // Token Name
//     string public constant _name = "JNA";
//     // Token Symbol
//     string public constant _symbol = "Jayna Token";
    // GPO Hard Cap
    uint256 public constant fixedSupply = 100_000_000;
    // Wallet Hard Cap
    uint256 public constant capOnWallet = 100_000;
    // GoldPesa fee on swap percentage
    uint256 public feeOnSwap = 10;
    // USDC ERC20 token Address
    address public addrUSDC;
    // Uniswap V3 Pool Fee * 10000 = 1 %
    uint24 internal swapPoolFee = 10000;
    // Uniswap V3 GPO/USDC liquidity pool address
    address public authorizedPool;
    // Time when Pre-Sale and Sale tokens will be unlocked (Unix Time)
    uint256 public walletsTimelockedUntil;
    // When freeTrade is true the token bypasses the hard cap on wallet and can be traded freely on any exchange
    bool public freeTrade = false;
    // The feeOnSwap percentage is distributed to the addresses and their respective percentage which are held in the feeSplits array
    FeeSplit[] public feeSplits;
    // Keeps a record of the number of addresses in the feeSplits array 
    uint256 public feeSplitsLength;

    // Defines an Access Control role called "CAN_LOCK" which is granted to addresses which are allowed to lock wallet addresses during the Sale and Pre-Sale phase
    bytes32 public constant AUTHORIZED_LOCK =
        keccak256("CAN_LOCK");
    bytes32 public constant AUTHORIZED_OPERATOR =
        keccak256("CAN_OPERATE");

    modifier authorizedLocker() {
        require(hasRole(AUTHORIZED_LOCK, _msgSender()));
        _;
    }

    modifier authorizedOperator() {
        require(hasRole(AUTHORIZED_OPERATOR, _msgSender()));
        _;
    }

    // Mapping which holds information of the wallet addresses which are locked (true) /unlocked (false)
    mapping(address => bool) public lockedWallets;
    // Mapping which holds details of the wallet addresses which bypass the wallet hard cap and are able to swap with the Uniswap GPO/USDC liquidity pool
    mapping(address => bool) public whitelistedWallets;
    // Mapping which holds details of the amount of GPO tokens are locked in the lockedWallets mapping 
    mapping(address => uint256) public lockedWalletsAmount;
    bool public swapEnabled = false;
    bool public mintOnDemand = false;
    // Upon deployment, the constructor is only executed once
    constructor(
        uint256 _walletsTimelockedUntil,
        bool _mintOnDemand
    ) ERC20("JNA", "Jayna Token") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        walletsTimelockedUntil = _walletsTimelockedUntil;
        whitelistedWallets[address(0x0)] = true;
        whitelistedWallets[address(this)] = true;

        mintOnDemand = _mintOnDemand;
        if (!mintOnDemand) {
            _mint(address(this), hardCapOnToken());
        }
    }

    // Enables GoldPesa to manually transfer GPO tokens from the GPO contract to another wallet address
    function transferTokensTo(address _to, uint256 amount) external onlyOwner {
        _transfer(address(this), _to, amount);
        emit ReserveTokenTransfer(_to, amount);
    }
    // Enables GoldPesa to manually add or remove wallet addresses from the whitelistedWallets mapping
    function changeWalletWhitelist(address _addr, bool yesOrNo) external onlyOwner {
        whitelistedWallets[_addr] = yesOrNo;
        emit WalletWhitelistChanged(_addr, yesOrNo);
    }

    // Enables GoldPesa to set the state of the contract to "freeTrade" 
    function switchFreeTrade() external onlyOwner {
        freeTrade = !freeTrade;
    }

    function switchSwapEnabled() external onlyOwner {
        swapEnabled = !swapEnabled;
    }

    // Enables GoldPesa to set the feeOnSwap 
    function setFeeOnSwap(uint24 _feeOnSwap) external onlyOwner {
        feeOnSwap = _feeOnSwap;
    }
    // Enables GoldPesa to set the "feeOnSwap" distribution details 
    // Only GoldPesa executes this
    function setFeeSplits(FeeSplit[] memory _feeSplits) external onlyOwner {
        uint256 grandTotal = 0;
        for (uint256 i = 0; i < _feeSplits.length; i++) {
            FeeSplit memory f = _feeSplits[i];
            grandTotal += f.fee;
        }
        require(grandTotal == 100);
        delete feeSplits;
        for (uint256 i = 0; i < _feeSplits.length; i++) {
            feeSplits.push(_feeSplits[i]);
        }
        feeSplitsLength = _feeSplits.length;
        emit FeeSplitsChanged(feeSplitsLength, feeSplits);
    }
    // Distributes the feeOnSwap amount collected during any swap transaction to the addresses defined in the "feeSplits" array
    function distributeFee(uint256 amount) internal {
        uint256 grandTotal = 0;
        for (uint256 i = 0; i < feeSplits.length; i++) {
            FeeSplit storage f = feeSplits[i];
            uint256 distributeAmount = amount * f.fee / 100;
            TransferHelper.safeTransfer(addrUSDC, f.recipient, distributeAmount);
            grandTotal += distributeAmount;
        }
        if (grandTotal != amount && feeSplits.length > 0) {
            FeeSplit storage f = feeSplits[0];
            TransferHelper.safeTransfer(addrUSDC, f.recipient, amount - grandTotal);
        }
    }

    function _beforeTokenTransferAdditional(address from, address to, uint256 amount) internal virtual;

    // Defines the rules that must be satisfied before GPO can be transferred
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);
        // Ensures that GPO token holders cannot burn their own tokens, unless they are whitelisted
        require(to != address(0x0) || whitelistedWallets[from] || hasRole(AUTHORIZED_OPERATOR, from), "GPO_ERR: Cannot burn");
        _beforeTokenTransferAdditional(from, to, amount);
        // Unless "freeTrade" has been enabled this require statement rejects any transfers to wallets which will break the 100,000 GPO wallet hard cap unless the 
        // receiving wallet address is a "whitelistedWallet"
        require(
            freeTrade || 
            from == address(0x0) ||
            whitelistedWallets[to] || 
            balanceOf(to) + amount <= hardCapOnWallet(),
            "GPO_ERR: Hard cap on wallet reached" 
        );
        // Disables all GPO transfers if the token has been paused by GoldPesa
        require(!paused(), "ERC20Pausable: token transfer while paused");
        // Rejects transfers made from locked wallets which are greater than the wallet's "lockedWalletsAmount" until the date where all tokens are unlocked
        require(block.timestamp >= walletsTimelockedUntil || 
            !lockedWallets[from] || 
            (lockedWallets[from] && amount <= (balanceOf(from) - lockedWalletsAmount[from])), "Cannot transfer token as the wallet is locked");
    }
    
    function mintTo(address account, uint256 amount) external authorizedOperator {
        require(mintOnDemand);
        _mint(account, amount);
    }

    function _mint(address account, uint256 amount) internal virtual override {
        // Ensures that GPO token hard cap of 100,000,000 is not breached even if the mint function is called internally
        require(
            ERC20.totalSupply() + amount <= hardCapOnToken(),
            "ERC20Capped: cap exceeded"
        );
        super._mint(account, amount);
    }

    // Returns the GPO token hard cap ("fixedSupply") in wei
    function hardCapOnToken() public virtual view returns (uint256) {
        return fixedSupply * (10**(uint256(decimals())));
    }
    // Returns the GPO token wallet hard cap ("capOnWallet") in wei
    function hardCapOnWallet() public virtual view returns (uint256) {
        return capOnWallet * (10**(uint256(decimals())));
    }
    // Returns the GoldPesa feeOnSwap in USDC which is used in the swap functions
    function calculateFeeOnSwap(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount * feeOnSwap / 100;
    }
    // Enables GoldPesa to lock and unlock wallet address manually 
    function lockUnlockWallet(address account, bool yesOrNo, uint256 amount) external authorizedLocker {
        lockedWallets[account] = yesOrNo;
        if (yesOrNo) {
            uint256 lockedValue = lockedWalletsAmount[account] + amount;
            require(lockedValue <= balanceOf(account), "Cannot lock more than what the wallet has");
            lockedWalletsAmount[account] = lockedValue;
            
            emit WalletLockChanged(account, lockedValue);
        } else {
            lockedWalletsAmount[account] = 0;
            
            emit WalletLockChanged(account, 0);
        }
    }
    // Pause the GPO token transfers
    function pause() external onlyOwner {
        _pause();
    }
    // Unpause the GPO token transfer
    function unpause() external onlyOwner {
        _unpause();
    }

    function burn(uint256 amount) public virtual {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public virtual {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    function unsafeSetAuthorizedPool(address pool, uint24 fee) public onlyOwner {
        whitelistedWallets[authorizedPool] = false;
        authorizedPool = pool;
        whitelistedWallets[authorizedPool] = true;
        swapPoolFee = fee;
        emit PoolParametersChanged(authorizedPool, fee);
    }

}

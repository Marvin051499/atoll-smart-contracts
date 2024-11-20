// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract StakedToken is ERC20, Ownable2Step, IERC4626 {
    // === SECURITY ===
    using SafeERC20 for IERC20;
    address public manager;
    address public securityManager;
    uint256 public paused; // 0 for not paused, 1 for paused

    // Note that shadow should be 18-decimal token.
    constructor(
        IERC20 _token,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) Ownable(msg.sender) {
        asset = address(_token);
        _totalShares = 1e17; // mint 0.1 sateth for avoiding empty market
        _mint(msg.sender, _totalShares);
        _exchangeRate = 1e18;
        lastUpdated = block.timestamp;
    }

    modifier onlyManager() {
        require(msg.sender == manager || msg.sender == owner(), "Not Manager");
        _;
    }

    modifier onlySecurityManager {
        require(msg.sender == securityManager || msg.sender == manager || msg.sender == owner(), "Not Security Manager");
        _;
    }

    modifier whenNotPaused() {
        require(paused == 0, "Paused");
        _;
    }

    function configSecurity(address _manager, address _securityManager) external onlyOwner {
        manager = _manager;
        securityManager = _securityManager;
    }

    // === EVENTS ===
    event AccuredInterest(uint256 accruedInterest);
    event Paused(uint256 isPaused);
    event RerwardRateUpdated(uint256 newRate);

    // === CORE LOGICS ===
    address public immutable asset;
    uint256 private immutable ONE = 1e18;
    uint256 public ratePerSecond;
    uint256 private _totalShares;
    uint256 private _exchangeRate;
    uint256 public lastUpdated;
    uint256 public marketCapacity;

    function _setMarketCapacity(uint256 _marketCapacity) internal {
        marketCapacity = _marketCapacity;
    }

    function setMarketCapacity(uint256 _marketCapacity) external onlyOwner {
        _setMarketCapacity(_marketCapacity);
    }

    function _exchangeRateInternal() internal view returns (uint256) {
        if (_totalShares == 0) {
            return ONE;
        } else {
            return
                _exchangeRate + (block.timestamp - lastUpdated) * ratePerSecond;
        }
    }

    function exchangeRate() external view returns (uint256) {
        return _exchangeRateInternal();
    }

    // apr should be scaled by 1e18
    // e.g., 10% apr should be 1e18 * 10 / 100 = 1e17
    function _setRateWithAPR(uint256 apr) internal {
        _exchangeRate = _exchangeRateInternal();
        ratePerSecond = Div(_exchangeRate * apr / 1e18, 365 days, RoudingMode.ROUND_DOWN);
        lastUpdated = block.timestamp;
    }

    function setRateWithAPR(uint256 apr) external onlyManager {
        _setRateWithAPR(apr);
    }

    function pause() external onlySecurityManager {
        paused = 1;
        _setRateWithAPR(0);
        _setMarketCapacity(0);
        emit Paused(paused);
    }

    function unPause(uint256 apr, uint256 capacity) external onlyOwner {
        paused = 0;
        _setRateWithAPR(apr);
        _setMarketCapacity(capacity);
        emit Paused(paused);
    }

    // === ERC4626 LOGICS: convertion ===
    function totalAssets() public view returns (uint256) {
        return _convertToAssets(_totalShares, RoudingMode.ROUND_DOWN);
    }

    function availableAssets() public view returns (uint256) {
        uint totalAsset = totalAssets();
        uint balance = IERC20(asset).balanceOf(address(this));
        if(totalAsset > balance) {
            return balance;
        } else {
            return totalAsset;
        }
    }

    function _convertToShares(
        uint256 _amount,
        RoudingMode mode
    ) public view returns (uint256) {
        if (_amount == 0 || _totalShares == 0) {
            return 0;
        }
        uint256 rate = _exchangeRateInternal();
        return Div(_amount * ONE, rate, mode);
    }

    function _convertToAssets(
        uint256 _shares,
        RoudingMode mode
    ) public view returns (uint256) {
        if (_shares == 0 || _totalShares == 0) {
            return 0;
        }
        uint256 rate = _exchangeRateInternal();
        return Div(_shares * rate, ONE, mode);
    }

    function convertToShares(uint256 _amount) public view returns (uint256) {
        return _convertToShares(_amount, RoudingMode.ROUND_DOWN);
    }

    function convertToAssets(uint256 _shares) public view returns (uint256) {
        return _convertToAssets(_shares, RoudingMode.ROUND_DOWN);
    }

    // === ERC4626 LOGICS: limits ===
    function maxDeposit(address) public view returns (uint256) {
        uint256 totalDeposited = totalAssets();
        if (totalDeposited >= marketCapacity) {
            return 0;
        } else {
            return marketCapacity - totalDeposited;
        }
    }

    function maxMint(address) public view returns (uint256) {
        return _convertToShares(maxDeposit(address(0)), RoudingMode.ROUND_DOWN);
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        uint256 _maxAssets = _convertToAssets(
            balanceOf(owner),
            RoudingMode.ROUND_DOWN
        );
        uint256 _availableAssets = availableAssets();
        if (_maxAssets >= _availableAssets) {
            return _availableAssets;
        } else {
            return _maxAssets;
        }
    }

    function maxRedeem(
        address owner
    ) public view returns (uint256 maxShares) {
        uint256 avaliable = availableAssets();
        uint256 _maxShares = _convertToShares(
            avaliable,
            RoudingMode.ROUND_DOWN
        );
        uint256 _maxRedeem = balanceOf(owner);
        if (_maxShares >= _maxRedeem) {
            return _maxRedeem;
        } else {
            return _maxShares;
        }
    }

    // === ERC4626 LOGICS: preview ===
    function previewDeposit(uint256 amount) public view returns (uint256) {
        return _convertToShares(amount, RoudingMode.ROUND_DOWN);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, RoudingMode.ROUND_UP);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, RoudingMode.ROUND_UP);
    }

    function previewRedeem(uint256 shares) public view returns (uint256 assets) {
        return _convertToAssets(shares, RoudingMode.ROUND_DOWN);
    }

    // === ERC4626 LOGICS: actions ===
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(caller, address(this), assets);
        uint256 newBal = IERC20(asset).balanceOf(address(this));
        require(newBal >= bal + assets, "StakedToken: Deposit failed");
        _mint(receiver, shares);
        _totalShares += shares;
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        if (balanceOf(owner) < shares) {
            revert("StakedToken: Insufficient balance");
        }
        _burn(owner, shares);
        _totalShares -= shares;
        IERC20(asset).safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function deposit(uint256 assets, address receiver) public whenNotPaused returns (uint256) {
        require(assets > 0, "Zero deposit");
        require(assets <= maxDeposit(receiver), "Exceeds max deposit");
        uint256 shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public whenNotPaused returns (uint256) {
        require(shares > 0, "Zero mint");
        require(shares <= maxMint(receiver), "Exceeds max mint");
        uint256 assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256) {
        require(assets > 0, "Zero withdraw");
        require(assets <= maxWithdraw(owner), "Exceeds max withdraw");
        uint256 shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public returns (uint256) {
        require(shares > 0, "Zero redeem");
        require(shares <= maxRedeem(owner), "Exceeds max redeem");
        uint256 assets = previewRedeem(shares);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    // === Black list ===
    mapping(address => bool) private _blacklist;

    event BlacklistAdded(address indexed account);
    event BlacklistRemoved(address indexed account);

    function addToBlacklist(address account) public {
        require(msg.sender == owner(), "Only the contract owner can add to the blacklist");
        require(!_blacklist[account], "Account is already blacklisted");
        _blacklist[account] = true;
        emit BlacklistAdded(account);
    }

    function removeFromBlacklist(address account) public {
        require(msg.sender == owner(), "Only the contract owner can remove from the blacklist");
        require(_blacklist[account], "Account is not blacklisted");
        _blacklist[account] = false;
        emit BlacklistRemoved(account);
    }

    function isBlacklisted(address account) public view returns (bool) {
        return _blacklist[account];
    }

    function _update(address from, address to, uint256 value) internal virtual override whenNotPaused {
        require(!_blacklist[from], "Sender is blacklisted");
        require(!_blacklist[to], "Receiver is blacklisted");
        super._update(from, to, value);
    }
    // === GOVERNANCE ===
    // This function can only be called by the multi sig owner in emergency.
    // It is to avoid using proxy contract and in case any assets are stuck in the contract.
    function rescue(address target, uint256 value, bytes calldata data) external onlyOwner {
        (bool success, ) = target.call{value: value}(data);
        require(success, "Rescue: Call failed");
    }

    function RescueTokenToOwner(address token) external onlyOwner {
        if (IERC20(token).balanceOf(address(this)) > 0) {
            IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
        }
    }

    // === HELPER FUNCTIONS ===
    enum RoudingMode {
        ROUND_UP,
        ROUND_DOWN
    }

    function Div(
        uint256 x,
        uint256 y,
        RoudingMode roundUp
    ) internal pure returns (uint256) {
        if (roundUp == RoudingMode.ROUND_UP) {
            return (x + y - 1) / y;
        } else {
            return x / y;
        }
    }
}

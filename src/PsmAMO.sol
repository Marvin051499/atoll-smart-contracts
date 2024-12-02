// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";


contract PsmAMO is Ownable2Step {
    // === SECURITY ===
    using SafeERC20 for IERC20;
    address public manager;
    address public securityManager;
    uint256 public paused; // 0 for not paused, 1 for paused

    constructor() Ownable(msg.sender) {
        paused = 0;
    }

    modifier onlyManager {
        require(msg.sender == manager || msg.sender == owner(), "PSM: Not Manager");
        _;
    }

    modifier onlySecurityManager {
        require(msg.sender == securityManager || msg.sender == manager || msg.sender == owner(), "PSM: Not Security Manager");
        _;
    }

    modifier whenNotPaused {
        require(paused == 0, "PSM: Paused");
        _;
    }

    function configSecurity(address _manager, address _securityManager) external onlyManager {
        manager = _manager;
        securityManager = _securityManager;
        emit SecurityConfigured(_manager, _securityManager);
    }

    function pause() external onlySecurityManager {
        paused = 1;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = 0;
        emit Unpaused();
    }

    // === EVENTS ===
    event Paused();
    event Unpaused();
    event SecurityConfigured(address manager, address securityManager);
    event Deposited(uint256 amountIn, uint256 amountOut);
    event TransferedToReceipt(address receipt, uint256 amountStable); 
    event AddressConfigured(address peg, address stable, address[] AMO, uint256 fee);
    // === TOKEN ===
    address public pegCoin;
    address public stableCoin;
    address[] public receipts;
    uint256 public fee = 2e14; // 0.02%
    uint256 constant ONE_HUNDRED_PERCENT = 1e18;
    uint256 decimalsRate;
    // @audit: one-shot address configuration
    bool _addressConfiged;

    function configAddress(address _peg, address _stable, address[] memory _AMO, uint256 _fee) external onlyOwner {
        // @audit: one-shot address configuration
        require(!_addressConfiged, "Address already configured");
        _addressConfiged = true;
        pegCoin = _peg;
        stableCoin = _stable;
        decimalsRate = 10 ** (18 - ERC20(stableCoin).decimals());
        receipts = new address[](_AMO.length);
        for(uint256 i = 0; i < _AMO.length; i++) {
            receipts[i] = _AMO[i];
        }
        fee = _fee;
        emit AddressConfigured(_peg, _stable, _AMO, _fee);
    }

    function setFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    function setReceipts(address[] memory _receipts) external onlyOwner {
        receipts = _receipts;
    }

    // === CONVERTIONS & TRANSFERS ===
    function mint(uint256 amount, address to) external whenNotPaused {
        IERC20 pegERC20 = IERC20(pegCoin); // cache storage reads
        IERC20 stableERC20 = IERC20(stableCoin);
        uint256 balBefore = stableERC20.balanceOf(address(this));
        IERC20(stableCoin).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balChange = stableERC20.balanceOf(address(this)) - balBefore;// double check balance
        require(balChange == amount, "mint amount failed");
        // we transfer pegCoin to `to`. 
        // This has roundings issues. All rounding errors are in the favor of the protocol
        uint256 outAmount = decimalsRate * amount * (ONE_HUNDRED_PERCENT - fee) / ONE_HUNDRED_PERCENT;
        require(pegERC20.balanceOf(address(this)) >= outAmount, "No enough pegCoin");
        pegERC20.safeTransfer(to, outAmount);
        emit Deposited(amount, outAmount);
    }

    function sendToAMO(uint256 amount, uint256 amoIdx) external onlyManager {
        require(amoIdx < receipts.length, "Invalid AMO index");
        address receipt = receipts[amoIdx];
        IERC20 stableERC20 = IERC20(stableCoin);
        require(stableERC20.balanceOf(address(this)) >= amount, "No enough stableCoin");
        stableERC20.safeTransfer(receipt, amount);
        emit TransferedToReceipt(receipt, amount);
    }

    // === GOVERNANCE & EMERGENCY ===

    function RescueTokenToOwner(address token) external onlyOwner {
        _transferTokenToOwner(token);
    }

    function _transferTokenToOwner(address token) internal {
        uint bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(owner(), bal);
        }
    }

    function withdrawStableCoins() external onlyManager {
        _transferTokenToOwner(stableCoin);
    }

    function withdrawPegCoins() external onlyManager {
        _transferTokenToOwner(pegCoin);
    }

    // This function can only be called by the multi sig owner in emergency.
    // It is to avoid using proxy contract and in case any assets are stuck in the contract.
    function rescue(address target, uint256 value, bytes calldata data) external onlyOwner {
        (bool success, ) = target.call{value: value}(data);
        require(success, "Rescue: Call failed");
    }
}
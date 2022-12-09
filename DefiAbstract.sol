//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./IUniswapV2Router02.sol";
import "./ISaleRound.sol";
import "./IERC20Burn.sol";
import "./ReferralSystem.sol";

abstract contract AbstractSale is 
    ReferralSystem, 
    Pausable, 
    AccessControl,
    ISaleRound
{
    using SafeERC20 for IERC20;

    error UnknownAddress();
    error InvalidParams();

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public precision = 1e18;
    address public adapter;

    uint256 private immutable _maxContribution;
    uint256 private immutable _minContribution;
    uint256 private immutable _pricePerToken; 

    uint256 private _totalAmount;
    uint256 private _percentDistributedImmediately;
    address private _MGBAddress;
    uint256 private _distributedAmount;
    uint256 private _vestingDuration;
    uint256 internal _receiveMATIC;
    uint256 internal _receiveUSD;
    uint256 private _soldAmount;
    uint256 private _burnAmount;
    uint256 private _periodDuration;
    uint256 private _tokenGenerationEvent;
    address internal _stablecoin;

    mapping(address => bool) private _availableCurrency;
    mapping(address => UserData) private _userData;

    /**
     *@param amount the total number of tokens to be distributed
     *@param tokenAddr address MGB
     *@param vesting how long will all tokens be distributed. Specify in months
     *@param percentDistributedImmediately the percentage of the total amount that will be immediately available for receipt
     *@param pricePerToken the percentage of the total amount that will be immediately available for receipt
     *@param availableCurrencies the stable coins will be available for the purchasing MGB
     *@param adapterAddr address Uniswap adapter
     *@param contribuitionLimits minimum and maximum deposit for a buy
     *@param periodDuration duration of the period of the selling MGB 
     *@param tokenGenerationEvent timestamp after which rewards will be calculated
     *@param percentReward the percents for the referral system
     */
    constructor(
        uint256 amount,
        address tokenAddr,
        uint256 vesting,
        uint256 percentDistributedImmediately,
        uint256 pricePerToken,
        address[] memory availableCurrencies,
        address adapterAddr,
        uint256[] memory contribuitionLimits,
        uint256 periodDuration,
        uint256 tokenGenerationEvent,
        uint256[] memory percentReward
    ) {
        if(
            percentDistributedImmediately > 100 ||
            contribuitionLimits[0] > contribuitionLimits[1] ||
            block.timestamp > tokenGenerationEvent ||
            _sum(percentReward) > 100 ||
            availableCurrencies.length == 0
        ) {
            revert InvalidParams();
        }

        _totalAmount = amount;
        _percentDistributedImmediately = percentDistributedImmediately;
        _MGBAddress = tokenAddr;
        _vestingDuration = vesting;
        _pricePerToken = pricePerToken;
        _periodDuration = periodDuration;
        _tokenGenerationEvent = tokenGenerationEvent;

        for(uint i; i < availableCurrencies.length;) {
            address currency = availableCurrencies[i];
            _availableCurrency[currency] = true;

            unchecked {
                i++;
            }
        }

        _maxContribution = contribuitionLimits[1];
        _minContribution = contribuitionLimits[0];

        adapter = adapterAddr;
        _stablecoin = availableCurrencies[0];

        _setSystemParameters(percentReward);

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(ADMIN_ROLE, msg.sender);
    }

    modifier isAvailableCurrency(address usdAddr) {
        if(!_availableCurrency[usdAddr]) {
            revert UnknownAddress();
        }
        _;
    }

    modifier isFinish() {
        if (_burnAmount > 0) {
            revert Finish();
        }
        _;
    }

    function setWhiteList(address[] memory account, bool[] memory status) 
        external
        onlyRole(ADMIN_ROLE)
    {
        _setWhiteList(account, status);
    }

    /**
     * See {ReferralSystem-_setSystemParameters}
     */
    function setPercentParameters(uint256[] memory percentReward)
        external
        onlyRole(ADMIN_ROLE)
    {
        _setSystemParameters(percentReward);
        emit PercentRewards(percentReward);
    }

    /**
     * @dev See {ISaleRound-setAvailableCurrency}
     */
    function setAvailableCurrency(address token) external onlyRole(ADMIN_ROLE) {
        _availableCurrency[token] = true;
        emit AvailableCurrency(token);
    }

    /**
     * @dev See {ISaleRound-buyMGB}.
     */
    function setStablecoin(address coin) external onlyRole(ADMIN_ROLE) {
        _stablecoin = coin;
        emit Stablecoin(coin);
    }

    /**
     * @dev See {ISaleRound-setPrecision}.
     */
    function setPrecision(uint256 newPrecision) external onlyRole(ADMIN_ROLE) {
        precision = newPrecision;
        emit Precision(newPrecision);
    }

    /**
     * @dev See {ISaleRound-setTGE}.
     */
    function setTGE(uint256 newTGE) external onlyRole(ADMIN_ROLE) {
        _tokenGenerationEvent = newTGE;
        emit TGE(newTGE);
    }

    /**
     * @dev See {ISaleRound-buyMGB}.
     */
    function _buyMGB(
        uint256 usdAmount,
        address usdAddr
    ) 
        internal
        returns 
    (
        uint256 amountMGB
    ) {
        uint256 factor = IERC20Metadata(_MGBAddress).decimals() - IERC20Metadata(usdAddr).decimals();

        amountMGB = swap(usdAmount, factor);
        _soldAmount += amountMGB;

        if (_soldAmount > _totalAmount) {
            revert ExceedingMaxSold();
        }

        UserData storage userData = _userData[msg.sender];
        userData.buyAmount += amountMGB;
    }

    /**
     * @dev See {ISaleRound-claim}.
     */
    function claim() external {
        uint256 availableAmount = _calcAvailableAmount(msg.sender);
        if (availableAmount == 0) revert ZeroAmount();

        UserData storage userData = _userData[msg.sender];
        userData.claimAmount += availableAmount;
        _distributedAmount += availableAmount;

        IERC20(_MGBAddress).safeTransfer(msg.sender, availableAmount);

        emit Claim(msg.sender, availableAmount);
    }

    /**
     * @dev See {ISaleRound-withdrawToken}.
     */
    function withdrawToken(address tokenAddr, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
    {
        IERC20(tokenAddr).safeTransfer(msg.sender, amount);
    }

    /**
     * @dev See {ISaleRound-withdraw}.
     */
    function withdraw(uint256 amount) external onlyRole(ADMIN_ROLE) {
        msg.sender.call{value: amount}("");
    }

    /**
     * @dev Burn unsold MGBs
     */
    function burnUnsoldToken() external onlyRole(ADMIN_ROLE) whenPaused {
        _burnAmount = _totalAmount - _soldAmount;
        IERC20Burn(_MGBAddress).burn(address(this), _burnAmount);
    }

    /**
     * @dev See {ISaleRound-getAvaiableAmount}.
     */
    function getAvailableAmount(
        address account
    ) external view returns (uint256) {
        return (_calcAvailableAmount(account));
    }

    /**
     * @dev See {ISaleRound-getPrice}.
     */
    function getPrice(uint256 amount) external view returns (uint256, uint8) {
        return (_getPrice(amount));
    }

    /**
     * @dev See {ISaleRound-getInfo}.
     */
    function getInfo() external view returns (SaleInfo memory) {
        return
            SaleInfo(
                _MGBAddress,
                _totalAmount,
                _percentDistributedImmediately,
                _distributedAmount,
                _vestingDuration,
                _tokenGenerationEvent,
                _pricePerToken,
                _maxContribution,
                _minContribution,
                _soldAmount,
                _burnAmount
            );
    }

    /**
     * @dev See {ISaleRound-getInfoTokens}.
     */
    function getInfoTokens() external view returns (uint256, uint256) {
        return (_receiveMATIC, _receiveUSD);
    }

    /**
     * @dev See {ISaleRound-getCurrencyStatus}.
     */
    function getCurrencyStatus(address currency) external view returns (bool) {
        return _availableCurrency[currency];
    }

    /**
     * @dev See {ISaleRound-getUserData}.
     */
    function getUserData(address user) external view returns (UserData memory) {
        return _userData[user];
    }

    /**
     * @dev Check that usdAmount within the normal range
     */
    function _validateUsdAmount(uint256 usdAmount, uint8 decimals) internal view {
        if (
            usdAmount > _maxContribution * 10**decimals || 
            usdAmount < _minContribution * 10**decimals
        ) {
            revert MinMaxContribution();
        }
    }

    /**
     * @dev Sets referrer for msg.sender if he has no one
     * and gives to sender opportunity to invite other users
     */
    function _setReferrals(
        address referrer
    ) internal {
        if (!_whiteList[msg.sender]) {
            _whiteList[msg.sender] = true;
        }

        if (
            _referralList[msg.sender] == address(0)
        ) {
            _referralList[msg.sender] = referrer;
        }
    }

    /**
     * @dev See {ISaleRound-swap}.
     */
    function swap(uint256 usdAmount, uint256 factor) public view returns (uint256 MGBamount) {
        return (usdAmount * (10 ** factor) * precision) / _pricePerToken;
    }

        /**
     * @dev See {ISaleRound-stopSale}.
     */
    function stopSale() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev See {ISaleRound-resumeSale}.
     */
    function resumeSale() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Calculate available amount of MGB for particular account
     * @param account Address of the account to calculate amount of MGB
     */
    function _calcAvailableAmount(address account)
        internal
        view
        returns (uint256 availableAmount)
    {   
        if(block.timestamp > _tokenGenerationEvent) {
            uint256 month = (block.timestamp - _tokenGenerationEvent) / _periodDuration;

            if (month > _vestingDuration) {
                month = _vestingDuration;
            }

            uint256 distrAmount = (_userData[account].buyAmount *
                _percentDistributedImmediately) / 100;
            
            availableAmount =
                distrAmount +
                ((_userData[account].buyAmount - distrAmount) / _vestingDuration) *
                month -
                _userData[account].claimAmount;

        }
    }

    /**
     * @dev Get USD amount
     * @param amount deposited for exchange
     */
    function _getPrice(uint256 amount) internal view returns (uint256, uint8) {
        address weth = IUniswapV2Router02(adapter).WETH();
        uint8 decimals = IERC20Metadata(_stablecoin).decimals();

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = _stablecoin;

        uint256[] memory amountOut = IUniswapV2Router02(adapter).getAmountsOut(
            amount,
            path
        );

        return (amountOut[1], decimals);
    }

    /**
     * @dev Calculates the sum of an array
     */
    function _sum(uint256[] memory values) internal pure returns(uint256) {
        uint256 s;

        for(uint256 i; i < values.length;) {
            s += values[i];

            unchecked {
                i++;
            }
        }

        return s;
    }
}
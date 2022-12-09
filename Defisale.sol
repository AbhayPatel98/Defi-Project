//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "./AbstractSaleRound.sol";


contract PrivateSale is AbstractSale {
    using SafeERC20 for IERC20;

    /**
     * @dev See {AbstractSale-constructor}
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
    ) AbstractSale(
        amount,
        tokenAddr,
        vesting,
        percentDistributedImmediately,
        pricePerToken,
        availableCurrencies,
        adapterAddr,
        contribuitionLimits,
        periodDuration,
        tokenGenerationEvent,
        percentReward
    ) Pausable() {}

    /**
     * @dev See {ISaleRound-buyMGB}.
     */
    function buyMGB(address referrer)
        external
        payable
        isWhiteList(msg.sender, referrer)
        isFinish
        whenNotPaused   
    {
        uint256 amountMATIC = msg.value;
        (uint256 amountUSD, uint8 decimals) = _getPrice(amountMATIC);

        _validateUsdAmount(amountUSD, decimals);
        _setReferrals(referrer);

        uint256 feeToReferrals = _distributeTheFee(msg.sender, amountMATIC, address(0));

        uint256 amountMGB = _buyMGB(amountUSD, _stablecoin);

        _receiveMATIC += amountMATIC;

        emit BuyMGBOfMATIC(
            msg.sender,
            amountMGB,
            amountMATIC,
            amountUSD,
            _stablecoin,
            feeToReferrals
        );
    }

    /**
     * @dev See {ISaleRound-buyMGB}.
     */
    function buyMGB(
        address usdAddr,
        uint256 usdAmount,
        address referrer
    ) 
        external
        isWhiteList(msg.sender, referrer)
        isAvailableCurrency(usdAddr) 
        isFinish
        whenNotPaused
    {
        uint8 decimals = IERC20Metadata(usdAddr).decimals();

        _validateUsdAmount(usdAmount, decimals);
        _setReferrals(referrer);

        IERC20(usdAddr).safeTransferFrom(
            msg.sender,
            address(this),
            usdAmount
        );

        uint256 feeToReferrals = _distributeTheFee(msg.sender, usdAmount, usdAddr);

        uint256 amountMGB = _buyMGB(usdAmount, usdAddr);
        
        _receiveUSD += usdAmount;

        emit BuyMGBOfUSD(
            msg.sender,
            amountMGB,
            usdAmount,
            usdAddr,
            feeToReferrals
        );
    }
}
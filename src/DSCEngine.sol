//SPDX-Licence-Identifier: MIT

pragma solidity 0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Predator
 * The system is desinged to be minimal as possible? and have the tokens maintain 1 token == 1$ (pegged to USD)
 * This stablecoin has property:
 * Exogenous Collateral: ETH & BTC
 * Dollar pegged
 * Algorithmic
 *
 * It's similar to DAI, if DAI had no governance, no fees, and was onl backed by wETH and wBTC.
 *
 * Our Dsc system should always be "overcollaterized". At no point, should the value of all collateral <= the $ backed of all the DSC.
 *
 *
 *
 * // threshold 150%
 *     // $100 ETH -> $75 ETH
 *     // $50 DSC
 *     // Undercollateralized!!!
 *
 *     // Client pays 50 DSC -> get all collaterized
 *     // $74 ETH
 *     //-50 DSC
 *     // $24 ETH
 *
 *     //if smn pays back your minted DSC, they can have all your collateral for a discount
 *
 *
 * @notice This contract is the governance contract for the Decentralized Stable Coin, the core of DSC system. It handles all logic for mining and redeeming DSC, and as well as depositing and withdrawing collateral
 * @notice This contract is Very loosely based on MakerDAO's DSChief contract. It is a simplified version of it, with only the core logic needed for the DSC system.
 *
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////////////////
    //////   ERRORS   //////////
    ////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotSupported();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////////////
    ///   STATE VARIABLES    ///
    ////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant COLLATERAL_THRESHOLD = 50; // 200% overcollaterised
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////
    ////////   EVENTS    ///////
    ////////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///////////////////////////
    /////  MODIFIERS    ///////
    ///////////////////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isTokenSupported(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotSupported();
        }
        _;
    }

    ////////////////////////////
    //////   FUNCTIONS   ///////
    ////////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD PriceFeed, ETH/USD, BTC/USD etc.
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    //   EXTERNAL FUNCTIONS   //
    ////////////////////////////

    /**
     *
     * @param tokenCollateralAddress The address of the collateral token.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of DSC to mint.
     * @notice this function will deposit your collateral and mint Dsc in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI pattern (check, effects, interact).
     * @param tokenCollateralAddress The address of the collateral token.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isTokenSupported(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice follows CEI pattern (check, effects, interact).
     * @param tokenCollateralForDsc The address of the collateral token.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC to burn.
     * @notice this function will redeem your collateral and burn Dsc in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralForDsc, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralForDsc, amountCollateral);
        // redeemCollateral already check for not success
    }

    // in order to redeem collateral:
    // 1. Health factor must be over 1 AFTER collateral is redeemed
    // DRY: Don't repeat yourself
    // CEI: Check, Effects, Interact
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI pattern (check, effects, interact).
     * @param amountDscMint The amount of DSC to mint.
     * @notice they have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscMint) public moreThanZero(amountDscMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscMint;
        // if they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // Do we need to check if it breaks health factor?
    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // likely this will never hit
    }

    // If we do start nearing undercollaterization, we need the user's collateral positions to liquidate

    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <- DSC isn't worth $1!!!

    // $75 backing $50 DSC
    // Liquidator takes $75 backing and burns off the $50 DSC

    // if smn is almost undercollaterized, we will pay you to liquidate them
    /**
     *
     * @param collateral  The address of the collateral token to liquidate.
     * @param user  The address of the user to liquidate. The user broke his health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover  The amount of DSC to cover, the amount of DSC the user has minted. The amount you want to improve the users health factor by.
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollaterized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collaterized, then we wouldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check health factor
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        //we want to burn their DSC "debt"
        // and take their collateral
        // Bad user: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC == ??? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // and  give them a 10% bonus for beign a bad user
        // so we are giving the liquidator $110 of WETH for 100 DSC
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amount into a treasury

        // 0.05 ETH * 0.1 = 0.005 ETH. Getting 0.05 + 0.005 = 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralRedeem, user, msg.sender);
        // we need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthfactor = _healthFactor(user);
        if (endingUserHealthfactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ///////////////////////////////////////
    // PRIVATE & INTERNAL VIEW FUNCTIONS //
    ///////////////////////////////////////

    /**
     * @param amountDscToBurn The amount of DSC to burn.
     * @param onBehalfOf The address of the user to burn the DSC for.
     * @param dscFrom The address of the user to burn the DSC from.
     * @notice Burns DSC from a user's account.
     * @dev Low-level internal function , do not call unless the function calling it is checking for health factor beign broken.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        // 100 - 1000 (revert)
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorrAfter();
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation the user is.
     * If user goes below 1, then they can get liquidated.
     * @param user The address of the user to check the health factor of.
     */
    function _healthFactor(address user) private view returns (uint256) {
        // 1. get the value of all collateral
        // 2. get the value of all DSC minted
        // 3. return the ratio of collateral value to DSC value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * COLLATERAL_THRESHOLD) / LIQUIDATION_PRECISION;

        // $1000 eth * 50 = 50000 / 100 = 500
        // $150 eth / 100 dsc = 1.5
        // $150 eth * 50 = 7500 / 100 = (75 / 100) < 1

        // $1000 eth / 100 dsc = 10
        // 1000 * 50 = 50000 / 100 = (500 / 100) > 1

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * 1. check health factor (do they have enough collateral value)
     * 2. Revert if they don't
     * @param user The address of the user to check the health factor of.
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    // PUBLIC & INTERNAL VIEW FUNCTIONS ///
    ///////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price in ETH (token)
        // $/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10) = 0.5e18
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited and map it to the price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1eth = $1000
        // the returned value from the price feed is in 8 decimals, 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000 * 1e8 * (1e10)) * 1000 * 1e18
    }
}

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

    ////////////////////////////
    ///   STATE VARIABLES    ///
    ////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRESISION = 1e10;
    uint256 private constant PRESISION = 1e18;
    uint256 private constant COLLATERAL_THRESHOLD = 50; // 200% overcollaterised
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////
    ////////   EVENTS    ///////
    ////////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

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
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // 100 - 1000 (revert)
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorrAfter();
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI pattern (check, effects, interact).
     * @param amountDscMint The amount of DSC to mint.
     * @notice they have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscMint) public moreThanZero(amountDscMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // Do we need to check if it breaks health factor?
    function burnDsc(uint256 amountDscToBurn) external moreThanZero(amountDscToBurn) {
        s_dscMinted[msg.sender] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
        _revertIfHealthFactorIsBroken(msg.sender); // likely this will never hit
    }

    function liquidate() external {}

    function getHealthFactor() external view {}

    ///////////////////////////////////////
    // PRIVATE & INTERNAL VIEW FUNCTIONS //
    ///////////////////////////////////////
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

        return (collateralAdjustedForThreshold * PRESISION) / totalDscMinted;
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
        return ((uint256(price) * ADDITIONAL_FEED_PRESISION) * amount) / PRESISION; // (1000 * 1e8 * (1e10)) * 1000 * 1e18
    }
}

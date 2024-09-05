//SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    error DSCEngine__TransfeFailed();

    ////////////////////////////
    ///   STATE VARIABLES    ///
    ////////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////
    ////////   EVENTS    ///////
    ////////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    //   EXTERNAL FUNCTIONS   //
    ////////////////////////////
    function depositCollateralAndMintDsc() external {}

    /**
     * @notice follows CEI pattern (check, effects, interact).
     * @param tokenCollateralAddress The address of the collateral token.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isTokenSupported(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransfeFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}

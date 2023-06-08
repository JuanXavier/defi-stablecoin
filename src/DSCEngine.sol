// SPDX-License-Identifier:MIT
pragma solidity 0.8.19;

import { OracleLib, AggregatorV3Interface } from "./libraries/OracleLib.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DecentralizedStableCoin } from "./DecentralizedStableCoin.sol";

/**
 * @title DSCEngine
 * @author Juan Xavier Valverde M.
 *
 * The system is deisgned to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exegenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 * TODO  We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

 */

contract DSCEngine is ReentrancyGuard {
    /* ---------------------- LIBRARIES --------------------- */
    using OracleLib for AggregatorV3Interface;

    /* ----------------------- ERRORS ----------------------- */
    error DSCEngine__ArrayLengthMismatch();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /* ----------------------- EVENTS ----------------------- */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed token, uint256 indexed amountCollateral, address from, address to); // if from != to, then it was liquidated

    /* ---------------------- VARIABLES --------------------- */
    DecentralizedStableCoin private immutable DSC;

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant LIQUIDATION_PRECISION = 100;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant FEED_PRECISION = 1e8;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    address[] private collateralTokens;
    mapping(address user => uint256 amount) private DSCMinted;
    mapping(address collateralToken => address priceFeed) private priceFeeds;
    mapping(address user => mapping(address collateralToken => uint256 amount)) private collateralDeposited;

    /* ****************************************************** */
    /*                        VERIFIERS                       */
    /* ****************************************************** */

    function _moreThanZero(uint256 amount) internal pure {
        if (amount == 0) revert DSCEngine__NeedsMoreThanZero();
    }

    function _isAllowedToken(address token) internal view {
        if (priceFeeds[token] == address(0)) revert DSCEngine__TokenNotAllowed(token);
    }

    function _checkHealthFactor(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }

    /* ****************************************************** */
    /*                       CONSTRUCTOR                      */
    /* ****************************************************** */

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__ArrayLengthMismatch();
        }

        // These feeds will be the USD pairs
        unchecked {
            for (uint256 i; i < tokenAddresses.length; ++i) {
                priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
                collateralTokens.push(tokenAddresses[i]);
            }
        }
        DSC = DecentralizedStableCoin(dscAddress);
    }

    /* ****************************************************** */
    /*                       COLLATERAL                       */
    /* ****************************************************** */

    /**
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public nonReentrant {
        _moreThanZero(amountCollateral);
        if (priceFeeds[tokenCollateralAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed(tokenCollateralAddress);
        }
        collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToBurn: The amount of DSC you want to burn
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external nonReentrant {
        _moreThanZero(amountCollateral);
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _checkHealthFactor(msg.sender); // redeem collateral already checks health factor
    }

    /**
     * @notice This function will redeem your collateral.
     * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) external nonReentrant {
        _moreThanZero(amountCollateral);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _checkHealthFactor(msg.sender);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
        emit CollateralRedeemed(tokenCollateralAddress, amountCollateral, from, to);
    }

    /* ****************************************************** */
    /*                       LIQUIDATION                      */
    /* ****************************************************** */

    /**
     * @param collateralAddress: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     * @notice You can partially liquidate a user.
     * @notice You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol was only 100% or less collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateralAddress, address user, uint256 debtToCover) external nonReentrant {
        _moreThanZero(debtToCover);

        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) revert DSCEngine__HealthFactorOk();

        uint256 debtToCoverInTokens = getTokenAmountFromUsd(collateralAddress, debtToCover);
        uint256 bonusCollateral = (debtToCoverInTokens * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // 10%
        uint256 totalCollateralToRedeem = debtToCoverInTokens + bonusCollateral;

        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(user, msg.sender, collateralAddress, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) revert DSCEngine__HealthFactorNotImproved();
        _checkHealthFactor(msg.sender);
    }

    /* ****************************************************** */
    /*                    MINTING / BURNING                   */
    /* ****************************************************** */

    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you hav enough collateral
     */
    function mintDsc(uint256 amountDscToMint) public nonReentrant {
        _moreThanZero(amountDscToMint);
        DSCMinted[msg.sender] += amountDscToMint;

        // todo before or afteer  minting
        _checkHealthFactor(msg.sender);
        bool minted = DSC.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    /*
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * you DSC but keep your collateral in.
     */
    function burnDsc(uint256 amount) external {
        _moreThanZero(amount);
        _burnDsc(amount, msg.sender, msg.sender);
        _checkHealthFactor(msg.sender);
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = DSC.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) revert DSCEngine__TransferFailed();
        DSC.burn(amountDscToBurn);
        _checkHealthFactor(msg.sender); // fixme
    }

    /* ****************************************************** */
    /*                      HEALTH FACTOR                     */
    /* ****************************************************** */

    function _getAccountInformation(
        address user
    ) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        // this is becasue if someone deposits tons of collateral but no dsc minted, their health factor will divide by zero
        if (totalDscMinted == 0) return type(uint256).max;

        // always half the collateral, unless 0 and 1 where output is 0
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((collateralAdjustedForThreshold * PRECISION) / totalDscMinted);
    }

    /* ****************************************************** */
    /*                          VIEW                          */
    /* ****************************************************** */

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        address token;
        uint256 amount;
        for (uint256 i; i < collateralTokens.length; ++i) {
            token = collateralTokens[i];
            amount = collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /// @dev This function converts an amount of USD (in wei) to an amount of a specified token
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountInformation(
        address user
    ) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        return _getAccountInformation(user);
    }

    function getUsdValue(address token, uint256 amountInWei) external view returns (uint256) {
        return _getUsdValue(token, amountInWei);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(DSC);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /* ****************************************************** */
    /*                          PURE                          */
    /* ****************************************************** */

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }
}

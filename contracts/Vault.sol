pragma solidity ^0.4.11;

import "./dependencies/ERC20.sol";
import {ERC20 as Shares} from "./dependencies/ERC20.sol";
import "./assets/AssetInterface.sol";
import "./dependencies/DBC.sol";
import "./dependencies/Owned.sol";
import "./dependencies/SafeMath.sol";
import "./dependencies/Logger.sol";
import "./participation/ParticipationAdaptor.sol";
import "./datafeeds/PriceFeedAdaptor.sol";
import "./riskmgmt/RiskMgmtAdaptor.sol";
import "./exchange/ExchangeAdaptor.sol";
import "./Calculate.sol";
import "./VaultInterface.sol";

/// @title Vault Contract
/// @author Melonport AG <team@melonport.com>
/// @notice Simple vault
contract Vault is DBC, Owned, Shares, VaultInterface {
    using SafeMath for uint256;

    // TYPES

    struct Prospectus { // Can be changed by Owner
      bool subscriptionAllowed;
      uint256 subscriptionFee; // Minimum threshold
      bool redeemalAllow;
      uint256 withdrawalFee;
    }

    struct Modules { // Can't be changed by Owner
        ParticipationAdaptor participation;
        PriceFeedAdaptor pricefeed;
        ExchangeAdaptor exchange;
        RiskMgmtAdaptor riskmgmt;
    }

    struct Calculations {
        uint256 gav;
        uint256 managementReward;
        uint256 performanceReward;
        uint256 unclaimedRewards;
        uint256 nav;
        uint256 sharePrice;
        uint256 totalSupply;
        uint256 timestamp;
    }

    // FIELDS

    // Constant asset specific fields
    uint public MANAGEMENT_REWARD_RATE = 0; // Reward rate in referenceAsset per delta improvment
    uint public PERFORMANCE_REWARD_RATE = 0; // Reward rate in referenceAsset per managed seconds
    uint public constant DIVISOR_FEE = 10 ** 15; // Reward are divided by this number
    uint256 public constant SUBSCRIBE_THRESHOLD = 1000;
    uint256 public constant SUBSCRIBE_FEE_DIVISOR = 100000; // << 10 ** decimals
    // Fields that are only changed in constructor
    string public name;
    string public symbol;
    uint public decimals;
    uint256 public baseUnitsPerShare; // One unit of share equals 10 ** decimals of base unit of shares
    address public melonAsset; // Adresss of Melon asset contract
    address public referenceAsset; // Performance measured against value of this asset
    // Fields that can be changed by functions
    Prospectus public prospectus;
    Modules public module;
    Calculations public atLastPayout;
    Logger public logger;
    uint256[] public allHoldings;
    uint256[] public allPrices;
    uint256[] public allDecimals;

    // EVENTS

    // PRE, POST, INVARIANT CONDITIONS

    function isZero(uint256 x) internal returns (bool) { return 0 == x; }
    function isPastZero(uint256 x) internal returns (bool) { return 0 < x; }
    function balancesOfHolderAtLeast(address ofHolder, uint256 x) internal returns (bool) { return balances[ofHolder] >= x; }
    function atLeastThreshold(uint256 x) internal returns (bool) { return x >= SUBSCRIBE_THRESHOLD; }

    // CONSTANT METHODS

    function getPriceFeedAddress() constant returns (address) { return module.pricefeed; }
    function getExchangeAddress() constant returns (address) { return module.exchange; }
    function getDecimals() constant returns (uint) { return decimals; }
    function getBaseUnitsPerShare() constant returns (uint) { return baseUnitsPerShare; }

    // NON-CONSTANT METHODS

    function Vault(
        address ofManager,
        string withName,
        string withSymbol,
        uint withDecimals,
        address ofMelonAsset,
        address ofPriceFeed,
        address ofParticipation,
        address ofExchange,
        address ofRiskMgmt,
        address ofLogger
    ) {
        logger = Logger(ofLogger);
        logger.addPermission(this);
        owner = ofManager;
        name = withName;
        symbol = withSymbol;
        decimals = withDecimals;
        melonAsset = ofMelonAsset;
        baseUnitsPerShare = 10 ** decimals;
        atLastPayout = Calculations({
            gav: 0,
            managementReward: 0,
            performanceReward: 0,
            unclaimedRewards: 0,
            nav: 0,
            sharePrice: baseUnitsPerShare,
            totalSupply: totalSupply,
            timestamp: now
        });
        // Init module struct
        module.pricefeed = PriceFeedAdaptor(ofPriceFeed);
        require(melonAsset == module.pricefeed.getQuoteAsset());
        module.participation = ParticipationAdaptor(ofParticipation);
        module.exchange = ExchangeAdaptor(ofExchange);
        module.riskmgmt = RiskMgmtAdaptor(ofRiskMgmt);
    }

    // TODO: integrate this further (e.g. is it only called in one place?)
    function fetchPricefeedData ()
    {
        /* Rem 1:
         *  All prices are relative to the melonAsset price. The melonAsset must be
         *  equal to quoteAsset of corresponding PriceFeed.
         * Rem 2:
         *  For this version, the melonAsset is set as EtherToken.
         *  The price of the EtherToken relative to Ether is defined to always be equal to one.
         * Rem 3:
         *  price input unit: [Wei / ( Asset * 10**decimals )] == Base unit amount of melonAsset per base unit of asset
         *  vaultHoldings input unit: [Asset * 10**decimals] == Base unit amount of asset this vault holds
         *    ==> vaultHoldings * price == value of asset holdings of this vault relative to melonAsset price.
         *  where 0 <= decimals <= 18 and decimals is a natural number.
         */
        // reset arrays
        delete allHoldings;
        delete allPrices;
        delete allDecimals;
        uint256 numAvailableAssets = module.pricefeed.numAvailableAssets();
        PriceFeedAdaptor Price = PriceFeedAdaptor(address(module.pricefeed));
        for (uint256 i = 0; i < numAvailableAssets; i++) {
            // Holdings
            address ofAsset = address(module.pricefeed.getAssetAt(i));
            AssetInterface Asset = AssetInterface(ofAsset);
            uint256 assetHoldings = Asset.balanceOf(this); // Amount of asset base units this vault holds
            uint256 assetDecimals = Asset.getDecimals();
            // Price
            uint256 assetPrice;
            if (ofAsset == melonAsset) { // See Remark 1
              assetPrice = 10 ** uint(assetDecimals); // See Remark 2
            } else {
              assetPrice = Price.getPrice(ofAsset); // Asset price given quoted to melonAsset (and 'quoteAsset') price
            }
            allHoldings.push(assetHoldings);
            allPrices.push(assetPrice);
            allDecimals.push(assetDecimals);
            logger.logPortfolioContent(assetHoldings, assetPrice, assetDecimals);
        }
    }

    /// Pre: None
    /// Post: Gav, managementReward, performanceReward, unclaimedRewards, nav, sharePrice denominated in [base unit of melonAsset]
    function recalculateAll()
        constant
        returns (uint gav, uint management, uint performance, uint unclaimed, uint nav, uint sharePrice)
    {
        gav = Calculate.grossAssetValue(allHoldings, allPrices, allDecimals);
        (
            management,
            performance,
            unclaimed
        ) = Calculate.rewards(
            atLastPayout.timestamp,
            MANAGEMENT_REWARD_RATE,
            PERFORMANCE_REWARD_RATE,
            gav,
            atLastPayout.sharePrice,
            totalSupply,
            baseUnitsPerShare,
            DIVISOR_FEE
        );
        nav = Calculate.netAssetValue(gav, unclaimed);
        sharePrice = Calculate.pricePerShare(nav, baseUnitsPerShare, totalSupply);
    }


    // NON-CONSTANT METHODS - PARTICIPATION

    // Pre: Fee multiplied by SUBSCRIBE_FEE_DIVISOR
    // Post: New subscription fee is set
    function setSubscriptionFee(uint256 newFee) pre_cond(atLeastThreshold(newFee)) { prospectus.subscriptionFee = newFee; }

    /// Pre: Investor pre-approves spending of vault's reference asset to this contract, denominated in [base unit of melonAsset]
    /// Post: Subscribe in this fund by creating shares
    // TODO check comment
    // TODO mitigate `spam` attack
    /* Rem:
     *  This can be seen as a non-persistent all or nothing limit order, where:
     *  amount == numShares and price == numShares/offeredAmount [Shares / Reference Asset]
     */
    function subscribe(uint256 numShares, uint256 offeredValue)
        pre_cond(module.participation.isSubscriberPermitted(msg.sender, numShares))
        pre_cond(module.participation.isSubscribePermitted(msg.sender, numShares))
    {
        if (isZero(numShares)) {
            subscribeUsingSlice(numShares);
        } else {
            uint256 actualValue = Calculate.subscribePriceForNumShares(numShares, prospectus.subscriptionFee, baseUnitsPerShare, SUBSCRIBE_FEE_DIVISOR, atLastPayout.nav, totalSupply); // [base unit of melonAsset]
            assert(offeredValue >= actualValue); // Sanity Check
            assert(AssetInterface(melonAsset).transferFrom(msg.sender, this, actualValue));  // Transfer value
            createShares(msg.sender, numShares); // Accounting
            logger.logSubscribed(msg.sender, now, numShares);
        }
    }

    /// Pre:  Redeemer has at least `numShares` shares; redeemer approved this contract to handle shares
    /// Post: Redeemer lost `numShares`, and gained `numShares * value` reference tokens
    // TODO mitigate `spam` attack
    function redeem(uint256 numShares, uint256 requestedValue)
        pre_cond(isPastZero(numShares))
        pre_cond(module.participation.isRedeemPermitted(msg.sender, numShares))

    {
        uint256 actualValue = Calculate.priceForNumShares(numShares, baseUnitsPerShare, atLastPayout.nav, totalSupply); // [base unit of melonAsset]
        assert(requestedValue <= actualValue); // Sanity Check
        assert(AssetInterface(melonAsset).transfer(msg.sender, actualValue)); // Transfer value
        annihilateShares(msg.sender, numShares); // Accounting
        logger.logRedeemed(msg.sender, now, numShares);
    }

    /// Pre: Approved spending of all assets with non-empty asset holdings;
    /// Post: Transfer percentage of all assets from Vault to Investor and annihilate numShares of shares.
    /// Note: Independent of running price feed!
    function subscribeUsingSlice(uint256 numShares)
        pre_cond(isPastZero(totalSupply))
        pre_cond(isPastZero(numShares))
    {
        allocateSlice(numShares);
        logger.logSubscribed(msg.sender, now, numShares);
    }

    /// Pre: Recipient owns shares
    /// Post: Transfer percentage of all assets from Vault to Investor and annihilate numShares of shares.
    /// Note: Independent of running price feed!
    function redeemUsingSlice(uint256 numShares)
        pre_cond(balancesOfHolderAtLeast(msg.sender, numShares))
    {
        separateSlice(numShares);
        logger.logRedeemed(msg.sender, now, numShares);
    }

    /// Pre: Allocation: Pre-approve spending for all non empty vaultHoldings of Assets, numShares denominated in [base units ]
    /// Post: Transfer ownership percentage of all assets to/from Vault
    function allocateSlice(uint256 numShares)
        internal
    {
        uint256 numAvailableAssets = module.pricefeed.numAvailableAssets();
        for (uint256 i = 0; i < numAvailableAssets; ++i) {
            AssetInterface Asset = AssetInterface(address(module.pricefeed.getAssetAt(i)));
            uint256 vaultHoldings = Asset.balanceOf(this); // Amount of asset base units this vault holds
            if (vaultHoldings == 0) continue;
            uint256 allocationAmount = vaultHoldings.mul(numShares).div(totalSupply); // ownership percentage of msg.sender
            uint256 senderHoldings = Asset.balanceOf(msg.sender); // Amount of asset sender holds
            require(senderHoldings >= allocationAmount);
            // Transfer allocationAmount of Assets
            assert(Asset.transferFrom(msg.sender, this, allocationAmount)); // Send funds from investor to vault
        }
        // Issue _after_ external calls
        createShares(msg.sender, numShares);
    }

    /// Pre: Allocation: Approve spending for all non empty vaultHoldings of Assets
    /// Post: Transfer ownership percentage of all assets to/from Vault
    function separateSlice(uint256 numShares)
        internal
    {
        // Current Value
        uint256 prevTotalSupply = totalSupply.sub(atLastPayout.unclaimedRewards);
        assert(isPastZero(prevTotalSupply));
        // Destroy _before_ external calls to prevent reentrancy
        annihilateShares(msg.sender, numShares);
        // Transfer separationAmount of Assets
        uint256 numAvailableAssets = module.pricefeed.numAvailableAssets();
        for (uint256 i = 0; i < numAvailableAssets; ++i) {
            AssetInterface Asset = AssetInterface(address(module.pricefeed.getAssetAt(i)));
            uint256 vaultHoldings = Asset.balanceOf(this); // EXTERNAL CALL: Amount of asset base units this vault holds
            if (vaultHoldings == 0) continue;
            uint256 separationAmount = vaultHoldings.mul(numShares).div(prevTotalSupply); // ownership percentage of msg.sender
            // EXTERNAL CALL
            assert(Asset.transfer(msg.sender, separationAmount)); // EXTERNAL CALL: Send funds from vault to investor
        }
    }

    function createShares(address recipient, uint256 numShares)
        internal
    {
        totalSupply = totalSupply.add(numShares);
        addShares(recipient, numShares);
    }

    function annihilateShares(address recipient, uint256 numShares)
        internal
    {
        totalSupply = totalSupply.sub(numShares);
        subShares(recipient, numShares);
    }

    function addShares(address recipient, uint256 numShares) internal {
        balances[recipient] = balances[recipient].add(numShares);
    }

    function subShares(address recipient, uint256 numShares) internal {
        balances[recipient] = balances[recipient].sub(numShares);
    }

    // NON-CONSTANT METHODS - MANAGING

    /// Pre: Sufficient balance and spending has been approved
    /// Post: Make offer on selected Exchange
    function makeOrder(
        uint256 sell_how_much, ERC20 sell_which_token,
        uint256 buy_how_much,  ERC20 buy_which_token
    )
        pre_cond(isOwner())
        pre_cond(module.riskmgmt.isExchangeMakePermitted(address(module.exchange),
            sell_how_much, sell_which_token,
            buy_how_much, buy_which_token)
        )
        returns (uint256 id)
    {
        requireValidAssetData(sell_which_token, buy_which_token);
        approveSpending(sell_which_token, address(module.exchange), sell_how_much);
        id = module.exchange.make(sell_how_much, sell_which_token, buy_how_much, buy_which_token);
    }

    /// Pre: Active offer (id) and valid buy amount on selected Exchange
    /// Post: Take offer on selected Exchange
    function takeOrder(uint256 id, uint256 wantedBuyAmount)
        pre_cond(isOwner())
        returns (bool)
    {
        // Inverse variable terminology! Buying what another person is selling
        var (
            offeredBuyAmount, offeredBuyToken,
            offeredSellAmount, offeredSellToken
        ) = module.exchange.getOrder(id);
        require(wantedBuyAmount <= offeredBuyAmount);
        requireValidAssetData(offeredSellToken, offeredBuyToken);
        var orderOwner = module.exchange.getOwner(id);
        require(module.riskmgmt.isExchangeTakePermitted(address(module.exchange),
            offeredSellAmount, offeredSellToken,
            offeredBuyAmount, offeredBuyToken,
            orderOwner)
        );
        uint256 wantedSellAmount = wantedBuyAmount.mul(offeredSellAmount).div(offeredBuyAmount);
        approveSpending(offeredSellToken, address(module.exchange), wantedSellAmount);
        return module.exchange.take(id, wantedBuyAmount);
    }

    /// Pre: Active offer (id) with owner of this contract on selected Exchange
    /// Post: Cancel offer on selected Exchange
    function cancelOrder(uint256 id)
        pre_cond(isOwner())
        returns (bool)
    {
        return module.exchange.cancel(id);
    }

    /// Pre: Universe has been defined
    /// Post: Whether buying and selling of tokens are allowed at given exchange
    function requireValidAssetData(address sell_which_token, address buy_which_token)
        internal
    {
        // Asset pair defined in Universe and contains melonAsset
        require(module.pricefeed.isValid(buy_which_token));
        require(module.pricefeed.isValid(sell_which_token));
        require(buy_which_token == melonAsset || sell_which_token == melonAsset); // One asset must be melonAsset
        require(buy_which_token != melonAsset || sell_which_token != melonAsset); // Pair must consists of diffrent assets
    }

    /// Pre: To Exchange needs to be approved to spend Tokens on the Managers behalf
    /// Post: Token specific exchange as registered in universe, approved to spend ofToken
    function approveSpending(ERC20 ofToken, address onExchange, uint256 amount)
        internal
    {
        assert(ofToken.approve(onExchange, amount));
        logger.logSpendingApproved(ofToken, onExchange, amount);
    }

    // NON-CONSTANT METHODS - REWARDS
    /// Pre: Only Owner
    /// Post: Unclaimed fees of manager are converted into shares of the Owner of this fund.
    function convertUnclaimedRewards()
        pre_cond(isOwner())
    {
        fetchPricefeedData(); //sync with pricefeed
        var (
            gav,
            managementReward,
            performanceReward,
            unclaimedRewards,
            nav,
            sharePrice
        ) = recalculateAll();
        assert(isPastZero(gav));

        // Accounting: Allocate unclaimedRewards to this fund
        uint256 numShares = totalSupply.mul(unclaimedRewards).div(gav);
        addShares(owner, numShares);
        // Update Calculations
        atLastPayout = Calculations({
          gav: gav,
          managementReward: managementReward,
          performanceReward: performanceReward,
          unclaimedRewards: unclaimedRewards,
          nav: nav,
          sharePrice: sharePrice,
          totalSupply: totalSupply,
          timestamp: now
        });

        logger.logRewardsConverted(now, numShares, unclaimedRewards);
        logger.logCalculationUpdate(now, managementReward, performanceReward, nav, sharePrice, totalSupply);
    }
}

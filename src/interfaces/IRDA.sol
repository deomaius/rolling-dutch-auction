pragma solidity 0.8.13;

interface IRDA {

    struct Auction {
        uint256 windowDuration;     /*  @dev Unix time window duration         */
        uint256 windowTimestamp;    /*  @dev Unix timestamp for window start   */
        uint256 startTimestamp;     /*  @dev Unix auction start timestamp      */ 
        uint256 endTimestamp;       /*  @dev Unix auction end timestamp        */
        uint256 duration;           /*  @dev Unix time auction duration        */
        uint256 proceeds;           /*  @dev Auction proceeds balance          */  
        uint256 reserves;           /*  @dev Auction reserves balance          */
        uint256 price;              /*  @dev Auction origin price              */
    }

    struct Window {
        bytes bidId;        /*  @dev Bid identifier                     */ 
        uint256 expiry;     /*  @dev Unix timestamp window exipration   */
        uint256 price;      /*  @dev Window price                       */
        uint256 volume;     /*  @dev Window volume                      */
        bool processed;     /*  @dev Window fuflfillment state          */
    }

    error InvalidPurchaseVolume();

    error InvalidReserveVolume();

    error InvalidWindowVolume();

    error InvalidWindowPrice();

    error InsufficientReserves();

    error InvalidTokenDecimals();

    error InvalidAuctionDurations();

    error InvalidAuctionPrice();

    error InvalidAuctionTimestamp();

    error InvalidScalarPrice();

    error WindowUnexpired();

    error WindowFulfilled();

    error AuctionExists();

    error AuctionActive();

    error AuctionInactive();

    function createAuction(
     	address operatorAddress,
      	address reserveToken,
      	address purchaseToken,
      	uint256 reserveAmount,
      	uint256 minimumPurchaseAmount,
      	uint256 startingOriginPrice,
      	uint256 startTimestamp,
      	uint256 endTimestamp,
      	uint256 windowDuration
    ) external returns (bytes memory);
        
    function commitBid(bytes calldata auctionId, uint256 price, uint256 volume) external returns (bytes memory);

    function fulfillWindow(bytes calldata auctionId, uint256 windowId) external; 

    function withdraw(bytes calldata auctionId) external;
    
    function redeem(address bidder, bytes calldata auctionId) external;

    event NewAuction(
        bytes indexed auctionId, address reserveToken, uint256 reserves, uint256 price, uint256 endTimestamp
    );

    event Offer(bytes indexed auctionId, address indexed owner, bytes indexed bidId, uint256 expiry);

    event Fulfillment(bytes indexed auctionId, bytes indexed bidId, uint256 windowId);

    event Expiration(bytes indexed auctionId, bytes indexed bidId, uint256 windowId);

    event Claim(bytes indexed auctionId, bytes indexed bidId);

    event Withdraw(bytes indexed auctionId);

}

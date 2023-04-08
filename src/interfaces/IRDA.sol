pragma solidity 0.8.13;

interface IRDA {

    error InvalidPurchaseVolume();

    error InvalidReserveVolume();

    error InvalidWindowVolume();

    error InvalidWindowPrice();

    error InsufficientReserves();

    error InvalidTokenDecimals();

    error InvalidAuctionDurations();

    error InvalidAuctionPrice();

    error InvalidAuctionTimestamps();

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
        
    function commitBid(bytes memory auctionId, uint256 price, uint256 volume) external returns (bytes memory);

    function fulfillWindow(bytes memory auctionId, uint256 windowId) external; 

    function withdraw(bytes memory auctionId) external;
    
    function redeem(address bidder, bytes memory auctionId) external;

    event NewAuction(
        bytes indexed auctionId, address reserveToken, uint256 reserves, uint256 price, uint256 endTimestamp
    );

    event Offer(bytes indexed auctionId, address indexed owner, bytes indexed bidId, uint256 expiry);

    event Fulfillment(bytes indexed auctionId, bytes indexed bidId, uint256 windowId);

    event Expiration(bytes indexed auctionId, bytes indexed bidId, uint256 windowId);

    event Claim(bytes indexed auctionId, bytes indexed bidId);

    event Withdraw(bytes indexed auctionId);

}

pragma solidity 0.8.13;

interface IRDA {

	error InvalidPurchaseVolume();

	error InvalidReserveVolume();

	error InvalidWindowVolume();

	error InvalidWindowPrice();

	error InsufficientReserves();

	error InvalidScalarPrice();

	error WindowUnexpired();

	error WindowFulfilled();

	error AuctionExists();

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

    function withdraw(bytes memory auctionId) external;
    
    function redeem(address bidder, bytes memory auctionId) external;

    event NewAuction(
        bytes indexed auctionId, address reserveToken, uint256 reserves, uint256 price, uint256 endTimestamp
    );

    event Offer(bytes indexed auctionId, address indexed owner, bytes indexed bidId, uint256 expiry);

    event Fufillment(bytes indexed auctionId, bytes indexed bidId, uint256 windowId);

    event Expiration(bytes indexed auctionId, bytes indexed bidId, uint256 windowId);

    event Claim(bytes indexed auctionId, bytes indexed bidId);

    event Withdraw(bytes indexed auctionId);

}

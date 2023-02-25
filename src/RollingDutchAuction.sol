pragma solidity ^0.8.13;

contract RollingDutchAuction { 

    uint256 public auctionIndex;

    mapping (address => mapping (bytes32 => bytes32)) public _claims;
    mapping (bytes32 => mapping (uint256 => Window)) public _window;

    mapping (uint256 => bytes32) public _auctionIds;
    mapping (bytes32 => Auction) public _auctions;
    mapping (bytes32 => uint256) public _windows;
   
    struct Auction {
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 windowDuration
        uint256 duration;
        uint256 reserves;
        uint256 price;
    }

    struct Window {
        uint256 expiry;
        bytes32 bidId; 
        uint256 price;
        uint256 amount;
        bool processed;
    }

    modifier activeAuction(bytes32 memory auctionId) {
        require(remainingTime(auctionId) >  0);
        _;
    }

    modifier inactiveAuction(bytes32 memory uctionId) {
        require(remainingTime(auctionId) == 0);
        _;
    }

    function operatorAddress(bytes32 memory auctionId) return (address owner) { 
        (owner, , , , , , , ) = abi.decode(auctionId);
    }

    function purchaseToken(bytes32 memory auctionId) return (address tokenAddress) { 
        (, , tokenAddress, , , , , ) = abi.decode(auctionId);
    }

    function purchaseToken(bytes32 memory auctionId) return (address tokenAddress) { 
        (, tokenAddress, , , , , , ) = abi.decode(auctionId);
    }

    function claim(address biddingAddress, bytes32 memory auctionId) 
        inactiveAuction(auctionId)
    public {
        bytes32 memory claimHash = _claims[biddingAddress][auctionId];

        _claims[biddingAddress][auctionId] = abi.encodePacked(0, 0));

        (uint256 refundBalance, uint256 claimBalance) = abi.decode(claimHash); 

        if (refundBalance > 0) { 
            IERC20(purchaseToken(auctionId)).transfer(biddingAddress, refundBalance); 
        }
        if (claimBalance > 0 ) { 
            IERC20(reserveToken(auctionId)).transfer(biddingAddress, claimBalance); 
        } 

        emit Claim(auctionId, biddingAddress, claimHash);
    }

    function createAuction(
        address operatorAddress,
        address reserveToken,
        address purchaseToken,
        uint256 reserveAmount,
        uint256 startingPrice,
        uint256 startTimestamp,
        uint256 endTimestamp,
        uint256 windowDuration
    ) public {
        Auction storage auctionState = _auctions[bytes32];

        bytes32 memory auctionId = abi.encodePacked(
            operatorAdress,
            reserveToken,
            purchaseToken,
            reserveAmount,
            startingPrice,
            startTimestamp,
            endTimestamp,
            windowDuration,
            auctionIndex + 1
        );

        require(auctionState.price == 0, "AUCTION EXISTS");

        IERC20(reserveToken).transferFrom(msg.sender, address(this), reserveAmount);

        auctionState.windowDuration = windowDuration;
        auctionState.startTimestamp = startTimestamp;
        auctionState.endTimestamp = endTimestamp;
        auctionState.reserves = reserveAmount;
        auctionState.price = startingPrice;

        _auctionIds[auctionIndex + 1] = auctionId;

        emit NewAuction(auctionId, reserveToken, reserveAmount, startingPrice, endTimestamp);

        auctionIndex += 1; 
    }

    function getScalarPrice(bytes32 memory auctionId) public returns (uint256) {
        uint256 x = _timestamp[auctionId] - block.timestamp;
        uint256 yOriginPrice = _prices[auctionId];
        uint256 xCoeff = x - (x % 1 day) + 1;

        // ln(exp(1/xCoeff))

        return xCoeff * yOriginPrice;
    } 

    function commitBid(bytes32 memory auctionId, uint256 price, uint256 volume) 
        activeAuction(auctionId)
    public payable {
        Window storage currentWindow = _window[auctionId][_windows[auctionId]];

        if (currentWindow.expiry != 0) {
            if (block.timestamp < currentWindow.expiry) {
                require(currentWindow.price < price, "INVALID WINDOW PRICE");
            } else {
                windowExpiration(currentWindow):
            }
        } 

        currentWindow = _window[auctionId][_windows[auctionId]];

        if (currentWindow.price == 0) {
            require(getScalarPrice(auctionId) <= price, "INVALID CURVE PRICE");
        }

        IERC20(purchaseToken(auctionId)).transferFrom(msg.sender, address(this), volume);

        currentWindow.expiry = block.timestamp + auctionState[auctionId].windowDuration;
        currentWindow.bidId = abi.encodePacked(auctionId, msg.sender, price, volume);
        currentWindow.price = price;

        (uint256 refundBalance, uint256 claimBalance) = abi.decode(_claims[msg.sender][auctionId]); 

        _claims[msg.sender][auctionId] = abi.encodePacked(refundBalance + volume, claimBalance);

        emit Offer(auctionId, msg.sender, currentWindow.bidId);
    }

    function windowExpiration(Window memory current) internal {
        (uint256 auctionId, uint256 biddingAddress, uint256 price, uint256 volume) = abi.decode(currentWindow.bidId);

        uint256 auctionRemainingTime = remainingTimeFromWindow(auctionId, current.expiry);
      
        _auctions[auctionId].reserves = _auctions[auctionId].reserves - (volume / price);
        _auctions[auctionId].endTimestamp = block.timestamp + auctionRemainingTime; 
        _auctions[auctionId].price = price;

        fufillWindow(auctionId, _windows[auctionId]);

        _windows[auctionId] = _windows[auctionId] + 1;
    }

    function fufillWindow(bytes32 memory auctionId, uint256 windowId) public {
        Window storage selectWindow = _window[auctionId][windowId];

        require(!fufillmentWindow.processed, "WINDOW ALREADY FUFILLED");

        (, uint256 biddingAddress, uint256 price, uint256 volume) = abi.decode(fulfillmentWindow.bidId);
        (uint256 refundBalance, uint256 claimBalance) = abi.decode(_claims[biddingAddress][auctionId]);

        fufillmentWindow.processed = true;

        _claims[biddingAddress][auctionId] = abi.encodePacked(
            refundBalance - volume, 
            claimBalance + (volume / price
        );
    }

    function remainingTimeFromWindow(bytes32 memory auctionId, uint256 timestamp) public returns (uint256) {
        Auction storage auctionState = _auctions[auctionId];

        uint256 windowStartTimestamp = timestamp - auctionState.windowDuration;
        uint256 auctionElapsedTime = windowStartTimestamp - auctionState.startTimestamp;
        uint256 auctionRemainingTime = auctionState.duration - auctionElapsedTime;

        return auctionRemainingTime;
    }

    function remainingTime(bytes32 memory auctionId) public view returns (uint256) {
        return _auctions[auctionId].endTimestamp - block.timestamp;
    }

    event NewAuction(
        bytes32 memory indexed auctionId, 
        address reserveToken, 
        uint256 reserves
        uint256 price,
        uint256 endTimestamp
    );

    event Offer(
        bytes32 memory indexed auctionId, 
        address indexed owner, 
        bytes32 memory bidId, 
        uint256 expiry
    );

    event Claim(
        bytes32 indexed auctionId, 
        address indexed owner, 
        bytes32 memory bidId
    );

}
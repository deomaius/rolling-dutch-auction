pragma solidity ^0.8.13;

import IERC20 from "interfaces/IERC20.sol";

import { UD60x18, exp, ln } from "@prb/math/UD60x18.sol";

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
        uint256 windowDuration;
        uint256 windowTimestamp;
        uint256 duration;
        uint256 proceeds;
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
        require(remainingWindowTime(auctionId) > 0 || remainingTime(auctionId) > 0);
        _;
    }

    modifier inactiveAuction(bytes32 memory uctionId) {
        require(remainingWindowTime(auctionId) == 0 && remainingTime(auctionId) == 0);
        _;
    }

    function operatorAddress(bytes32 memory auctionId) return (address owner) { 
        (owner, , , , , , , , ,) = abi.decode(auctionId);
    }

    function purchaseToken(bytes32 memory auctionId) return (address tokenAddress) { 
        (, , tokenAddress, , , , , ,) = abi.decode(auctionId);
    }

    function purchaseToken(bytes32 memory auctionId) return (address tokenAddress) { 
        (, tokenAddress, , , , , , ,) = abi.decode(auctionId);
    }

    function withdraw(bytes32 memory auctionId) 
        inactiveAuction(auctionId)
    public {
        uint256 proceedsBalance = _auctions[auctionId].proceeds;
        uint256 reservesBalance = _auctions[auctionId].reserves;

        delete _auctions[auctionId].proceeds;
        delete _auctions[auctionId].reserves;

        if (proceedsBalance > 0) {
            IERC20(purchaseToken(auctionId).transfer(operatorAddress(auctionId), proceedsBalance));
        }
        if (reservesBalance > 0) {
            IERC20(reserveToken(auctionId).transfer(operatorAddress(auctionId), reservesBalance));
        }

        emit Withdraw(auctionId);
    }

    function claim(address biddingAddress, bytes32 memory auctionId) 
        inactiveAuction(auctionId)
    public {
        bytes32 memory claimHash = _claims[biddingAddress][auctionId];

        delete _claims[biddingAddress][auctionId];

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
            auctionIndex
        );

        require(auctionState.price == 0, "AUCTION EXISTS");

        IERC20(reserveToken).transferFrom(msg.sender, address(this), reserveAmount);

        auctionState.windowDuration = windowDuration;
        auctionState.windowTimestamp = block.timestamp;
        auctionState.startTimestamp = startTimestamp;
        auctionState.endTimestamp = endTimestamp;
        auctionState.reserves = reserveAmount;
        auctionState.price = startingPrice;

        _auctionIds[auctionIndex] = auctionId;

        emit NewAuction(auctionId, reserveToken, reserveAmount, startingPrice, endTimestamp);

        auctionIndex += 1; 
    }

    function getScalarPrice(bytes32 memory auctionId) public returns (UD60x18) {
        Auction storage auctionState = _auctions[auctionId];

        uint256 t = block.timestamp - auctionState.windowTimestamp;
        uint256 t_r = auctionState.endTimestamp - auctionState.windowTimestamp;

        UD60x18 x = ud((t % (t_r - t)) / t_r);
        UD60x18 y = ud(auctionState.price);

        return ln(exp(x + ud(1))) * y;
    } 

    function commitBid(bytes32 memory auctionId, uint256 price, uint256 volume) 
        activeAuction(auctionId)
    public payable {
        Window storage currentWindow = _window[auctionId][_windows[auctionId]];

        _auctions[auctionId].windowTimestamp = block.timestamp;

        if (currentWindow.expiry != 0) {
            if (remainingWindowTime(auctionId) > 0) {
                require(currentWindow.price < price, "INVALID WINDOW PRICE");
            } else {
                windowExpiration(currentWindow):
            }
        } 

        currentWindow = _window[auctionId][_windows[auctionId]];

        if (currentWindow.price == 0) {
            require(getScalarPrice(auctionId) <= ud(price), "INVALID CURVE PRICE");
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

        uint256 auctionRemainingTime = auctions[auctionId].duration - elapsedTime(auctionId, block.timestamp);
      
        _auctions[auctionId].reserves = _auctions[auctionId].reserves - (volume / price);
        _auctions[auctionId].endTimestamp = block.timestamp + auctionRemainingTime; 
        _auctions[auctionId].price = price;

        fufillWindow(auctionId, _windows[auctionId]);

        _windows[auctionId] = _windows[auctionId] + 1; 

        emit Expiration(auctionId, currentWindow.bidId, _windows[auctionId] - 1);
    }

    function fufillWindow(bytes32 memory auctionId, uint256 windowId) public {
        Window storage selectWindow = _window[auctionId][windowId];

        require(!fufillmentWindow.processed, "WINDOW ALREADY FUFILLED");

        (, uint256 biddingAddress, uint256 price, uint256 volume) = abi.decode(fulfillmentWindow.bidId);
        (uint256 refundBalance, uint256 claimBalance) = abi.decode(_claims[biddingAddress][auctionId]);

        fufillmentWindow.processed = true;

        _auctions[auctionId].proceeds = _auctions[auctionId].proceeds + volume;
        _claims[biddingAddress][auctionId] = abi.encodePacked(
            refundBalance - volume, 
            claimBalance + (volume / price
        );
    }

    function remainingTime(bytes32 memory auctionId) public view returns (uint256) {
        return _auctions[auctionId].endTimestamp - block.timestamp;
    }

    function remainingWindowTime(bytes32 memory auctionId) public view returns (uint256) {
        return _window[auctionId][_windows[auctionId]].expiry - block.timestamp;
    }

    function elapsedTime(bytes memory auctionId, uint256 timestamp) public view returns (uint256) {
        uint256 windowElapsedTime = _auctions[auctionId].windowDuration * _windows[auctionId];
     
        return timestamp - windowElapsedTime - auctionState.startTimestamp;
    }

    event Withdraw(bytes32 indexed auctionId);

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

    event Expiration(
        bytes32 indexed auctionId, 
        bytes32 memory bidId,
        uint256 windowIndex
    );

    event Claim(
        bytes32 indexed auctionId, 
        address indexed owner, 
        bytes32 memory bidId
    );

}
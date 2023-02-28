pragma solidity ^0.8.13;

import { IERC20 } from "./interfaces/IERC20.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

import { add, mul, exp, ln, ud, unwrap, gte } from "@prb/math/UD60x18.sol";

contract RollingDutchAuction { 

    uint256 public auctionIndex;

    mapping (address => mapping (bytes => bytes)) public _claims;
    mapping (bytes => mapping (uint256 => Window)) public _window;

    mapping (uint256 => bytes) public _auctionIds;
    mapping (bytes => Auction) public _auctions;
    mapping (bytes => uint256) public _windows;
   
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
        bytes bidId; 
        uint256 price;
        uint256 amount;
        bool processed;
    }

    modifier activeAuction(bytes memory auctionId) {
        require(remainingWindowTime(auctionId) > 0 || remainingTime(auctionId) > 0);
        _;
    }

    modifier inactiveAuction(bytes memory auctionId) {
        require(remainingWindowTime(auctionId) == 0 && remainingTime(auctionId) == 0);
        _;
    }

    function operatorAddress(bytes memory auctionId) public view returns (address owner) { 
        (owner, , , , , , , ,) = abi.decode(auctionId, (address, address, address, uint256, uint256, uint256, uint256, uint256, uint256));
    }

    function purchaseToken(bytes memory auctionId) public view returns (address tokenAddress) { 
        (, , tokenAddress, , , , , ,) = abi.decode(auctionId, (address, address, address, uint256, uint256, uint256, uint256, uint256, uint256));
    }

    function reserveToken(bytes memory auctionId) public view returns (address tokenAddress) { 
        (, tokenAddress, , , , , , ,) = abi.decode(auctionId, (address, address, address, uint256, uint256, uint256, uint256, uint256, uint256));
    }

    function withdraw(bytes memory auctionId) 
        inactiveAuction(auctionId)
    public {
        uint256 proceedsBalance = _auctions[auctionId].proceeds;
        uint256 reservesBalance = _auctions[auctionId].reserves;

        delete _auctions[auctionId].proceeds;
        delete _auctions[auctionId].reserves;

        if (proceedsBalance > 0) {
            IERC20(purchaseToken(auctionId)).transfer(operatorAddress(auctionId), proceedsBalance);
        }
        if (reservesBalance > 0) {
            IERC20(reserveToken(auctionId)).transfer(operatorAddress(auctionId), reservesBalance);
        }

        emit Withdraw(auctionId);
    }

    function claim(address biddingAddress, bytes memory auctionId) 
        inactiveAuction(auctionId)
    public {
        bytes memory claimHash = _claims[biddingAddress][auctionId];

        delete _claims[biddingAddress][auctionId];

        (uint256 refundBalance, uint256 claimBalance) = abi.decode(claimHash, (uint256, uint256)); 

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
        bytes memory auctionId = abi.encodePacked(
            operatorAddress,
            reserveToken,
            purchaseToken,
            reserveAmount,
            startingPrice,
            startTimestamp,
            endTimestamp,
            windowDuration,
            auctionIndex
        );
        Auction storage auctionState = _auctions[auctionId];

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

    function getScalarPrice(bytes memory auctionId) public returns (UD60x18) {
        Auction storage auctionState = _auctions[auctionId];

        uint256 t = block.timestamp - auctionState.windowTimestamp;
        uint256 t_r = auctionState.endTimestamp - auctionState.windowTimestamp;

        UD60x18 x = ud((t % (t_r - t)) / t_r);
        UD60x18 y = ud(auctionState.price);

        return mul(ln(exp(add(x, ud(1)))), y);
    } 

    function commitBid(bytes memory auctionId, uint256 price, uint256 volume) 
        activeAuction(auctionId)
    public {
        Window storage currentWindow = _window[auctionId][_windows[auctionId]];

        if (currentWindow.expiry != 0) {
            if (remainingWindowTime(auctionId) > 0) {
                require(currentWindow.price < price, "INVALID WINDOW PRICE");
            } else {
                windowExpiration(currentWindow);
            }
        } 

        currentWindow = _window[auctionId][_windows[auctionId]];

        if (currentWindow.price == 0) {
            require(gte(ud(price), getScalarPrice(auctionId)), "INVALID CURVE PRICE");
        }

        IERC20(purchaseToken(auctionId)).transferFrom(msg.sender, address(this), volume);

        require(_auctions[auctionId].reserves >= volume / price, "INSUFFICIENT RESERVES");

        currentWindow.expiry = block.timestamp + _auctions[auctionId].windowDuration;
        currentWindow.bidId = abi.encodePacked(auctionId, msg.sender, price, volume);
        currentWindow.price = price;

        (uint256 refundBalance, uint256 claimBalance) = abi.decode(_claims[msg.sender][auctionId], (uint256, uint256)); 

        _claims[msg.sender][auctionId] = abi.encodePacked(refundBalance + volume, claimBalance);

        emit Offer(auctionId, msg.sender, currentWindow.bidId, currentWindow.expiry);
    }


    function windowExpiration(Window memory currentWindow) internal {
        (bytes memory auctionId, address biddingAddress, uint256 price, uint256 volume) = abi.decode(currentWindow.bidId, (bytes, address, uint256, uint256));

        uint256 auctionRemainingTime = _auctions[auctionId].duration - elapsedTime(auctionId, block.timestamp);
      
        _auctions[auctionId].reserves = _auctions[auctionId].reserves - (volume / price);
        _auctions[auctionId].endTimestamp = block.timestamp + auctionRemainingTime; 
        _auctions[auctionId].windowTimestamp = block.timestamp;
        _auctions[auctionId].price = price;

        fufillWindow(auctionId, _windows[auctionId]);

        _windows[auctionId] = _windows[auctionId] + 1; 

        emit Expiration(auctionId, currentWindow.bidId, _windows[auctionId] - 1);
    }

    function fufillWindow(bytes memory auctionId, uint256 windowId) public {
        Window storage fufillmentWindow = _window[auctionId][windowId];

        require(!fufillmentWindow.processed, "WINDOW ALREADY FUFILLED");

        (, address biddingAddress, uint256 price, uint256 volume) = abi.decode(fufillmentWindow.bidId, (bytes, address, uint256, uint256));
        (uint256 refundBalance, uint256 claimBalance) = abi.decode(_claims[biddingAddress][auctionId], (uint256, uint256));

        fufillmentWindow.processed = true;

        _auctions[auctionId].proceeds = _auctions[auctionId].proceeds + volume;
        _claims[biddingAddress][auctionId] = abi.encodePacked(
            refundBalance - volume, 
            claimBalance + (volume / price)
        );
    }

    function remainingTime(bytes memory auctionId) public view returns (uint256) {
        return _auctions[auctionId].endTimestamp - block.timestamp;
    }

    function remainingWindowTime(bytes memory auctionId) public view returns (uint256) {
        return _window[auctionId][_windows[auctionId]].expiry - block.timestamp;
    }

    function elapsedTime(bytes memory auctionId, uint256 timestamp) public view returns (uint256) {
        uint256 windowElapsedTime = _auctions[auctionId].windowDuration * _windows[auctionId];
     
        return timestamp - windowElapsedTime - _auctions[auctionId].startTimestamp;
    }

    event Withdraw(bytes indexed auctionId);

    event NewAuction(
        bytes indexed auctionId, 
        address reserveToken, 
        uint256 reserves,
        uint256 price,
        uint256 endTimestamp
    );

    event Offer(
        bytes indexed auctionId, 
        address indexed owner, 
        bytes indexed bidId, 
        uint256 expiry
    );

    event Expiration(
        bytes indexed auctionId, 
        bytes indexed bidId,
        uint256 windowIndex
    );

    event Claim(
        bytes indexed auctionId, 
        address indexed owner, 
        bytes indexed bidId
    );

}
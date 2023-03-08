pragma solidity ^0.8.13;

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { IERC20 } from "@root/interfaces/IERC20.sol";

import { add, sub, mul, exp, ln, wrap, unwrap, gte, mod, div, eq } from "@prb/math/UD60x18.sol";

contract RollingDutchAuction {
    uint256 public auctionIndex;

    mapping(address => mapping(bytes => bytes)) public _claims;
    mapping(bytes => mapping(uint256 => Window)) public _window;

    mapping(uint256 => bytes) public _auctionIds;
    mapping(bytes => Auction) public _auctions;
    mapping(bytes => uint256) public _windows;

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
        uint256 volume;
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

    function operatorAddress(bytes memory auctionId) public view returns (address opAddress) {
        (opAddress,,,) = abi.decode(auctionId, (address, address, address, bytes));
    }

    function purchaseToken(bytes memory auctionId) public view returns (address tokenAddress) {
        (,, tokenAddress,) = abi.decode(auctionId, (address, address, address, bytes));
    }

    function reserveToken(bytes memory auctionId) public view returns (address tokenAddress) {
        (, tokenAddress,,) = abi.decode(auctionId, (address, address, address, bytes));
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
    ) public returns (bytes memory auctionId) {
        auctionId = abi.encode(
            operatorAddress,
            reserveToken,
            purchaseToken,
            abi.encodePacked(reserveAmount, startingPrice, startTimestamp, endTimestamp, windowDuration, auctionIndex)
        );
        Auction storage auctionState = _auctions[auctionId];

        require(auctionState.price == 0, "AUCTION EXISTS");

        IERC20(reserveToken).transferFrom(msg.sender, address(this), reserveAmount);

        uint256 auctionDuration = endTimestamp - startTimestamp;

        auctionState.windowDuration = windowDuration;
        auctionState.windowTimestamp = startTimestamp;
        auctionState.startTimestamp = startTimestamp;
        auctionState.endTimestamp = endTimestamp;
        auctionState.reserves = reserveAmount;
        auctionState.duration = auctionDuration;
        auctionState.price = startingPrice;

        _auctionIds[auctionIndex] = auctionId;

        emit NewAuction(auctionId, reserveToken, reserveAmount, startingPrice, endTimestamp);

        auctionIndex += 1;
    }

    function getScalarPriceUint(bytes memory auctionId) public returns (uint256) {
        return unwrap(getScalarPrice(auctionId));
    }

    function getScalarPrice(bytes memory auctionId) public returns (UD60x18) {
        Auction storage auctionState = _auctions[auctionId];
        Window storage currentWindow = _window[auctionId][_windows[auctionId]];

        uint256 timestamp = isExpiredWindow(auctionId) ? currentWindow.expiry : auctionState.windowTimestamp;

        UD60x18 t = wrap(block.timestamp - timestamp);
        UD60x18 t_r = wrap(auctionState.endTimestamp - timestamp);
        UD60x18 p_1 = wrap(currentWindow.price);
        UD60x18 p_2 = wrap(auctionState.price);

        UD60x18 x = div(add(t, mod(t, sub(t_r, t))), t_r);
        UD60x18 y = eq(p_1, wrap(0)) ? p_2 : p_1;
        UD60x18 y_x = mul(ln(exp(x)), y);

        return sub(y, y_x);
    }

    function commitBid(bytes memory auctionId, uint256 price, uint256 volume) 
        activeAuction(auctionId) 
    public returns (bytes memory) {
        Window storage currentWindow = _window[auctionId][_windows[auctionId]];

        bool hasExpired;

        if (currentWindow.expiry != 0) {
            if (remainingWindowTime(auctionId) > 0) {
                if (currentWindow.price < price) {
                    require(currentWindow.volume <= volume, "INSUFFICIENT WINDOW VOLUME");
                } else {
                    require(currentWindow.price < price, "INVALID WINDOW PRICE");
                }
            } else {
                hasExpired = true;
            }
        }

        if (currentWindow.price == 0 || hasExpired) {
            require(gte(wrap(price), getScalarPrice(auctionId)), "INVALID CURVE PRICE");
        }

        IERC20(purchaseToken(auctionId)).transferFrom(msg.sender, address(this), volume);

        require(_auctions[auctionId].reserves >= volume / price, "INSUFFICIENT RESERVES");

        bytes memory bidId = abi.encode(auctionId, msg.sender, price, volume);

        uint256 refundBalance;
        uint256 claimBalance;

        currentWindow.expiry = block.timestamp + _auctions[auctionId].windowDuration;
        currentWindow.volume = volume;
        currentWindow.price = price;
        currentWindow.bidId = bidId;

        if (keccak256(_claims[msg.sender][auctionId]) != keccak256(bytes(""))) {
            (refundBalance, claimBalance) = abi.decode(_claims[msg.sender][auctionId], (uint256, uint256));
        }

        _claims[msg.sender][auctionId] = abi.encode(refundBalance + volume, claimBalance);
        _auctions[auctionId].windowTimestamp = block.timestamp;

        if (hasExpired) {
            windowExpiration(currentWindow);
        }

        emit Offer(auctionId, msg.sender, currentWindow.bidId, currentWindow.expiry);

        return bidId;
    }

    function isExpiredWindow(bytes memory auctionId) public returns (bool) {
        Window storage currentWindow = _window[auctionId][_windows[auctionId]];

        return currentWindow.expiry != 0 && currentWindow.expiry < block.timestamp;
    }

    function windowExpiration(Window memory currentWindow) internal returns (uint256) {
        (bytes memory auctionId, address biddingAddress, uint256 price, uint256 volume) =
            abi.decode(currentWindow.bidId, (bytes, address, uint256, uint256));

        uint256 auctionRemainingTime = _auctions[auctionId].duration - elapsedTime(auctionId, block.timestamp);

        _auctions[auctionId].endTimestamp = block.timestamp + auctionRemainingTime;
        _auctions[auctionId].windowTimestamp = currentWindow.expiry;
        _auctions[auctionId].price = price;

        fufillWindow(auctionId, _windows[auctionId]);

        emit Expiration(auctionId, currentWindow.bidId, _windows[auctionId
        ]);

        return _windows[auctionId] + 1;
    }

    function fufillWindow(bytes memory auctionId, uint256 windowId) public {
        Window storage fufillmentWindow = _window[auctionId][windowId];

        require(!fufillmentWindow.processed, "WINDOW ALREADY FUFILLED");

        (, address biddingAddress, uint256 price, uint256 volume) =
            abi.decode(fufillmentWindow.bidId, (bytes, address, uint256, uint256));
        (uint256 refundBalance, uint256 claimBalance) =
            abi.decode(_claims[biddingAddress][auctionId], (uint256, uint256));

        delete _claims[biddingAddress][auctionId];

        fufillmentWindow.processed = true;

        _auctions[auctionId].reserves = _auctions[auctionId].reserves - (volume / price);
        _auctions[auctionId].proceeds = _auctions[auctionId].proceeds + volume;

        _claims[biddingAddress][auctionId] = abi.encode(refundBalance - volume, claimBalance + (volume / price));

        emit Fufillment(auctionId, fufillmentWindow.bidId, windowId);
    }

    function remainingTime(bytes memory auctionId) public view returns (uint256) {
        uint256 endTimestamp = _auctions[auctionId].endTimestamp;

        if (endTimestamp > block.timestamp) {
            return endTimestamp - block.timestamp;
        } else {
            return 0;
        }
    }

    function remainingWindowTime(bytes memory auctionId) public view returns (uint256) {
        uint256 expiryTimestamp = _window[auctionId][_windows[auctionId]].expiry;

        if (expiryTimestamp == 0 || block.timestamp > expiryTimestamp) {
            return 0;
        } else {
            return expiryTimestamp - block.timestamp;
        }
    }

    function elapsedTime(bytes memory auctionId, uint256 timestamp) public returns (uint256) {
        uint256 windowIndex = _windows[auctionId] + 1;
        uint256 windowElapsedTime = _auctions[auctionId].windowDuration * windowIndex;

        return timestamp - _auctions[auctionId].startTimestamp - windowElapsedTime;
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
        if (claimBalance > 0) {
            IERC20(reserveToken(auctionId)).transfer(biddingAddress, claimBalance);
        }

        emit Claim(auctionId, claimHash);
    }

    event NewAuction(
        bytes indexed auctionId, address reserveToken, uint256 reserves, uint256 price, uint256 endTimestamp
    );

    event Offer(bytes indexed auctionId, address indexed owner, bytes indexed bidId, uint256 expiry);

    event Fufillment(bytes indexed auctionId, bytes indexed bidId, uint256 windowId);

    event Expiration(bytes indexed auctionId, bytes indexed bidId, uint256 windowId);

    event Claim(bytes indexed auctionId, bytes indexed bidId);

    event Withdraw(bytes indexed auctionId);

    event Debug(uint256 a, uint256 b);
}

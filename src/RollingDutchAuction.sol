pragma solidity ^0.8.13;

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { IERC20 } from "@root/interfaces/IERC20.sol";

import { inv, add, sub, mul, exp, ln, wrap, unwrap, gte, mod, div } from "@prb/math/UD60x18.sol";

contract RollingDutchAuction {
    mapping(address => mapping(bytes => bytes)) public _claims;
    mapping(bytes => mapping(uint256 => Window)) public _window;

    mapping(bytes => Auction) public _auctions;
    mapping(bytes => uint256) public _windows;

    struct Auction {
        uint256 windowDuration;
        uint256 windowTimestamp;
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 duration;
        uint256 proceeds;
        uint256 reserves;
        uint256 price;
    }

    struct Window {
        bytes bidId;
        uint256 expiry;
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

    function operatorAddress(bytes memory auctionId) public pure returns (address opAddress) {
        (opAddress,,,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    function purchaseToken(bytes memory auctionId) public pure returns (address tokenAddress) {
        (,, tokenAddress,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    function reserveToken(bytes memory auctionId) public pure returns (address tokenAddress) {
        (, tokenAddress,,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    function balancesOf(bytes memory claimHash) public pure returns (uint256, uint256) {
        uint256 refundBalance;
        uint256 claimBalance;

        if (keccak256(claimHash) != keccak256(bytes(""))) {
            (refundBalance, claimBalance) = abi.decode(claimHash, (uint256, uint256));
        }

        return (refundBalance, claimBalance);
    }

    function createAuction(
        address operatorAddress,
        address reserveToken,
        address purchaseToken,
        uint256 reserveAmount,
        uint256 minimumPurchaseAmount,
        uint256 startingPrice,
        uint256 startTimestamp,
        uint256 endTimestamp,
        uint256 windowDuration
    ) public returns (bytes memory) {
        bytes memory auctionId = abi.encode(
            operatorAddress,
            reserveToken,
            purchaseToken,
            minimumPurchaseAmount,
            abi.encodePacked(reserveAmount, startingPrice, startTimestamp, endTimestamp, windowDuration)
        );

        Auction storage state = _auctions[auctionId];

        require(state.price == 0, "AUCTION EXISTS");

        IERC20(reserveToken).transferFrom(msg.sender, address(this), reserveAmount);

        state.duration = endTimestamp - startTimestamp;
        state.windowDuration = windowDuration;
        state.windowTimestamp = startTimestamp;
        state.startTimestamp = startTimestamp;
        state.endTimestamp = endTimestamp;
        state.reserves = reserveAmount;
        state.price = startingPrice;

        emit NewAuction(auctionId, reserveToken, reserveAmount, startingPrice, endTimestamp);

        return auctionId;
    }

    function minimumPurchase(bytes memory auctionId) public pure returns (uint256 minimumAmount) {
        (,,, minimumAmount,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    function maximumPurchase(bytes memory auctionId) public view returns (uint256) {
        return unwrap(inv(scalarPrice(auctionId)));
    }

    function scalarPriceUint(bytes memory auctionId) public view returns (uint256) {
        return unwrap(scalarPrice(auctionId));
    }

    function scalarPrice(bytes memory auctionId) public view returns (UD60x18) {
        Auction storage state = _auctions[auctionId];
        Window storage w = _window[auctionId][_windows[auctionId]];

        bool isInitialised = w.expiry != 0;
        bool isExpired = w.expiry < block.timestamp && isInitialised;

        uint256 timestamp = isExpired ? w.expiry : state.windowTimestamp;

        UD60x18 t = wrap(block.timestamp - timestamp);
        UD60x18 t_r = wrap(state.endTimestamp - timestamp);

        UD60x18 x = div(add(t, mod(t, sub(t_r, t))), t_r);
        UD60x18 y = !isInitialised ? wrap(state.price) : wrap(w.price);

        return sub(y, mul(ln(exp(x)), y));
    }

    function commitBid(bytes memory auctionId, uint256 price, uint256 volume) 
        activeAuction(auctionId) 
    public returns (bytes memory) {
        Window storage w = _window[auctionId][_windows[auctionId]];

        require(minimumPurchase(auctionId) <= volume, "INSUFFICIENT VOLUME");

        bool hasExpired;

        if (w.expiry != 0) {
            if (remainingWindowTime(auctionId) > 0) {
                if (w.price < price) {
                    require(w.volume <= volume, "INSUFFICIENT WINDOW VOLUME");
                } else {
                    require(w.price < price, "INVALID WINDOW PRICE");
                }
            } else {
                hasExpired = true;
            }
        }

        if (w.price == 0 || hasExpired) {
            require(gte(wrap(price), scalarPrice(auctionId)), "INVALID CURVE PRICE");
        }

        IERC20(purchaseToken(auctionId)).transferFrom(msg.sender, address(this), volume);

        require(_auctions[auctionId].reserves >= (volume / price), "INSUFFICIENT RESERVES");
        require(maximumPurchase(auctionId) >= (volume / price), "INVALID VOLUME");

        bytes memory bidId = abi.encode(auctionId, msg.sender, price, volume);

        (uint256 refund, uint256 claim) = balancesOf(_claims[msg.sender][auctionId]);

        _claims[msg.sender][auctionId] = abi.encode(refund + volume, claim);

        if (hasExpired) {
            w = _window[auctionId][windowExpiration(auctionId)];
        } 

        _auctions[auctionId].windowTimestamp = block.timestamp;

        w.expiry = block.timestamp + _auctions[auctionId].windowDuration;
        w.volume = volume;
        w.price = price;
        w.bidId = bidId;

        emit Offer(auctionId, msg.sender, w.bidId, w.expiry);

        return bidId;
    }

    function windowExpiration(bytes memory auctionId) internal returns (uint256) {
        uint256 windowIndex = _windows[auctionId];
        uint256 auctionElapsedTime = elapsedTime(auctionId, block.timestamp);
        uint256 auctionRemainingTime = _auctions[auctionId].duration - auctionElapsedTime;

        bytes memory winningBidId = _window[auctionId][windowIndex].bidId;

        _auctions[auctionId].endTimestamp = block.timestamp + auctionRemainingTime;
        _auctions[auctionId].price = _window[auctionId][windowIndex].price;

        _windows[auctionId] = windowIndex + 1;

        fulfillWindow(auctionId, windowIndex);

        emit Expiration(auctionId, winningBidId, windowIndex);

        return windowIndex + 1;
    }

    function fulfillWindow(bytes memory auctionId, uint256 windowId) public {
        Window storage w = _window[auctionId][windowId];

        require(w.expiry < block.timestamp, "WINDOW UNEXPIRED");
        require(!w.processed, "WINDOW ALREADY FUFILLED");

        (, address bidder, uint256 price, uint256 volume) = abi.decode(w.bidId, (bytes, address, uint256, uint256));
        (uint256 refund, uint256 claim) = balancesOf(_claims[bidder][auctionId]);

        delete _claims[bidder][auctionId];

        w.processed = true;

        _auctions[auctionId].reserves -= volume / price;
        _auctions[auctionId].proceeds += volume;

        _claims[bidder][auctionId] = abi.encode(refund - volume, claim + (volume / price));

        emit Fufillment(auctionId, w.bidId, windowId);
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

    function elapsedTime(bytes memory auctionId, uint256 timestamp) public view returns (uint256) {
        uint256 windowIndex = _windows[auctionId] + 1;
        uint256 windowElapsedTime = _auctions[auctionId].windowDuration * windowIndex;

        return timestamp - _auctions[auctionId].startTimestamp - windowElapsedTime;
    }

    function withdraw(bytes memory auctionId) 
        inactiveAuction(auctionId) 
    public {
        uint256 proceeds = _auctions[auctionId].proceeds;
        uint256 reserves = _auctions[auctionId].reserves;

        delete _auctions[auctionId].proceeds;
        delete _auctions[auctionId].reserves;

        if (proceeds > 0) {
            IERC20(purchaseToken(auctionId)).transfer(operatorAddress(auctionId), proceeds);
        }
        if (reserves > 0) {
            IERC20(reserveToken(auctionId)).transfer(operatorAddress(auctionId), reserves);
        }

        emit Withdraw(auctionId);
    }

    function redeem(address bidder, bytes memory auctionId)
        inactiveAuction(auctionId) 
    public {
        bytes memory claimHash = _claims[bidder][auctionId];

        (uint256 refund, uint256 claim) = balancesOf(claimHash);

        delete _claims[bidder][auctionId];

        if (refund > 0) {
            IERC20(purchaseToken(auctionId)).transfer(bidder, refund);
        }
        if (claim > 0) {
            IERC20(reserveToken(auctionId)).transfer(bidder, claim);
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
}

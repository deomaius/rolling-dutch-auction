pragma solidity 0.8.13;

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { IERC20 } from "@root/interfaces/IERC20.sol";

import { inv, add, sub, mul, exp, ln, wrap, unwrap, gte, mod, div } from "@prb/math/UD60x18.sol";

/*
    * @title Rolling Dutch Auction 
    * @author Samuel JJ Gosling 
    * @description A dutch auction derivative with composite logarithimic decay 
*/

contract RollingDutchAuction {

    /*  @dev Address mapping for an auction's redeemable balances  */
    mapping(address => mapping(bytes => bytes)) public _claims;

    /*  @dev Auction mapping translating to an indexed window      */
    mapping(bytes => mapping(uint256 => Window)) public _window;

    /*  @dev Auction mapping for associated parameters             */
    mapping(bytes => Auction) public _auctions;

    /*  @dev Auction mapping for the window index                  */
    mapping(bytes => uint256) public _windows;

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

    /*  
        * @dev Conditioner to ensure an auction is active  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    modifier activeAuction(bytes memory auctionId) {
        require(remainingWindowTime(auctionId) > 0 || remainingTime(auctionId) > 0);
        _;
    }

    /*  
        * @dev Conditioner to ensure an auction is inactive  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    modifier inactiveAuction(bytes memory auctionId) {
        require(remainingWindowTime(auctionId) == 0 && remainingTime(auctionId) == 0);
        _;
    }

    /*  
        * @dev Helper to view an auction's operator address  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function operatorAddress(bytes memory auctionId) public pure returns (address opAddress) {
        (opAddress,,,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    /*  
        * @dev Helper to view an auction's purchase token address  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Ancoded auction parameter identifier    
    */  
    function purchaseToken(bytes memory auctionId) public pure returns (address tokenAddress) {
        (,, tokenAddress,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    /*  
        * @dev Helper to view an auction's reserve token address  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function reserveToken(bytes memory auctionId) public pure returns (address tokenAddress) {
        (, tokenAddress,,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    /*  
        * @dev Helper to decode claim hash balances
        * @param c͟l͟a͟i͟m͟H͟a͟s͟h͟ Encoded (uint256, uint256) values 
    */  
    function balancesOf(bytes memory claimHash) public pure returns (uint256, uint256) {
        uint256 refundBalance;
        uint256 claimBalance;

        if (keccak256(claimHash) != keccak256(bytes(""))) {
            (refundBalance, claimBalance) = abi.decode(claimHash, (uint256, uint256));
        }

        return (refundBalance, claimBalance);
    }

    /*  
        * @dev Auction deployment
        * @param o͟p͟e͟r͟a͟t͟o͟r͟A͟d͟r͟e͟s͟s͟ Auction management address
        * @param r͟e͟s͟e͟r͟v͟e͟T͟o͟k͟e͟n͟ Auctioning token address
        * @param p͟u͟r͟c͟h͟a͟s͟e͟T͟o͟k͟e͟n͟ Currency token address
        * @param r͟e͟s͟e͟r͟v͟e͟A͟m͟o͟u͟n͟t͟ Auctioning token amount
        * @param m͟i͟n͟i͟m͟u͟m͟P͟u͟r͟c͟h͟a͟s͟e͟A͟m͟o͟u͟n͟t͟ Minimum currency purchase amount 
        * @param s͟t͟a͟r͟t͟i͟n͟g͟O͟r͟i͟g͟i͟n͟P͟r͟i͟c͟e͟ Auction starting price 
        * @param s͟t͟a͟r͟t͟T͟i͟m͟e͟s͟t͟a͟m͟p͟ Unix timestamp auction initiation
        * @param e͟n͟d͟T͟i͟m͟e͟s͟t͟a͟m͟p͟ Unix timestamp auction expiration
        * @param w͟i͟n͟d͟o͟w͟D͟u͟r͟a͟t͟i͟o͟n͟ Uinx time window duration
    */  
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
        state.price = startingOriginPrice;
        state.reserves = reserveAmount;

        emit NewAuction(auctionId, reserveToken, reserveAmount, startingPrice, endTimestamp);

        return auctionId;
    }

    /*  
        * @dev Helper to view an auction's minimum purchase amount   
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function minimumPurchase(bytes memory auctionId) public pure returns (uint256 minimumAmount) {
        (,,, minimumAmount,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    /*  
        * @dev Helper to view an auction's maximum order reserve amount  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */   
    function maximumPurchase(bytes memory auctionId) public view returns (uint256) {
        return unwrap(inv(scalarPrice(auctionId)));
    }

    /*  
        * @dev Helper to view an auction's active scalar price formatted to uint256  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function scalarPriceUint(bytes memory auctionId) public view returns (uint256) {
        return unwrap(scalarPrice(auctionId));
    }

    /*  
        * @dev Active price decay following time delta (x) between the current 
        * timestamp and the window's start timestamp or if the window is expired; time 
        * delta between the window's expiration. Which is the applied as the exponent 
        * of Euler's number and subject to the natural logarithim. Finally applied as  
        * as a product to the origin price (y) and substracted from itself
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */      
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

    /*  
        * @dev Bid submission 
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
        * @param p͟r͟i͟c͟e͟ Bid order price  
        * @param v͟o͟l͟u͟m͟e͟ Bid order volume
    */     
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

    /*  
        * @dev Expire and fulfill an auction's active window  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */     
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

    /*  
        * @dev Fulfill a window index even if the auction is inactive 
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
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

    /*  
        * @dev Helper to view an auction's remaining duration
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function remainingTime(bytes memory auctionId) public view returns (uint256) {
        uint256 endTimestamp = _auctions[auctionId].endTimestamp;

        if (endTimestamp > block.timestamp) {
            return endTimestamp - block.timestamp;
        } else {
            return 0;
        }
    }

    /*  
        * @dev Helper to view an auction's active remaining window duration
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function remainingWindowTime(bytes memory auctionId) public view returns (uint256) {
        uint256 expiryTimestamp = _window[auctionId][_windows[auctionId]].expiry;

        if (expiryTimestamp == 0 || block.timestamp > expiryTimestamp) {
            return 0;
        } else {
            return expiryTimestamp - block.timestamp;
        }
    }

    /*  
        * @dev Helper to view an auction's progress in unix time
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */     
    function elapsedTime(bytes memory auctionId, uint256 timestamp) public view returns (uint256) {
        uint256 windowIndex = _windows[auctionId] + 1;
        uint256 windowElapsedTime = _auctions[auctionId].windowDuration * windowIndex;

        return timestamp - _auctions[auctionId].startTimestamp - windowElapsedTime;
    }

    /*  
        * @dev Auction management redemption 
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */     
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

    /*  
        * @dev Auction order and refund redemption 
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
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

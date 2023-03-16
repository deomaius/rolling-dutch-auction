pragma solidity 0.8.13;

import { UD60x18 } from "@prb/math/UD60x18.sol";

import { IRDA } from "@root/interfaces/IRDA.sol";
import { IERC20 } from "@root/interfaces/IERC20.sol";

import { inv, add, sub, mul, wrap, unwrap, gt, mod, div } from "@prb/math/UD60x18.sol";

/*
    * @title Rolling Dutch Auction (RDA) 
    * @author Samuel JJ Gosling 
    * @description A dutch auction derivative with composite decay 
*/

contract RDA is IRDA {

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
        uint256 endTimestamp;        /*  @dev Unix auction end timestamp        */
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
    ) external returns (bytes memory) {
        bytes memory auctionId = abi.encode(
            operatorAddress,
            reserveToken,
            purchaseToken,
            minimumPurchaseAmount,
            abi.encodePacked(reserveAmount, startingOriginPrice, startTimestamp, endTimestamp, windowDuration)
        );

        Auction storage state = _auctions[auctionId];

        if (state.price != 0) {
            revert AuctionExists();
        }

        IERC20(reserveToken).transferFrom(msg.sender, address(this), reserveAmount);

        state.duration = endTimestamp - startTimestamp;
        state.windowDuration = windowDuration;
        state.windowTimestamp = startTimestamp;
        state.startTimestamp = startTimestamp;
        state.endTimestamp = endTimestamp;
        state.reserves = reserveAmount;
        state.price = startingOriginPrice;

        emit NewAuction(auctionId, reserveToken, reserveAmount, startingOriginPrice, endTimestamp);

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
    function maximumPurchase(bytes memory auctionId) public returns (uint256) {
        return unwrap(inv(scalarPrice(auctionId)));
    }

    /*  
        * @dev Helper to view an auction's active scalar price formatted to uint256  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function scalarPriceUint(bytes memory auctionId) external returns (uint256) {
        return unwrap(scalarPrice(auctionId));
    }

    /*  
        * @dev Active price decay proportional to time delta (t) between the current 
        * timestamp and the window's start timestamp or if the window is expired;  
        * the window's expiration. Time remaining (t_r) since the predefined 
        * timestamp until the auctions conclusion, is subtracted from t and applied
        * as modulo to t subject to addition of itself. The resultant is divided by t_r 
        * to compute elapsed progress (x) from the last timestamp, x is multipled by 
        * the origin price (y) and subtracted by y to result the decayed price.
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */      
    function scalarPrice(bytes memory auctionId) public returns (UD60x18) {
        Auction storage state = _auctions[auctionId];
        Window storage window = _window[auctionId][_windows[auctionId]];

        bool isInitialised = window.expiry != 0;
        bool isExpired = window.expiry < block.timestamp && isInitialised;

        uint256 timestamp = isExpired ? window.expiry : state.windowTimestamp;

        UD60x18 t = wrap(block.timestamp - timestamp);
        UD60x18 t_r = wrap(state.duration - elapsedTime(auctionId, timestamp));

        UD60x18 x = div(add(t, mod(t, sub(t_r, t))), t_r);
        UD60x18 y = !isInitialised ? wrap(state.price) : wrap(window.price);

        return sub(y, mul(y, x));
    }

    /*  
        * @dev Bid submission 
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
        * @param p͟r͟i͟c͟e͟ Bid order price  
        * @param v͟o͟l͟u͟m͟e͟ Bid order volume
    */     
    function commitBid(bytes memory auctionId, uint256 price, uint256 volume) 
        activeAuction(auctionId) 
    external returns (bytes memory) {
        Window storage window = _window[auctionId][_windows[auctionId]];

        if (volume < minimumPurchase(auctionId)) {
            revert InvalidPurchaseVolume();
        }

        bool hasExpired;

        if (window.expiry != 0) {
            if (remainingWindowTime(auctionId) > 0) {
                if (window.price < price) {
                    if (volume < window.volume) {
                        revert InvalidWindowVolume();
                    }
                } else {
                    revert InvalidWindowPrice(); 
                }
            } else {
                hasExpired = true;
            }
        }

        if (window.price == 0 || hasExpired) {
            if (gt(scalarPrice(auctionId), wrap(price))) {
                revert InvalidScalarPrice();
            }
        }

        IERC20(purchaseToken(auctionId)).transferFrom(msg.sender, address(this), volume);

        if (_auctions[auctionId].reserves < (volume / price)) {
            revert InsufficientReserves();
        }
        if (maximumPurchase(auctionId) < (volume / price)) {
            revert InvalidReserveVolume();
        }

        bytes memory bidId = abi.encode(auctionId, msg.sender, price, volume);

        (uint256 refund, uint256 claim) = balancesOf(_claims[msg.sender][auctionId]);

        _claims[msg.sender][auctionId] = abi.encode(refund + volume, claim);

        if (hasExpired) {
            window = _window[auctionId][windowExpiration(auctionId)];
        } 

        _auctions[auctionId].windowTimestamp = block.timestamp;

        window.expiry = block.timestamp + _auctions[auctionId].windowDuration;
        window.volume = volume;
        window.price = price;
        window.bidId = bidId;

        emit Offer(auctionId, msg.sender, window.bidId, window.expiry);

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

        _auctions[auctionId].endTimestamp = block.timestamp + auctionRemainingTime;
        _auctions[auctionId].price = _window[auctionId][windowIndex].price;

        _windows[auctionId] = windowIndex + 1;

        fulfillWindow(auctionId, windowIndex);

        emit Expiration(auctionId, _window[auctionId][windowIndex].bidId, windowIndex);

        return windowIndex + 1;
    }

    /*  
        * @dev Fulfill a window index even if the auction is inactive 
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function fulfillWindow(bytes memory auctionId, uint256 windowId) public {
        Window storage window = _window[auctionId][windowId];

        if (window.expiry > block.timestamp) {
            revert WindowUnexpired();
        }
        if (window.processed) {
            revert WindowFulfilled();
        }

        (, address bidder, uint256 price, uint256 volume) = abi.decode(window.bidId, (bytes, address, uint256, uint256));
        (uint256 refund, uint256 claim) = balancesOf(_claims[bidder][auctionId]);

        delete _claims[bidder][auctionId];

        window.processed = true;

        _auctions[auctionId].reserves -= volume / price;
        _auctions[auctionId].proceeds += volume;

        _claims[bidder][auctionId] = abi.encode(refund - volume, claim + (volume / price));

        emit Fufillment(auctionId, window.bidId, windowId);
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

        if (expiryTimestamp > 0 && block.timestamp < expiryTimestamp) {
            return expiryTimestamp - block.timestamp;
        } else {
            return 0;
        }
    }

    /*  
        * @dev Helper to view an auction's progress in unix time
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */     
    function elapsedTime(bytes memory auctionId, uint256 timestamp) public view returns (uint256) {
        uint256 windowIndex = _windows[auctionId] + 1;
        uint256 elapsedTime =  timestamp - _auctions[auctionId].startTimestamp;
        uint256 windowElapsedTime = _auctions[auctionId].windowDuration * windowIndex;

        if (elapsedTime > windowElapsedTime) {
            return elapsedTime - windowElapsedTime; 
        } else {
            return elapsedTime;
        }
    }

    /*  
        * @dev Auction management redemption 
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */     
    function withdraw(bytes memory auctionId) 
        inactiveAuction(auctionId) 
    external {
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
    external {
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

}

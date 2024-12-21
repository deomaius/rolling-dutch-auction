// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import { IRDA } from "@root/interfaces/IRDA.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/security/ReentrancyGuard.sol";

/*
    * @title Rolling Dutch Auction (RDA) 
    * @author Samuel JJ Gosling (@deomaius)
    * @description A dutch auction derivative with composite decay 
*/

contract RDA is IRDA, ReentrancyGuard {
    
    using SafeERC20 for IERC20;

    /*  @dev Address mapping for an auction's redeemable balances  */
    mapping(address => mapping(bytes => bytes)) public _claims;

    /*  @dev Auction mapping translating to an indexed window      */
    mapping(bytes => mapping(uint256 => Window)) public _window;

    /*  @dev Auction mapping for associated parameters             */
    mapping(bytes => Auction) public _auctions;

    /*  @dev Auction mapping for the window index                  */
    mapping(bytes => uint256) public _windows;

    /*  
        * @dev Condition to ensure an auction is active  
        * @param auctionId Encoded auction parameter identifier    
    */  
    modifier activeAuction(bytes calldata auctionId) {
        if (remainingWindowTime(auctionId) == 0 && remainingTime(auctionId) == 0) {
            revert AuctionInactive();
        }
        _;
    }

    /*  
        * @dev Condition to ensure an auction is inactive  
        * @param auctionId Encoded auction parameter identifier    
    */  
    modifier inactiveAuction(bytes calldata auctionId) {
        if (remainingWindowTime(auctionId) > 0 || remainingTime(auctionId) > 0) {
            revert AuctionActive();
        }
        _;
    }

    /*  
        * @dev Helper to view an auction's operator address  
        * @param auctionId Encoded auction parameter identifier
        * @return operator Auction operator address
    */  
    function operatorAddress(bytes calldata auctionId) public pure returns (address operator) {
        (operator,,,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    /*  
        * @dev Helper to view an auction's purchase token address  
        * @param auctionId Encoded auction parameter identifier
        * @return Token interface    
    */  
    function purchaseToken(bytes calldata auctionId) public pure returns (IERC20) {
        (,, address tokenAddress,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));

        return IERC20(tokenAddress);
    }

    /*  
        * @dev Helper to view an auction's reserve token address  
        * @param auctionId Encoded auction parameter identifier
        * @return Token interface   
    */  
    function reserveToken(bytes calldata auctionId) public pure returns (IERC20) {
        (, address tokenAddress,,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));

        return IERC20(tokenAddress);
    }

    /*  
        * @dev Helper to decode claim hash balances
        * @param claimHash Encoded claim parameter identifer 
        * @return refund Account refund balance
        * @return claim Account claim balance
    */  
    function balancesOf(bytes memory claimHash) public pure returns (uint256 refund, uint256 claim) {
        if (keccak256(claimHash) != keccak256(bytes(""))) {
            (refund, claim) = abi.decode(claimHash, (uint256, uint256));
        }
    }

    /*  
        * @dev Helper to decode bid identifer parameters
        * @param bidId Encoded bid parameter indentifier  
        * @return auctionId Encoded auction parameter identifier
        * @return bidder Order recipient address
        * @return price Order price
        * @return volume Order volume
    */  
    function bidParameters(bytes memory bidId) public pure returns (
        bytes memory auctionId, 
        address bidder,  
        uint256 price, 
        uint256 volume
    ) {
        (auctionId, bidder, price, volume) = abi.decode(bidId, (bytes, address, uint256, uint256));
    }

    /*  
        * @dev Helper to query whether the current window is initialised
        * @param auctionId Encoded auction parameter identifier
        * @return Window state condition
    */  
    function isWindowInit(bytes calldata auctionId) public view returns (bool) {
        return _window[auctionId][_windows[auctionId]].expiry != 0;   
    }

    /*  
        * @dev Helper to query whether the current window is active
        * @param Encoded auction parameter identifier
        * @return Window state condition
    */ 
    function isWindowActive(bytes calldata auctionId) public view returns (bool) {
        Window storage window = _window[auctionId][_windows[auctionId]];

        return isWindowInit(auctionId) && window.expiry > block.timestamp;   
    }

    /*  
        * @dev Helper to query whether the current window is expired
        * @param auctionId Encoded auction parameter identifier
        * @return Window state condition
    */ 
    function isWindowExpired(bytes calldata auctionId) public view returns (bool) {
        Window storage window = _window[auctionId][_windows[auctionId]];

        return isWindowInit(auctionId) && window.expiry < block.timestamp;   
    }

    /*  
        * @dev Auction deployment
        * @param operatorAddress Auction management address
        * @param reserveToken Auctioning token address
        * @param purchaseToken Currency token address
        * @param reserveAmount Auctioning token amount
        * @param minimumPurchaseAmount Minimum currency purchase amount 
        * @param startingOriginPrice Auction starting price 
        * @param startTimestamp Unix timestamp auction initiation
        * @param endTimestamp Unix timestamp auction expiration
        * @param windowDuration Unix time window duration
        * @return Encoded auction parameter identifier 
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
    ) override external returns (bytes memory) {
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
        if (startingOriginPrice == 0) {
            revert InvalidAuctionPrice();
        }
        if (startTimestamp < block.timestamp) {
            revert InvalidAuctionTimestamp();
        }
        if (endTimestamp - startTimestamp < 1 days || windowDuration < 2 hours) {
            revert InvalidAuctionDurations();
        }
        if (IERC20Metadata(reserveToken).decimals() != IERC20Metadata(purchaseToken).decimals()){
            revert InvalidTokenDecimals();
        }

        state.duration = endTimestamp - startTimestamp;
        state.windowDuration = windowDuration;
        state.windowTimestamp = startTimestamp;
        state.startTimestamp = startTimestamp;
        state.endTimestamp = endTimestamp;
        state.price = startingOriginPrice;
        state.reserves = reserveAmount;

        emit NewAuction(auctionId, reserveToken, reserveAmount, startingOriginPrice, endTimestamp);

        IERC20(reserveToken).safeTransferFrom(msg.sender, address(this), reserveAmount);

        return auctionId;
    }

    /*  
        * @dev Helper to view an auction's minimum purchase amount   
        * @param auctionId Encoded auction parameter identifier  
        * @return minimumAmount Minimum purchaseToken amount  
    */  
    function minimumPurchase(bytes calldata auctionId) public pure returns (uint256 minimumAmount) {
        (,,, minimumAmount,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    /*  
        * @param auctionId Encoded auction parameter identifier    
        * -----------------------------------------------------------------------------
        * @dev  Active price decay proportional to time delta (t) between the current 
        *       timestamp and the window's start timestamp or if the window is expired;  
        *       the window's expiration. Time remaining (t_r) since the predefined 
        *       timestamp until the auctions conclusion, is subtracted from t and 
        *       applied as modulo to t subject to addition of itself. The resultant is  
        *       divided by t_r to compute elapsed progress (x) from the last timestamp,  
        *       x is multiplied by the origin price (y) and subtracted by y to result  
        *       the decayed price.
        * -----------------------------------------------------------------------------
        * @return Curve price
    */      
    function scalarPrice(bytes calldata auctionId) 
        activeAuction(auctionId)
    public view returns (uint256) {
        Auction storage state = _auctions[auctionId];
        Window storage window = _window[auctionId][_windows[auctionId]];

        uint256 ts = isWindowExpired(auctionId) ? window.expiry : state.windowTimestamp;
        uint256 y = !isWindowInit(auctionId) ? state.price : window.price;

        uint256 t = block.timestamp - ts;
        uint256 t_r = state.duration - elapsedTimeFromWindow(auctionId);

        uint256 t_mod = t % (t_r - t);
        uint256 x = (t + t_mod) * 1e18;        
        uint256 y_x = y * x / t_r;

        return y - y_x / 1e18;
    }

    /*  
        * @dev Bid submission 
        * @param auctionID Encoded auction parameter identifier    
        * @param price Bid order price  
        * @param volume Bid order volume
        * @return bidId Encoded bid parameter indentifier
    */     
    function commitBid(bytes calldata auctionId, uint256 price, uint256 volume) 
        activeAuction(auctionId) 
        nonReentrant
    override external returns (bytes memory bidId) {
        Auction storage state = _auctions[auctionId];
        Window storage window = _window[auctionId][_windows[auctionId]];

        if (volume < minimumPurchase(auctionId)) {
            revert InvalidPurchaseVolume();
        }

        bool hasExpired;

        if (isWindowInit(auctionId)) {
            if (isWindowActive(auctionId)) {
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
            if (price < scalarPrice(auctionId)) {
                revert InvalidScalarPrice();
            }
        }

        uint256 orderVolume = volume - (volume % price);

        if (state.reserves < orderVolume * 1e18 / price) {
            revert InsufficientReserves();
        }
        if (volume < price) {
            revert InvalidReserveVolume();
        }

        bidId = abi.encode(auctionId, msg.sender, price, orderVolume);

        {
            (uint256 refund, uint256 claim) = balancesOf(_claims[msg.sender][auctionId]);

            delete _claims[msg.sender][auctionId];

            _claims[msg.sender][auctionId] = abi.encode(refund + orderVolume, claim);
        }

        if (hasExpired) {
            window = _window[auctionId][windowExpiration(auctionId)];
        } 

        window.expiry = block.timestamp + state.windowDuration;
        window.volume = orderVolume;
        window.price = price;
        window.bidId = bidId;

        state.windowTimestamp = block.timestamp;

        emit Offer(auctionId, msg.sender, bidId, window.expiry);

        purchaseToken(auctionId).safeTransferFrom(msg.sender, address(this), orderVolume);
    }

    /*  
        * @dev Expire and fulfill an auction's active window  
        * @param auctionId Encoded auction parameter identifier
        * @return Next window index 
    */     
    function windowExpiration(bytes calldata auctionId) internal returns (uint256) {
        uint256 windowIndex = _windows[auctionId];

        Auction storage state = _auctions[auctionId];
        Window storage window = _window[auctionId][windowIndex];

        state.endTimestamp = block.timestamp + remainingTime(auctionId);
        state.price = window.price;

        _windows[auctionId] = windowIndex + 1;

        _fulfillWindow(auctionId, windowIndex);

        emit Expiration(auctionId, window.bidId, windowIndex);

        return windowIndex + 1;
    }

    /*  
        * @dev Fulfill a window index for an inactive auction
        * @param auctionId Encoded auction parameter identifier    
    */  
    function fulfillWindow(bytes calldata auctionId, uint256 windowId) 
        inactiveAuction(auctionId)
    override public {    
        _fulfillWindow(auctionId, windowId);
    }

    /*  
        * @dev Fulfill a window index
        * @param auctionId Encoded auction parameter identifier    
    */  
    function _fulfillWindow(bytes calldata auctionId, uint256 windowId) internal {
        Auction storage state = _auctions[auctionId];
        Window storage window = _window[auctionId][windowId];

        if (isWindowActive(auctionId)) {
            revert WindowUnexpired();
        }
        if (window.processed) {
            revert WindowFulfilled();
        }

        (, address bidder, uint256 price, uint256 volume) = bidParameters(window.bidId);
        (uint256 refund, uint256 claim) = balancesOf(_claims[bidder][auctionId]);

        delete _claims[bidder][auctionId];

        window.processed = true;

        uint256 orderAmount = volume * 1e18 / price;

        state.reserves -= orderAmount;
        state.proceeds += volume;

        _claims[bidder][auctionId] = abi.encode(refund - volume, claim + orderAmount);

        emit Fulfillment(auctionId, window.bidId, windowId);
    }

    /*  
        * @dev Helper to view an auction's remaining duration
        * @param auctionId Encoded auction parameter identifier    
        * @return Remaining unix time
    */  
    function remainingTime(bytes calldata auctionId) public view returns (uint256) {
        return _auctions[auctionId].duration - elapsedTime(auctionId);
    }

    /*  
        * @dev Helper to view an auction's active remaining window duration
        * @param auctionId Encoded auction parameter identifier
        * @return Remaining window unix time
    */  
    function remainingWindowTime(bytes calldata auctionId) public view returns (uint256) {
        if (!isWindowActive(auctionId)) {
            return 0;
        } 

        return _window[auctionId][_windows[auctionId]].expiry - block.timestamp; 
    }

    /*  
        * @dev Helper to view an auction's progress in unix time
        * @param auctionId Encoded auction parameter identifier 
        * @return Completed unix time   
    */     
    function elapsedTime(bytes calldata auctionId) public view returns (uint256) {
        return block.timestamp - windowElapsedTime(auctionId) - _auctions[auctionId].startTimestamp;
    }

    /*  
        * @dev Helper to view an auction's total window progress in unix time
        * @param auctionId Encoded auction parameter identifier
        * @return Completed unix time    
    */     
    function windowElapsedTime(bytes calldata auctionId) public view returns (uint256) {
        if (!isWindowInit(auctionId)) {
            return 0;
        }

        uint256 windowIndex = _windows[auctionId];
        uint256 elapsedWindowsTime = _auctions[auctionId].windowDuration * (windowIndex + 1); 

        return elapsedWindowsTime - remainingWindowTime(auctionId);
    }

    /*  
        * @dev Helper to view an auction's progress from a window expiration or start in unix time
        * @param auctionId Encoded auction parameter identifier
        * @return Completed unix time
    */     
    function elapsedTimeFromWindow(bytes calldata auctionId) public view returns (uint256) {
        Auction storage state = _auctions[auctionId];

        uint256 endTimestamp = state.windowTimestamp;

        if (isWindowExpired(auctionId)) {
            endTimestamp = _window[auctionId][_windows[auctionId]].expiry;
        }

        return endTimestamp - windowElapsedTime(auctionId) - state.startTimestamp;
    }

    /*  
        * @dev Auction management redemption 
        * @param auctionId Encoded auction parameter identifier    
    */     
    function withdraw(bytes calldata auctionId) 
        inactiveAuction(auctionId) 
    override external {
        uint256 proceeds = _auctions[auctionId].proceeds;
        uint256 reserves = _auctions[auctionId].reserves;

        delete _auctions[auctionId].proceeds;
        delete _auctions[auctionId].reserves;

        if (proceeds > 0) {
            purchaseToken(auctionId).safeTransfer(operatorAddress(auctionId), proceeds);
        }
        if (reserves > 0) {
            reserveToken(auctionId).safeTransfer(operatorAddress(auctionId), reserves);
        }

        emit Withdraw(auctionId);
    }

    /*  
        * @dev Auction order and refund redemption 
        * @param auctionId Encoded auction parameter identifier    
    */  
    function redeem(address bidder, bytes calldata auctionId)
        inactiveAuction(auctionId) 
    override external {
        bytes memory claimHash = _claims[bidder][auctionId];

        (uint256 refund, uint256 claim) = balancesOf(claimHash);

        delete _claims[bidder][auctionId];

        if (refund > 0) {
            purchaseToken(auctionId).safeTransfer(bidder, refund);
        }
        if (claim > 0) {
            reserveToken(auctionId).safeTransfer(bidder, claim);
        }

        emit Claim(auctionId, claimHash);
    }

}

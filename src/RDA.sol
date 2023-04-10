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
        * @dev Conditioner to ensure an auction is active  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    modifier activeAuction(bytes calldata auctionId) {
        if (remainingWindowTime(auctionId) == 0 && remainingTime(auctionId) == 0) {
            revert AuctionInactive();
        }
        _;
    }

    /*  
        * @dev Conditioner to ensure an auction is inactive  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    modifier inactiveAuction(bytes calldata auctionId) {
        if (remainingWindowTime(auctionId) > 0 || remainingTime(auctionId) > 0) {
            revert AuctionActive();
        }
        _;
    }

    /*  
        * @dev Helper to view an auction's operator address  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return o͟p͟A͟d͟d͟r͟e͟s͟s͟ Auction operator address
    */  
    function operatorAddress(bytes calldata auctionId) public pure returns (address opAddress) {
        (opAddress,,,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    /*  
        * @dev Helper to view an auction's purchase token address  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Ancoded auction parameter identifier
        * @return p͟u͟r͟c͟h͟a͟s͟e͟T͟o͟k͟e͟n͟ Token interface    
    */  
    function purchaseToken(bytes calldata auctionId) public pure returns (IERC20) {
        (,, address tokenAddress,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));

        return IERC20(tokenAddress);
    }

    /*  
        * @dev Helper to view an auction's reserve token address  
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return r͟e͟s͟e͟r͟v͟e͟T͟o͟k͟e͟n͟ Token interface   
    */  
    function reserveToken(bytes calldata auctionId) public pure returns (IERC20) {
        (, address tokenAddress,,,) = abi.decode(auctionId, (address, address, address, uint256, bytes));

        return IERC20(tokenAddress);
    }

    /*  
        * @dev Helper to decode claim hash balances
        * @param c͟l͟a͟i͟m͟H͟a͟s͟h͟ Encoded claim parameter identifer 
        * @return r͟e͟f͟u͟n͟d͟ Account refund balance
        * @return c͟l͟a͟i͟m͟ Account claim balance
    */  
    function balancesOf(bytes memory claimHash) public pure returns (uint256 refund, uint256 claim) {
        if (keccak256(claimHash) != keccak256(bytes(""))) {
            (refund, claim) = abi.decode(claimHash, (uint256, uint256));
        }
    }

    /*  
        * @dev Helper to decode bid identifer parameters
        * @param b͟i͟d͟I͟d͟ Encoded bid parameter indentifier  
        * @return a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return b͟i͟d͟d͟e͟r͟ Order recipient address
        * @return p͟r͟i͟c͟e͟ Order price
        * @return v͟o͟l͟u͟m͟e͟ Order volume
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return i͟s͟W͟i͟n͟d͟o͟w͟I͟n͟i͟t͟ Window state condition
    */  
    function isWindowInit(bytes calldata auctionId) public view returns (bool) {
        return _window[auctionId][_windows[auctionId]].expiry != 0;   
    }

    /*  
        * @dev Helper to query whether the current window is active
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return i͟s͟W͟i͟n͟d͟o͟w͟A͟c͟t͟i͟v͟e͟ Window state condition
    */ 
    function isWindowActive(bytes calldata auctionId) public view returns (bool) {
        Window storage window = _window[auctionId][_windows[auctionId]];

        return isWindowInit(auctionId) && window.expiry > block.timestamp;   
    }

    /*  
        * @dev Helper to query whether the current window is expired
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return i͟s͟W͟i͟n͟d͟o͟w͟E͟x͟p͟i͟r͟e͟d͟ Window state condition
    */ 
    function isWindowExpired(bytes calldata auctionId) public view returns (bool) {
        Window storage window = _window[auctionId][_windows[auctionId]];

        return isWindowInit(auctionId) && window.expiry < block.timestamp;   
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
        * @return a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier 
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier  
        * @return m͟i͟n͟i͟m͟u͟m͟A͟m͟o͟u͟n͟t͟ Minimum purchaseToken amount  
    */  
    function minimumPurchase(bytes calldata auctionId) public pure returns (uint256 minimumAmount) {
        (,,, minimumAmount,) = abi.decode(auctionId, (address, address, address, uint256, bytes));
    }

    /*  
        * @dev Active price decay proportional to time delta (t) between the current 
        * timestamp and the window's start timestamp or if the window is expired;  
        * the window's expiration. Time remaining (t_r) since the predefined 
        * timestamp until the auctions conclusion, is subtracted from t and applied
        * as modulo to t subject to addition of itself. The resultant is divided by t_r 
        * to compute elapsed progress (x) from the last timestamp, x is multipled by 
        * the origin price (y) and subtracted by y to result the decayed price
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
        * @return s͟c͟a͟l͟a͟r͟P͟r͟i͟c͟e͟ Curve price
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
        * @param p͟r͟i͟c͟e͟ Bid order price  
        * @param v͟o͟l͟u͟m͟e͟ Bid order volume
        * @return b͟i͟d͟I͟d͟ Encoded bid parameter indentifier
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return w͟i͟n͟d͟o͟w͟I͟n͟d͟e͟x͟ Next window index 
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
    */  
    function fulfillWindow(bytes calldata auctionId, uint256 windowId) 
        inactiveAuction(auctionId)
    override public {    
        _fulfillWindow(auctionId, windowId);
    }

    /*  
        * @dev Fulfill a window index
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
        * @return r͟e͟m͟a͟i͟n͟i͟n͟g͟T͟i͟m͟e͟ Remaining unix time
    */  
    function remainingTime(bytes calldata auctionId) public view returns (uint256) {
        return _auctions[auctionId].duration - elapsedTime(auctionId);
    }

    /*  
        * @dev Helper to view an auction's active remaining window duration
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return r͟e͟m͟a͟i͟n͟i͟n͟g͟W͟i͟n͟d͟o͟w͟T͟i͟m͟e͟ Remaining window unix time
    */  
    function remainingWindowTime(bytes calldata auctionId) public view returns (uint256) {
        if (!isWindowActive(auctionId)) {
            return 0;
        } 

        return _window[auctionId][_windows[auctionId]].expiry - block.timestamp; 
    }

    /*  
        * @dev Helper to view an auction's progress in unix time
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier 
        * @return e͟l͟a͟p͟s͟e͟d͟T͟i͟m͟e͟ Completed unix time   
    */     
    function elapsedTime(bytes calldata auctionId) public view returns (uint256) {
        return block.timestamp - windowElapsedTime(auctionId) - _auctions[auctionId].startTimestamp;
    }

    /*  
        * @dev Helper to view an auction's total window progress in unix time
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return w͟i͟n͟d͟o͟w͟E͟l͟a͟p͟s͟e͟d͟T͟i͟m͟e͟ Completed unix time    
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier
        * @return e͟l͟a͟p͟s͟e͟d͟T͟i͟m͟e͟F͟r͟o͟m͟W͟i͟n͟d͟o͟w͟ Completed unix time
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
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
        * @param a͟u͟c͟t͟i͟o͟n͟I͟d͟ Encoded auction parameter identifier    
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

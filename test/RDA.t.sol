pragma solidity 0.8.13;

import "@root/RDA.sol";
import "forge-std/Test.sol";

import "./mock/Parameters.sol";
import "./mock/ERC20M.sol";

contract RDATest is Test, Parameters {
    address _auctionAddress;
    address _purchaseToken;
    address _reserveToken;

    bytes _auctionId;

    function setUp() public {
        vm.deal(TEST_ADDRESS_ONE, 1 ether);
        vm.deal(TEST_ADDRESS_TWO, 1 ether);

        _auctionAddress = address(new RDA());
        _reserveToken = address(new ERC20M("COIN", "COIN"));
        _purchaseToken = address(new ERC20M("WETH", "WETH"));

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);

            ERC20M(_purchaseToken).mint(1 ether);
            ERC20M(_reserveToken).mint(AUCTION_RESERVES);
            _auctionId = createAuction();

            vm.stopPrank();
        /* --------------------------------- *

        /* -------------BIDDER-------------- */
            vm.startPrank(TEST_ADDRESS_TWO);
            ERC20M(_purchaseToken).mint(100 ether);
            vm.stopPrank();
        /* --------------------------------- */
    }

    function testAuctionIdDecoding() public {
        require(RDA(_auctionAddress).operatorAddress(_auctionId) == TEST_ADDRESS_ONE);
        require(RDA(_auctionAddress).purchaseToken(_auctionId) == _purchaseToken);
        require(RDA(_auctionAddress).reserveToken(_auctionId) == _reserveToken);
        require(RDA(_auctionAddress).minimumPurchase(_auctionId) == AUCTION_MINIMUM_PURCHASE);
    }

    function testBidIdDecoding() public {
        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);

            uint256 scalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

            bytes memory bidId = createBid(scalarPrice);

            (bytes memory auctionId, address biddingAddress, uint256 price, uint256 volume) = abi.decode(bidId, (bytes, address, uint256, uint256));

            require(keccak256(auctionId) == keccak256(_auctionId));
            require(biddingAddress == TEST_ADDRESS_TWO);
            require(price == scalarPrice);
            require(volume == 1 ether);

            vm.stopPrank();
        /* --------------------------------- */
    }

    function testScalarPrice() public {
        vm.warp(block.timestamp + 6 days + 23 hours + 30 minutes);

        uint256 scalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

        require(scalarPrice == 14039523809524);

        /* -------------BIDDER-------------- */
            vm.startPrank(TEST_ADDRESS_TWO);
            bytes memory bidId = createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        vm.warp(block.timestamp + AUCTION_WINDOW_DURATION + 20 minutes);

        uint256 windowScalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

        require(windowScalarPrice == 4679841269842);
    }

    function testElapsedTime() public {
        vm.warp(block.timestamp + 1 days);

        uint256 scalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

        /* -------------BIDDER-------------- */
            vm.startPrank(TEST_ADDRESS_TWO);
            bytes memory bidId = createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

         vm.warp(block.timestamp + AUCTION_WINDOW_DURATION);

         uint256 remainingTime = RDA(_auctionAddress).elapsedTime(_auctionId, block.timestamp);

         require(remainingTime == 1 days);
    }

    function testRemainingTime() public {
        uint256 remainingTime = RDA(_auctionAddress).remainingTime(_auctionId);
        uint256 elapsedTime = 3 hours + 14 minutes + 45 seconds;

        require(remainingTime == 7 days);

        vm.warp(block.timestamp + elapsedTime);

        uint256 scalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

        /* -------------BIDDER-------------- */
            vm.startPrank(TEST_ADDRESS_TWO);
            bytes memory bidId = createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        uint256 elapsedWindowTime = 39 minutes + 7 seconds;

        vm.warp(block.timestamp + elapsedWindowTime);

        uint256 remainingWindowTime = RDA(_auctionAddress).remainingWindowTime(_auctionId);

        require(remainingWindowTime == AUCTION_WINDOW_DURATION - elapsedWindowTime);

        vm.warp(block.timestamp + remainingWindowTime);

        uint256 finalWindowTime = RDA(_auctionAddress).remainingWindowTime(_auctionId);

        require(finalWindowTime == 0);

        uint256 newScalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

        /* -------------BIDDER-------------- */
            vm.startPrank(TEST_ADDRESS_TWO);
            bidId = createBid(newScalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        uint256 finalRemainingTime = RDA(_auctionAddress).remainingTime(_auctionId);

        require(finalRemainingTime == AUCTION_DURATION - elapsedTime);
    }


    function testWindowExpiry() public {
        vm.warp(block.timestamp + 33 minutes);

        uint256 scalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);
        uint256 initialRemainingTime = RDA(_auctionAddress).remainingTime(_auctionId);

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        require(RDA(_auctionAddress).remainingWindowTime(_auctionId) == AUCTION_WINDOW_DURATION);

        vm.warp(block.timestamp + 1 hours);

        require(RDA(_auctionAddress).remainingWindowTime(_auctionId) == AUCTION_WINDOW_DURATION - 1 hours);

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            createBid(scalarPrice + 1);
            vm.stopPrank();
        /* --------------------------------- */

        vm.warp(block.timestamp + AUCTION_WINDOW_DURATION);

        require(RDA(_auctionAddress).remainingWindowTime(_auctionId) == 0);

        vm.warp(block.timestamp + 1 minutes);

        uint256 nextScalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

        (, uint256 expiryTimestamp,,,) = RDA(_auctionAddress)._window(_auctionId, 0);
        (, uint256 windowTimestamp,,,,,,) = RDA(_auctionAddress)._auctions(_auctionId);
        uint256 elapsedWindowTimestamp = expiryTimestamp - windowTimestamp;
        uint256 elapsedExpiryTimestamp = block.timestamp - expiryTimestamp;

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(nextScalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        vm.warp(block.timestamp + AUCTION_WINDOW_DURATION);

        uint256 newRemainingTime = RDA(_auctionAddress).remainingTime(_auctionId);
        uint256 remainingMinusElapsedTime = initialRemainingTime - elapsedExpiryTimestamp - AUCTION_WINDOW_DURATION - 1 hours;

        require(remainingMinusElapsedTime == newRemainingTime);
    }   

    function testCommitBid() public {
        vm.warp(block.timestamp + 10 minutes);
        
        uint256 scalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */
    }

    function testClaimAndWithdraw() public {
        vm.warp(block.timestamp + 1 minutes);

        uint256 scalarPrice = RDA(_auctionAddress).scalarPriceUint(_auctionId);

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            createBid(scalarPrice + 1);
            vm.stopPrank();
        /* --------------------------------- */

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(scalarPrice + 2);
            vm.stopPrank();
        /* --------------------------------- */
        
        vm.warp(block.timestamp + AUCTION_DURATION + AUCTION_WINDOW_DURATION + 1 hours);

        RDA(_auctionAddress).fulfillWindow(_auctionId, 0);

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            RDA(_auctionAddress).redeem(TEST_ADDRESS_TWO, _auctionId);
            vm.stopPrank();
        /* --------------------------------- */

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            RDA(_auctionAddress).redeem(TEST_ADDRESS_ONE, _auctionId);
            RDA(_auctionAddress).withdraw(_auctionId);
            vm.stopPrank();
        /* --------------------------------- */

        uint256 operatorPTokenBalance = ERC20(_purchaseToken).balanceOf(TEST_ADDRESS_ONE);
        uint256 operatorRTokenBalance = ERC20(_reserveToken).balanceOf(TEST_ADDRESS_ONE);
        uint256 bidderPTokenBalance = ERC20(_purchaseToken).balanceOf(TEST_ADDRESS_TWO);
        uint256 bidderRTokenBalance = ERC20(_reserveToken).balanceOf(TEST_ADDRESS_TWO);
        uint256 remainingReserves = AUCTION_RESERVES - (1 ether / (scalarPrice + 2));

        require(bidderRTokenBalance == 1 ether / (scalarPrice + 2));
        require(operatorRTokenBalance == remainingReserves);
        require(operatorPTokenBalance == 2 ether);
        require(bidderPTokenBalance == 99 ether);
    }

    function createAuction() public returns (bytes memory) {
        ERC20(_reserveToken).approve(_auctionAddress, AUCTION_RESERVES);

        return RDA(_auctionAddress).createAuction(
            TEST_ADDRESS_ONE,
            _reserveToken,
            _purchaseToken,
            AUCTION_RESERVES,
            AUCTION_MINIMUM_PURCHASE,
            AUCTION_ORIGIN_PRICE,
            block.timestamp,
            block.timestamp + AUCTION_DURATION,
            AUCTION_WINDOW_DURATION
        );
    }

    function createBid(uint256 price) public returns (bytes memory) {
        ERC20(_purchaseToken).approve(_auctionAddress, 1 ether);

        return RDA(_auctionAddress).commitBid(_auctionId, price, 1 ether);
    }

}
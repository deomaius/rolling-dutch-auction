pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "./mock/Parameters.sol";
import "./mock/ERC20.sol";

import "@root/RollingDutchAuction.sol";

contract RollingDutchAuctionTest is Test, Parameters {
    address _auctionAddress;
    address _purchaseToken;
    address _reserveToken;

    bytes _auctionId;

    function setUp() public {
        vm.deal(TEST_ADDRESS_ONE, 1 ether);
        vm.deal(TEST_ADDRESS_TWO, 1 ether);

        _auctionAddress = address(new RollingDutchAuction());
        _reserveToken = address(new ERC20("COIN", "COIN", 18));
        _purchaseToken = address(new ERC20("WETH", "WETH", 18));

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);

            ERC20(_purchaseToken).mint(1 ether);
            ERC20(_reserveToken).mint(AUCTION_RESERVES);
            _auctionId = createAuction();

            vm.stopPrank();
        /* --------------------------------- *

        /* -------------BIDDER-------------- */
            vm.startPrank(TEST_ADDRESS_TWO);
            ERC20(_purchaseToken).mint(100 ether);
            vm.stopPrank();
        /* --------------------------------- */
    }

    function testAuctionIdDecoding() public {
        require(RollingDutchAuction(_auctionAddress).operatorAddress(_auctionId) == TEST_ADDRESS_ONE);
        require(RollingDutchAuction(_auctionAddress).purchaseToken(_auctionId) == _purchaseToken);
        require(RollingDutchAuction(_auctionAddress).reserveToken(_auctionId) == _reserveToken);
        require(RollingDutchAuction(_auctionAddress).minimumPurchase(_auctionId) == AUCTION_MINIMUM_PURCHASE);
    }

    function testBidIdDecoding() public {
        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);

            uint256 scalarPrice = RollingDutchAuction(_auctionAddress).getScalarPriceUint(_auctionId);

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
        uint256 startPrice = RollingDutchAuction(_auctionAddress).getScalarPriceUint(_auctionId);

        vm.warp(block.timestamp + 6 days + 23 hours + 30 minutes);

        uint256 finishPrice = RollingDutchAuction(_auctionAddress).getScalarPriceUint(_auctionId);

        require(startPrice > (finishPrice * 10));
    }

    function testWindowExpiry() public {
        vm.warp(block.timestamp + 33 minutes);

        uint256 scalarPrice = RollingDutchAuction(_auctionAddress).getScalarPriceUint(_auctionId);
        uint256 initialRemainingTime = RollingDutchAuction(_auctionAddress).remainingTime(_auctionId);

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        require(RollingDutchAuction(_auctionAddress).remainingWindowTime(_auctionId) == AUCTION_WINDOW_DURATION);

        vm.warp(block.timestamp + 1 hours);

        require(RollingDutchAuction(_auctionAddress).remainingWindowTime(_auctionId) == AUCTION_WINDOW_DURATION - 1 hours);

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            createBid(scalarPrice + 1);
            vm.stopPrank();
        /* --------------------------------- */

        vm.warp(block.timestamp + AUCTION_WINDOW_DURATION);

        require(RollingDutchAuction(_auctionAddress).remainingWindowTime(_auctionId) == 0);

        vm.warp(block.timestamp + 1 minutes);

        uint256 nextScalarPrice = RollingDutchAuction(_auctionAddress).getScalarPriceUint(_auctionId);

        (uint256 expiryTimestamp, , , , ) = RollingDutchAuction(_auctionAddress)._window(_auctionId, 0);
        (, , , uint256 windowTimestamp, , , ,) = RollingDutchAuction(_auctionAddress)._auctions(_auctionId);
        uint256 elapsedWindowTimestamp = expiryTimestamp - windowTimestamp;
        uint256 elapsedExpiryTimestamp = block.timestamp - expiryTimestamp;

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(nextScalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        vm.warp(block.timestamp + AUCTION_WINDOW_DURATION);

        uint256 newRemainingTime = RollingDutchAuction(_auctionAddress).remainingTime(_auctionId);
        uint256 initialRemainingMinusElapsedTime = initialRemainingTime - elapsedExpiryTimestamp - AUCTION_WINDOW_DURATION - 1 hours;

        require(initialRemainingMinusElapsedTime == newRemainingTime);
    }   

    function testCommitBid() public {
        vm.warp(block.timestamp + 10 minutes);
        
        uint256 scalarPrice = RollingDutchAuction(_auctionAddress).getScalarPriceUint(_auctionId);

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        vm.warp(block.timestamp + 1 hours);

       /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            createBid(scalarPrice + 1);
            vm.stopPrank();
        /* --------------------------------- */

        uint256 newScalarPrice = RollingDutchAuction(_auctionAddress).getScalarPriceUint(_auctionId);

        require(newScalarPrice == scalarPrice + 1);
    }

    function testClaimAndWithdraw() public {
        vm.warp(block.timestamp + 1 minutes);

        uint256 scalarPrice = RollingDutchAuction(_auctionAddress).getScalarPriceUint(_auctionId);

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

        RollingDutchAuction(_auctionAddress).fufillWindow(_auctionId, 0);

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            RollingDutchAuction(_auctionAddress).claim(TEST_ADDRESS_TWO, _auctionId);
            vm.stopPrank();
        /* --------------------------------- */

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            RollingDutchAuction(_auctionAddress).claim(TEST_ADDRESS_ONE, _auctionId);
            RollingDutchAuction(_auctionAddress).withdraw(_auctionId);
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

        return RollingDutchAuction(_auctionAddress).createAuction(
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

        return RollingDutchAuction(_auctionAddress).commitBid(_auctionId, price, 1 ether);
    }

}

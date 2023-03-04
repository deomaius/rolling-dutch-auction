pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "./mock/Parameters.sol";
import "./mock/ERC20.sol";

import "@root/RollingDutchAuction.sol";

contract RollingDutchAuctionTest is Test, Parameters {
    address auctionAddress;
    address purchaseToken;
    address reserveToken;

    bytes auctionId;

    function setUp() public {
        vm.deal(TEST_ADDRESS_ONE, 1 ether);
        vm.deal(TEST_ADDRESS_TWO, 1 ether);

        auctionAddress = address(new RollingDutchAuction());
        reserveToken = address(new ERC20("COIN", "COIN", 18));
        purchaseToken = address(new ERC20("WETH", "WETH", 18));

        /* -------------OPERATOR------------ */
        vm.startPrank(TEST_ADDRESS_ONE);

        ERC20(purchaseToken).mint(1 ether);
        ERC20(reserveToken).mint(AUCTION_RESERVES);
        auctionId = createAuction();

        vm.stopPrank();
        /* --------------------------------- *

        /* -------------BIDDER-------------- */
        vm.startPrank(TEST_ADDRESS_TWO);
        ERC20(purchaseToken).mint(100 ether);
        vm.stopPrank();
        /* --------------------------------- */
    }

    function createAuction() public returns (bytes memory) {
        ERC20(reserveToken).approve(auctionAddress, AUCTION_RESERVES);

        return RollingDutchAuction(auctionAddress).createAuction(
            TEST_ADDRESS_ONE,
            reserveToken,
            purchaseToken,
            AUCTION_RESERVES,
            AUCTION_ORIGIN_PRICE,
            block.timestamp,
            block.timestamp + AUCTION_DURATION,
            AUCTION_WINDOW_DURATION
        );
    }

    function testAuctionIdDecoding() public {
        require(RollingDutchAuction(auctionAddress).operatorAddress(auctionId) == TEST_ADDRESS_ONE);
        require(RollingDutchAuction(auctionAddress).purchaseToken(auctionId) == purchaseToken);
        require(RollingDutchAuction(auctionAddress).reserveToken(auctionId) == reserveToken);
    }

    function testScalarPrice() public {
        uint256 startPrice = RollingDutchAuction(auctionAddress).getScalarPriceUint(auctionId);

        vm.warp(block.timestamp + 6 days + 23 hours + 30 minutes);

        uint256 finishPrice = RollingDutchAuction(auctionAddress).getScalarPriceUint(auctionId);

        require(startPrice > (finishPrice * 10));
    }

    function testWindowExpiry() public {
        vm.warp(block.timestamp + 33 minutes);

        uint256 scalarPrice = RollingDutchAuction(auctionAddress).getScalarPriceUint(auctionId);
        uint256 initialRemainingTime = RollingDutchAuction(auctionAddress).remainingTime(auctionId);

        /* -------------BIDDER------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(scalarPrice);
            vm.stopPrank();
        /* --------------------------------- */

        require(RollingDutchAuction(auctionAddress).remainingWindowTime(auctionId) == AUCTION_WINDOW_DURATION);

        vm.warp(block.timestamp + 1 hours);

        require(RollingDutchAuction(auctionAddress).remainingWindowTime(auctionId) == AUCTION_WINDOW_DURATION - 1 hours);

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            createBid(scalarPrice + 1);
            vm.stopPrank();
        /* --------------------------------- */

        vm.warp(block.timestamp + AUCTION_WINDOW_DURATION);

        require(RollingDutchAuction(auctionAddress).remainingWindowTime(auctionId) == 0);

        vm.warp(block.timestamp + 1 minutes);

        uint256 nextScalarPrice = RollingDutchAuction(auctionAddress).getScalarPriceUint(auctionId);

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_TWO);
            createBid(nextScalarPrice);
            vm.stopPrank();
        /* --------------------------------- */
    }   

    function testCommitBid() public {
        vm.warp(block.timestamp + 10 minutes);
        
        uint256 scalarPrice = RollingDutchAuction(auctionAddress).getScalarPriceUint(auctionId);

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
    }

    function createBid(uint256 price) public {
        ERC20(purchaseToken).approve(auctionAddress, 1 ether);
        RollingDutchAuction(auctionAddress).commitBid(auctionId, price, 1 ether);
    }

}

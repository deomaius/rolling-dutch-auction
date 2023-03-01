pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "./mock/Parameters.sol";
import "./mock/ERC20.sol";

import "../src/RollingDutchAuction.sol";

contract RollingDutchAuctionTest is Test, Parameters {

    address auctionAddress;
    address purchaseToken;
    address reserveToken;

    bytes auctionId;

    uint256 auctionIndex;

    function setUp() public {
        vm.deal(TEST_ADDRESS_ONE, 1 ether);
        vm.deal(TEST_ADDRESS_TWO, 1 ether);

        auctionAddress = address(new RollingDutchAuction());
        reserveToken = address(new ERC20("COIN", "COIN", 18));
        purchaseToken = address(new ERC20("WETH", "WETH", 18));

        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            ERC20(reserveToken).mint(AUCTION_RESERVES);
            vm.stopPrank();
        /* --------------------------------- *

        /* -------------BIDDER-------------- */
            vm.startPrank(TEST_ADDRESS_TWO);
            ERC20(purchaseToken).mint(100 ether);
            vm.stopPrank();
        /* --------------------------------- */

        auctionId = abi.encodePacked(
            TEST_ADDRESS_ONE,
            reserveToken,
            purchaseToken,
            AUCTION_RESERVES,
            AUCTION_ORIGIN_PRICE,
            block.timestamp,
            block.timestamp + AUCTION_DURATION,
            AUCTION_WINDOW_DURATION,
            auctionIndex
        );  
    }

    function testAuctionCreation() public {
        /* -------------OPERATOR------------ */
            vm.startPrank(TEST_ADDRESS_ONE);
            ERC20(reserveToken).transfer(address(this), AUCTION_RESERVES);
            vm.stopPrank();
        /* --------------------------------- */

        ERC20(reserveToken).approve(auctionAddress, AUCTION_RESERVES);
        RollingDutchAuction(auctionAddress).createAuction(
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

    function testCommitOffer() public {}

    function testCommitBid() public {}

    function testWindowfufilliment() public {}

    function testWithdraw() public {}

    function testClaim() public {}

}

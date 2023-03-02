pragma solidity ^0.8.1;

contract Parameters { 

	uint256 constant TEST_PRIVATE_KEY_ONE = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
	uint256 constant TEST_PRIVATE_KEY_TWO = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
	address constant TEST_ADDRESS_ONE = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
	address constant TEST_ADDRESS_TWO = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

	uint256 constant AUCTION_DURATION = 7 days;
	uint256 constant AUCTION_WINDOW_DURATION = 2 hours;
	uint256 constant AUCTION_ORIGIN_PRICE = 10000 gwei;
	uint256 constant AUCTION_RESERVES = 100000 ether;

}
pragma solidity ^0.8.13;

interface IERC20 {
	
	function transferFrom(address from, address to, uint256 amount) external;

	function transfer(address to, uint256 amount) external;

}
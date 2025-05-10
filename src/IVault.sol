// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IVault {
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner, uint256 minAssets) external returns (uint256 assets);

    function balanceOf(address account) external view returns (uint256);

    function sharePrice() external view returns (uint256);

    function asset() external view returns (address);

    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice Minimal WBNB interface used by the vault to wrap native BNB before swapping.
interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

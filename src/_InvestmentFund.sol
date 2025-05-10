// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract InvestmentFund {
    IERC20 public immutable token;
    address public owner;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    constructor(address _token) {
        token = IERC20(_token);
        owner = msg.sender;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");

        // Получить текущий пул токенов (до перевода)
        uint256 pool = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 newShares;
        if (totalShares == 0 || pool == 0) {
            // Первому вкладчику просто выдаём 1:1
            newShares = amount;
        } else {
            newShares = (amount * totalShares) / pool;
        }

        shares[msg.sender] += newShares;
        totalShares += newShares;
    }

    function withdraw(uint256 shareAmount) external {
        require(shareAmount > 0, "Invalid share amount");
        require(shares[msg.sender] >= shareAmount, "Not enough shares");

        uint256 pool = token.balanceOf(address(this));
        uint256 amountToWithdraw = (shareAmount * pool) / totalShares;

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        require(token.transfer(msg.sender, amountToWithdraw), "Transfer failed");
    }

    function balanceOf(address investor) external view returns (uint256) {
        return shares[investor];
    }

    function sharePrice() external view returns (uint256) {
        uint256 pool = token.balanceOf(address(this));
        if (totalShares == 0) {
            return 1000000; 
        }
        return 1000000 * pool / totalShares;
    }
}

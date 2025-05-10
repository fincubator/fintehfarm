// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal ERC20 interface for balance management
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Interface for the xTokens precompile (used for cross-chain transfers via XCM)
interface IXTokens {
    function transfer(
        address token,
        uint256 amount,
        bytes calldata dest,
        uint64 weight
    ) external;
}

/// @title InvestFundSecondChain
/// @notice Contract to receive funds from one parachain and send them back via XCM
/// @dev Deploy this on the destination parachain (e.g., Astar), not the origin (e.g., Westend EVM)
contract InvestFundSecondChain {
    address public owner;
    IERC20 public token;

    /// @notice Emitted when funds are received via XCM (optional event)
    event ReceivedFromXCM(address indexed token, uint256 amount);

    /// @notice Emitted when funds are returned to origin chain
    event ReturnedToOrigin(address indexed toChain, uint256 amount);

    /// @dev Ensures only contract owner can call sensitive functions
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /// @param _token ERC20 token that will be managed via XCM
    constructor(address _token) {
        owner = msg.sender;
        token = IERC20(_token);
    }

    /// @notice Optional method to log receipt of funds (can be called after XCM transfer completes)
    function onXcmReceived() external {
        uint256 balance = token.balanceOf(address(this));
        emit ReceivedFromXCM(address(token), balance);
    }

    /// @notice Returns tokens back to original chain using xTokens
    /// @param destination SCALE-encoded `Multilocation` to define where the funds go
    ///        Example: `hex"010100000004000000"` means:
    ///        - `parents = 1` (go to relay chain)
    ///        - `interior = Parachain(1024)` (Westend EVM parachain)
    /// @param amount Amount of tokens to send
    /// @param weight Execution weight of the XCM message (e.g. 500_000_000 gas units)
    function returnFunds(
        bytes calldata destination,
        uint256 amount,
        uint64 weight
    ) external onlyOwner {
        require(token.balanceOf(address(this)) >= amount, "Insufficient balance");

        // Approve the xTokens precompile to transfer tokens
        // 0x000...0817 is a fixed address of the xTokens precompile on EVM-compatible parachains
        token.approve(0x0000000000000000000000000000000000000817, amount);

        // Send tokens back via XCM
        IXTokens(0x0000000000000000000000000000000000000817).transfer(
            address(token),
            amount,
            destination,
            weight
        );

        emit ReturnedToOrigin(msg.sender, amount);
    }

    /// @notice Emergency function to withdraw tokens to a specific address
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        require(token.transfer(to, amount), "Transfer failed");
    }

    /// @notice Returns current token balance of the contract
    function balance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

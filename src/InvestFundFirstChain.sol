// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal ERC20 interface for balance management
interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
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

/// @title InvestFundFirstChain
/// @notice Investment Fund Contract deployed on the first parachain (e.g., Westend EVM)
/// @dev This contract allows users to deposit funds, invest them via XCM, and later withdraw funds.
contract InvestFundFirstChain {
    IERC20 public immutable token;
    IXTokens public immutable xTokens;
    address public owner;

    uint256 public totalShares;
    mapping(address => uint256) public shares;
    
    // Destination multilocation of second parachain (in SCALE codec format)
    bytes public constant DESTINATION_MULTILOCATION = hex"010100000004000000";
    
    // Estimated weight for XCM message execution on the destination chain
    uint64 public constant XCM_WEIGHT = 500_000_000;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /// @notice Contract constructor to initialize the token and owner
    /// @param _token The ERC20 token used for deposits and withdrawals
    constructor(address _token) {
        token = IERC20(_token);
        owner = msg.sender;
    }

    /// @notice Deposit funds into the investment fund and issue corresponding shares
    /// @param amount The amount of tokens to deposit
    /// @dev The contract calculates the share issuance based on the proportion of tokens in the fund.
    /// It also sends the tokens to another parachain using XCM (via precompile xTokens).
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");

        // Get the current pool balance before deposit
        uint256 pool = token.balanceOf(address(this));

        // Transfer tokens from user to contract
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // Calculate the number of shares to issue based on the deposit
        uint256 newShares;
        if (totalShares == 0 || pool == 0) {
            // First user simply gets 1:1 ratio of shares
            newShares = amount;
        } else {
            // Subsequent users get shares proportional to the total pool size
            newShares = (amount * totalShares) / pool;
        }

        shares[msg.sender] += newShares;
        totalShares += newShares;

        // Approve the xTokens precompile to transfer tokens
        // 0x000...0817 is the precompile address for xTokens on EVM-compatible parachains
        token.approve(0x0000000000000000000000000000000000000817, amount);

        // Send tokens to another parachain using XCM
        IXTokens(0x0000000000000000000000000000000000000817).transfer(
            address(token),
            amount,
            hex"010100000004000000", // Example: parents=1; parachain=1024 (Westend EVM)
            500_000_000            // Estimated weight for XCM execution
        );
    }

    /// @notice Request a withdrawal by submitting the amount of shares to be withdrawn
    /// @param shareAmount The number of shares to be withdrawn
    /// @dev Sends an XCM message to the second chain to return corresponding tokens
    function requestWithdraw(uint256 shareAmount) external {
        require(shareAmount > 0, "Invalid share amount");
        require(shares[msg.sender] >= shareAmount, "Not enough shares");
        require(!withdrawalRequests[msg.sender].pending, "Already pending");

        uint256 pool = token.balanceOf(address(this));
        uint256 amountToWithdraw = (shareAmount * pool) / totalShares;

        // Store withdrawal request
        withdrawalRequests[msg.sender] = WithdrawalRequest({
            shares: shareAmount,
            pending: true
        });

        // Send XCM transfer request to the second parachain
        xTokens.transfer(
            address(token),
            amountToWithdraw,
            DESTINATION_MULTILOCATION,
            XCM_WEIGHT
        );
    }

    /// @notice Fulfills a withdrawal request by transferring the calculated amount back to the investor
    /// @param investor The address of the investor requesting the withdrawal
    /// @dev This method calculates the amount based on the investor's share and sends the corresponding amount.
    function fulfillWithdraw(address investor) external onlyOwner {
        WithdrawalRequest storage request = withdrawalRequests[investor];
        require(request.pending, "No pending withdrawal");

        uint256 pool = token.balanceOf(address(this));
        uint256 amountToWithdraw = (request.shares * pool) / totalShares;

        shares[investor] -= request.shares;
        totalShares -= request.shares;
        delete withdrawalRequests[investor];

        // Transfer the calculated amount to the investor
        require(token.transfer(investor, amountToWithdraw), "Transfer failed");
    }

    /// @notice Cross-chain withdrawal: send funds back to another parachain via XCM
    /// @param destination The destination Multilocation (SCALE-encoded format) where the funds will be sent
    /// @param amount The amount of tokens to send back
    /// @param weight The XCM execution weight (estimated gas required for the operation)
    /// @dev This method uses the xTokens precompile to send tokens back to the destination chain
    function xcmWithdrawBack(
        address tokenToSend,
        uint256 amount,
        bytes calldata destination,
        uint64 weight
    ) external onlyOwner {
        // Approve the xTokens precompile to transfer the tokens
        token.approve(0x0000000000000000000000000000000000000817, amount);

        // Send tokens back via XCM to the destination parachain
        IXTokens(0x0000000000000000000000000000000000000817).transfer(
            tokenToSend,
            amount,
            destination, // SCALE-encoded Multilocation (e.g., to Westend EVM)
            weight       // Required XCM execution weight
        );
    }

    /// @notice Emergency withdrawal of tokens to a specific address
    /// @param to The address to send the tokens to
    /// @param amount The amount of tokens to withdraw
    /// @dev This method allows the owner to withdraw funds from the contract in case of an emergency
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        require(token.transfer(to, amount), "Transfer failed");
    }

    /// @notice Returns the current balance of tokens in the contract
    /// @return The current token balance in the contract
    function balance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    // Private struct to hold the withdrawal request details
    struct WithdrawalRequest {
        uint256 shares;
        bool pending;
    }

    // Mapping to store withdrawal requests by investor address
    mapping(address => WithdrawalRequest) public withdrawalRequests;
}

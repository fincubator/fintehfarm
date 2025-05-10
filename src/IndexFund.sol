// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.26;

import {IVault} from "./interfaces/IVault.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BaseVault} from "./BaseVault.sol";

/**
 * @title IndexFund
 * @notice A simplified index fund managing investments in multiple lending pools.
 */
contract IndexFund is BaseVault {
    using SafeERC20 for IERC20Metadata;
    using EnumerableSet for EnumerableSet.AddressSet;

    error InvalidPoolAddress();
    error ArraysLengthMismatch();
    error NoAvailablePools();

    event LendingPoolAdded(address indexed poolAddress);
    event LendingPoolRemoved(address indexed poolAddress);
    event LendingPoolUpdated(address indexed poolAddress, uint256 newLendingShare);

    uint256 public constant maxPools = 1000;

    mapping(address => uint256) public lendingShares;
    EnumerableSet.AddressSet private lendingPoolAddresses;
    uint256 public totalLendingShares;

    uint256 public depositFeeBps;
    address public feeRecipient;

    constructor(IERC20Metadata _asset, address _feeRecipient, uint256 _depositFeeBps)
        BaseVault(_asset)
    {
        require(_depositFeeBps <= 10_000, "Fee too high");
        feeRecipient = _feeRecipient;
        depositFeeBps = _depositFeeBps;
        _disableInitializers();
    }

    function initialize(address admin, string memory name, string memory symbol) public initializer {
        __ERC20_init(name, symbol);
        __BaseVault_init(admin);
    }


    function deposit(uint256 assets) public {
        require(assets > 0, "Zero deposit");

        uint256 fee = (assets * depositFeeBps) / 10_000;
        uint256 netAssets = assets - fee;

        if (fee > 0) {
            asset.safeTransferFrom(msg.sender, feeRecipient, fee);
        }

        asset.safeTransferFrom(msg.sender, address(this), netAssets);

        uint256 remainingAssets = netAssets;
        uint256 remainingShares = totalLendingShares;

        for (uint256 i = 0; i < lendingPoolAddresses.length(); i++) {
            address poolAddress = lendingPoolAddresses.at(i);
            remainingShares -= lendingShares[poolAddress];

            uint256 amountToDeposit;
            if (remainingShares == 0) {
                amountToDeposit = remainingAssets;
            } else {
                amountToDeposit = (netAssets * lendingShares[poolAddress]) / totalLendingShares;
            }

            remainingAssets -= amountToDeposit;

            if (amountToDeposit > 0) {
                IVault(poolAddress).deposit(amountToDeposit, address(this), 0);
            }

            if (remainingAssets == 0) {
                break;
            }
        }
    }

    function redeem(uint256 shares) public returns (uint256 assets) {
        uint256 senderBalance = balanceOf(msg.sender);
        require(senderBalance >= shares, "Insufficient shares");

        if (lendingPoolAddresses.length() == 0) {
            revert NoAvailablePools();
        }

        for (uint256 i = 0; i < lendingPoolAddresses.length(); i++) {
            address pool = lendingPoolAddresses.at(i);
            uint256 poolBalance = IVault(pool).balanceOf(address(this));

            uint256 poolShareToRedeem = (shares * poolBalance) / totalSupply();
            if (poolShareToRedeem > 0) {
                uint256 redeemed = IVault(pool).redeem(poolShareToRedeem, address(this), address(this), 0);
                assets = assets + redeemed;
            }
        }

        require(assets > 0, "Nothing to redeem");
    }

    function setDepositFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeBps <= 10_000, "Fee too high");
        depositFeeBps = newFeeBps;
    }

    function addLendingPools(address[] memory poolAddresses) public onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            if (lendingPoolAddresses.add(poolAddresses[i])) {
                IERC20Metadata(IVault(poolAddresses[i]).asset()).forceApprove(poolAddresses[i], type(uint256).max);
                emit LendingPoolAdded(poolAddresses[i]);
            }
        }
    }

    function removeLendingPools(address[] memory poolAddresses) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            totalLendingShares -= lendingShares[poolAddresses[i]];
            delete lendingShares[poolAddresses[i]];
            require(lendingPoolAddresses.remove(poolAddresses[i]));
            IERC20Metadata(IVault(poolAddresses[i]).asset()).forceApprove(poolAddresses[i], 0);
            emit LendingPoolRemoved(poolAddresses[i]);
        }
    }

    function setLendingShares(address[] memory poolAddresses, uint256[] memory newLendingShares)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (poolAddresses.length != newLendingShares.length) revert ArraysLengthMismatch();
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            if (!lendingPoolAddresses.contains(poolAddresses[i])) revert InvalidPoolAddress();
            totalLendingShares = totalLendingShares - lendingShares[poolAddresses[i]] + newLendingShares[i];
            lendingShares[poolAddresses[i]] = newLendingShares[i];
            emit LendingPoolUpdated(poolAddresses[i], newLendingShares[i]);
        }
    }

    function rebalanceAuto() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 totalAssetsToRedistribute;
        uint256 totalAssetsToDeposit;
        address[maxPools] memory poolsToDeposit;
        uint256[maxPools] memory amountsToDeposit;
        uint256 count;

        for (uint256 i = 0; i < lendingPoolAddresses.length(); i++) {
            address pool = lendingPoolAddresses.at(i);
            uint256 poolBalance = _getBalance(pool);
            int256 deviation = int256(poolBalance) - int256(totalAssets() * lendingShares[pool] / totalLendingShares);

            if (deviation > 0) {
                uint256 redeemedAmount = IVault(pool).redeem(
                    uint256(deviation) * IVault(pool).balanceOf(address(this)) / poolBalance,
                    address(this),
                    address(this),
                    0
                );
                totalAssetsToRedistribute += redeemedAmount;
            } else if (deviation < 0) {
                poolsToDeposit[count] = pool;
                amountsToDeposit[count] = uint256(-deviation);
                totalAssetsToDeposit += uint256(-deviation);
                count++;
            }
        }

        uint256 leftAssets = totalAssetsToRedistribute;
        for (uint256 i = 0; i < count; i++) {
            uint256 depositAmount = (amountsToDeposit[i] * totalAssetsToRedistribute) / totalAssetsToDeposit;
            if (depositAmount > 0) {
                leftAssets -= depositAmount;
                IVault(poolsToDeposit[i]).deposit(depositAmount, address(this), 0);
            }
        }

        if (leftAssets > 0) {
            IVault(poolsToDeposit[count - 1]).deposit(leftAssets, address(this), 0);
        }
    }

    function getSharePriceOfPool(address pool) external view returns (uint256) {
        return IVault(pool).sharePrice();
    }

    function getBalanceOfPool(address pool) external view returns (uint256) {
        return _getBalance(pool);
    }

    function getPools() external view returns (address[] memory) {
        return lendingPoolAddresses.values();
    }

    function getLendingPoolCount() external view returns (uint256) {
        return lendingPoolAddresses.length();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 totalBalance;
        for (uint256 i = 0; i < lendingPoolAddresses.length(); i++) {
            totalBalance += _getBalance(lendingPoolAddresses.at(i));
        }
        return totalBalance;
    }

    function _computeDeviation(address pool) internal view returns (int256) {
        uint256 expected = (totalAssets() * lendingShares[pool]) / totalLendingShares;
        return int256(_getBalance(pool)) - int256(expected);
    }

    function _getBalance(address poolAddress) internal view returns (uint256) {
        IVault vault = IVault(poolAddress);
        return vault.balanceOf(address(this)) * vault.sharePrice() / 10 ** vault.decimals();
    }

}

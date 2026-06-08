// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LpRewardDistributor is ReentrancyGuard {
    IERC20 public immutable sato;
    IERC20 public immutable lpToken;

    uint256 public constant ACC_PRECISION = 1e36;

    uint256 public totalStaked;
    uint256 public accSatoPerShare;
    uint256 public undistributedRewards;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewardDebt;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event RewardsAdded(uint256 amount);
    event RewardsQueued(uint256 amount);

    constructor(address _sato, address _lpToken) {
        require(_sato != address(0), "SATO zero address");
        require(_lpToken != address(0), "LP zero address");

        sato = IERC20(_sato);
        lpToken = IERC20(_lpToken);
    }

    function notifyRewardAmount(uint256 amount) external nonReentrant {
        require(amount > 0, "No rewards");

        if (totalStaked == 0) {
            undistributedRewards += amount;
            emit RewardsQueued(amount);
            return;
        }

        uint256 totalAmount = amount + undistributedRewards;
        undistributedRewards = 0;

        accSatoPerShare += (totalAmount * ACC_PRECISION) / totalStaked;

        emit RewardsAdded(totalAmount);
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "No LP amount");

        _claim(msg.sender);

        totalStaked += amount;
        stakedBalance[msg.sender] += amount;

        if (undistributedRewards > 0) {
            accSatoPerShare +=
                (undistributedRewards * ACC_PRECISION) /
                totalStaked;

            emit RewardsAdded(undistributedRewards);
            undistributedRewards = 0;
        }

        rewardDebt[msg.sender] =
            (stakedBalance[msg.sender] * accSatoPerShare) /
            ACC_PRECISION;

        require(
            lpToken.transferFrom(msg.sender, address(this), amount),
            "LP transfer failed"
        );

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "No LP amount");
        require(stakedBalance[msg.sender] >= amount, "Not enough staked");

        _claim(msg.sender);

        totalStaked -= amount;
        stakedBalance[msg.sender] -= amount;

        rewardDebt[msg.sender] =
            (stakedBalance[msg.sender] * accSatoPerShare) /
            ACC_PRECISION;

        require(lpToken.transfer(msg.sender, amount), "LP transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    function claim() external nonReentrant {
        _claim(msg.sender);

        rewardDebt[msg.sender] =
            (stakedBalance[msg.sender] * accSatoPerShare) /
            ACC_PRECISION;
    }

    function pendingRewards(address user) external view returns (uint256) {
        uint256 accumulated =
            (stakedBalance[user] * accSatoPerShare) /
            ACC_PRECISION;

        if (accumulated < rewardDebt[user]) {
            return 0;
        }

        return accumulated - rewardDebt[user];
    }

    function _claim(address user) internal {
        uint256 accumulated =
            (stakedBalance[user] * accSatoPerShare) /
            ACC_PRECISION;

        if (accumulated <= rewardDebt[user]) {
            return;
        }

        uint256 pending = accumulated - rewardDebt[user];

        require(sato.transfer(user, pending), "SATO claim failed");

        emit Claimed(user, pending);
    }
}
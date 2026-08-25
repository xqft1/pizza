// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LpRewardDistributor is
    Ownable2Step,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    IERC20 public immutable sato;
    IERC20 public immutable lpToken;

    uint256 public constant PRECISION = 1e18;

    // IMPORTANT:
    // Prevents freshly deposited SATO being immediately reclaimed
    // and recycled through the Oven in the same transaction.
    uint256 public constant REWARD_DURATION = 7 days;

    address public oven;
    address public pizzaSlices;

    uint256 public totalStaked;

    mapping(address => uint256) public stakedBalance;

    // ------------------------------------------------------------
    // STREAMING REWARD ACCOUNTING
    // ------------------------------------------------------------

    uint256 public rewardRate;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;
    uint256 public periodFinish;

    // Rewards waiting because:
    // - nobody is staking
    // - distribution was paused
    // - integer division left tiny dust
    uint256 public queuedRewards;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // ------------------------------------------------------------
    // SOLVENCY ACCOUNTING
    // ------------------------------------------------------------

    // Actual SATO that has been accepted as reward funding.
    uint256 public totalRewardFunded;

    // Actual SATO paid out to LP stakers.
    uint256 public totalRewardPaid;

    // ------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 amount,
        uint256 forfeitedReward
    );

    event Claimed(address indexed user, uint256 amount);

    event RewardsFunded(
        address indexed source,
        uint256 amount
    );

    event RewardsQueued(uint256 amount);

    event OvenUpdated(
        address indexed oldOven,
        address indexed newOven
    );

    event PizzaSlicesUpdated(
        address indexed oldPizzaSlices,
        address indexed newPizzaSlices
    );

    // ------------------------------------------------------------
    // ERRORS
    // ------------------------------------------------------------

    error NotAuthorised();
    error ZeroAddress();
    error ZeroAmount();
    error NotEnoughStaked();
    error RewardsNotBacked();
    error RewardRateTooHigh();
    error OwnershipRenunciationDisabled();
    error ProtectedToken();

    // ------------------------------------------------------------
    // ACCESS
    // ------------------------------------------------------------

    modifier onlyRewardSource() {
        if (
            msg.sender != oven &&
            msg.sender != pizzaSlices
        ) {
            revert NotAuthorised();
        }

        _;
    }

    // ------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------

    constructor(
        address _sato,
        address _lpToken,
        address _oven,
        address _pizzaSlices,
        address _owner
    )
        Ownable(_owner)
    {
        if (
            _sato == address(0) ||
            _lpToken == address(0) ||
            _oven == address(0) ||
            _pizzaSlices == address(0) ||
            _owner == address(0)
        ) {
            revert ZeroAddress();
        }

        sato = IERC20(_sato);
        lpToken = IERC20(_lpToken);

        oven = _oven;
        pizzaSlices = _pizzaSlices;

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp;
    }

    // ------------------------------------------------------------
    // OWNERSHIP SAFETY
    // ------------------------------------------------------------

    // Deliberately disabled.
    //
    // You have already seen why retaining emergency control over
    // infrastructure contracts matters.
    function renounceOwnership()
        public
        override
        onlyOwner
    {
        revert OwnershipRenunciationDisabled();
    }

    // ------------------------------------------------------------
    // ADMIN
    // ------------------------------------------------------------

    function setOven(address newOven)
        external
        onlyOwner
    {
        if (newOven == address(0)) {
            revert ZeroAddress();
        }

        address oldOven = oven;
        oven = newOven;

        emit OvenUpdated(oldOven, newOven);
    }

    function setPizzaSlices(address newPizzaSlices)
        external
        onlyOwner
    {
        if (newPizzaSlices == address(0)) {
            revert ZeroAddress();
        }

        address oldPizzaSlices = pizzaSlices;
        pizzaSlices = newPizzaSlices;

        emit PizzaSlicesUpdated(
            oldPizzaSlices,
            newPizzaSlices
        );
    }

    // Emergency stop.
    //
    // Stops:
    // - new staking
    // - new reward notifications
    // - new reward streaming
    //
    // Users can STILL withdraw and claim already-earned rewards.
    function pause()
        external
        onlyOwner
    {
        _updateReward(address(0));
        _freezeRemainingRewards();
        _pause();
    }

    function unpause()
        external
        onlyOwner
    {
        _unpause();

        if (
            totalStaked > 0 &&
            queuedRewards > 0
        ) {
            _startQueuedRewards();
        }
    }

    // ------------------------------------------------------------
    // REWARD FUNDING
    // ------------------------------------------------------------

    /*
        Oven compatibility:

        SATO.transferFrom(
            baker,
            distributor,
            amount
        );

        distributor.notifyRewardAmount(amount);


        PizzaSlices compatibility:

        SATO.transferFrom(
            upgrader,
            distributor,
            amount
        );

        distributor.notifyRewardAmount(amount);


        In BOTH cases the SATO must physically arrive FIRST.
    */

    function notifyRewardAmount(uint256 amount)
        external
        onlyRewardSource
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) {
            revert ZeroAmount();
        }

        _updateReward(address(0));

        /*
            CRITICAL SOLVENCY CHECK

            outstandingBacking =
                everything ever funded
                minus everything actually paid.

            For another reward to be accepted, the contract
            must physically contain enough SATO to cover:

                existing liabilities
                +
                the newly reported reward.

            Therefore:

            - fake notify calls fail
            - the same SATO cannot be counted twice
            - notifyRewardAmount() cannot manufacture rewards
        */

        uint256 outstandingBacking =
            totalRewardFunded -
            totalRewardPaid;

        uint256 balance =
            sato.balanceOf(address(this));

        if (
            balance <
            outstandingBacking + amount
        ) {
            revert RewardsNotBacked();
        }

        totalRewardFunded += amount;

        emit RewardsFunded(
            msg.sender,
            amount
        );

        if (totalStaked == 0) {
            queuedRewards += amount;

            emit RewardsQueued(amount);

            return;
        }

        _extendRewardPeriod(amount);
    }

    // ------------------------------------------------------------
    // STAKING
    // ------------------------------------------------------------

    function stake(uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) {
            revert ZeroAmount();
        }

        _updateReward(msg.sender);

        bool wasEmpty =
            totalStaked == 0;

        /*
            Transfer first.

            ReentrancyGuard prevents malicious callback
            re-entry into state-changing functions.
        */

        lpToken.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(
            msg.sender,
            amount
        );

        /*
            Rewards deposited while nobody was staking
            only begin streaming AFTER somebody stakes.
        */

        if (
            wasEmpty &&
            queuedRewards > 0
        ) {
            _startQueuedRewards();
        }
    }

    // ------------------------------------------------------------
    // WITHDRAW
    // ------------------------------------------------------------

    function withdraw(uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (
            stakedBalance[msg.sender] <
            amount
        ) {
            revert NotEnoughStaked();
        }

        _updateReward(msg.sender);

        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;

        /*
            If the final LP holder leaves, stop the reward clock.

            Remaining rewards are preserved instead of silently
            disappearing while nobody is staked.
        */

        if (totalStaked == 0) {
            _freezeRemainingRewards();
        }

        lpToken.safeTransfer(
            msg.sender,
            amount
        );

        emit Withdrawn(
            msg.sender,
            amount
        );
    }

    // ------------------------------------------------------------
    // EMERGENCY WITHDRAW
    // ------------------------------------------------------------

    /*
        Emergency withdrawal deliberately forfeits
        the user's already-earned reward.

        That forfeited SATO is placed back into the reward queue
        rather than becoming stuck.
    */

    function emergencyWithdraw()
        external
        nonReentrant
    {
        uint256 amount =
            stakedBalance[msg.sender];

        if (amount == 0) {
            revert ZeroAmount();
        }

        _updateReward(msg.sender);

        uint256 forfeited =
            rewards[msg.sender];

        rewards[msg.sender] = 0;

        if (forfeited > 0) {
            queuedRewards += forfeited;
        }

        stakedBalance[msg.sender] = 0;
        userRewardPerTokenPaid[msg.sender] =
            rewardPerTokenStored;

        totalStaked -= amount;

        if (totalStaked == 0) {
            _freezeRemainingRewards();
        }

        lpToken.safeTransfer(
            msg.sender,
            amount
        );

        emit EmergencyWithdraw(
            msg.sender,
            amount,
            forfeited
        );
    }

    // ------------------------------------------------------------
    // CLAIM
    // ------------------------------------------------------------

    function claim()
        external
        nonReentrant
    {
        _updateReward(msg.sender);

        uint256 reward =
            rewards[msg.sender];

        if (reward == 0) {
            return;
        }

        // Effects before interaction.
        rewards[msg.sender] = 0;
        totalRewardPaid += reward;

        sato.safeTransfer(
            msg.sender,
            reward
        );

        emit Claimed(
            msg.sender,
            reward
        );
    }

    // ------------------------------------------------------------
    // VIEWS
    // ------------------------------------------------------------

    function lastTimeRewardApplicable()
        public
        view
        returns (uint256)
    {
        return
            block.timestamp < periodFinish
                ? block.timestamp
                : periodFinish;
    }

    function rewardPerToken()
        public
        view
        returns (uint256)
    {
        if (
            totalStaked == 0 ||
            rewardRate == 0
        ) {
            return rewardPerTokenStored;
        }

        uint256 applicable =
            lastTimeRewardApplicable();

        if (applicable <= lastUpdateTime) {
            return rewardPerTokenStored;
        }

        uint256 elapsed =
            applicable -
            lastUpdateTime;

        /*
            rewardRate is bounded when schedules are created,
            preventing rewardRate * PRECISION overflow.
        */

        uint256 increment =
            Math.mulDiv(
                elapsed,
                rewardRate * PRECISION,
                totalStaked
            );

        return
            rewardPerTokenStored +
            increment;
    }

    function pendingRewards(address user)
        external
        view
        returns (uint256)
    {
        return earned(user);
    }

    function earned(address user)
        public
        view
        returns (uint256)
    {
        uint256 currentRPT =
            rewardPerToken();

        uint256 delta =
            currentRPT -
            userRewardPerTokenPaid[user];

        return
            rewards[user] +
            Math.mulDiv(
                stakedBalance[user],
                delta,
                PRECISION
            );
    }

    function outstandingRewardBacking()
        public
        view
        returns (uint256)
    {
        return
            totalRewardFunded -
            totalRewardPaid;
    }

    function isFullyBacked()
        external
        view
        returns (bool)
    {
        return
            sato.balanceOf(address(this)) >=
            outstandingRewardBacking();
    }

    // ------------------------------------------------------------
    // INTERNAL REWARD ACCOUNTING
    // ------------------------------------------------------------

    function _updateReward(address account)
        internal
    {
        uint256 currentRPT =
            rewardPerToken();

        rewardPerTokenStored =
            currentRPT;

        lastUpdateTime =
            lastTimeRewardApplicable();

        if (account == address(0)) {
            return;
        }

        uint256 delta =
            currentRPT -
            userRewardPerTokenPaid[account];

        if (delta > 0) {
            rewards[account] +=
                Math.mulDiv(
                    stakedBalance[account],
                    delta,
                    PRECISION
                );
        }

        userRewardPerTokenPaid[account] =
            currentRPT;
    }

    function _extendRewardPeriod(
        uint256 newReward
    )
        internal
    {
        uint256 distributable =
            newReward +
            queuedRewards;

        queuedRewards = 0;

        /*
            Preserve rewards remaining from the active stream.
        */

        if (
            block.timestamp <
            periodFinish &&
            rewardRate > 0
        ) {
            uint256 remainingTime =
                periodFinish -
                block.timestamp;

            distributable +=
                remainingTime *
                rewardRate;
        }

        _startRewardPeriod(
            distributable
        );
    }

    function _startQueuedRewards()
        internal
    {
        if (
            totalStaked == 0 ||
            queuedRewards == 0
        ) {
            return;
        }

        uint256 amount =
            queuedRewards;

        queuedRewards = 0;

        _startRewardPeriod(amount);
    }

    function _startRewardPeriod(
        uint256 amount
    )
        internal
    {
        if (
            amount <
            REWARD_DURATION
        ) {
            /*
                Too small to produce even 1 wei/second.

                Keep it queued until more SATO arrives.
            */

            queuedRewards += amount;
            rewardRate = 0;
            periodFinish = block.timestamp;
            lastUpdateTime = block.timestamp;

            return;
        }

        uint256 newRate =
            amount /
            REWARD_DURATION;

        if (
            newRate >
            type(uint256).max /
            PRECISION
        ) {
            revert RewardRateTooHigh();
        }

        /*
            Preserve integer-division dust.
        */

        uint256 scheduled =
            newRate *
            REWARD_DURATION;

        uint256 remainder =
            amount -
            scheduled;

        queuedRewards += remainder;

        rewardRate = newRate;

        lastUpdateTime =
            block.timestamp;

        periodFinish =
            block.timestamp +
            REWARD_DURATION;
    }

    function _freezeRemainingRewards()
        internal
    {
        if (
            rewardRate == 0 ||
            block.timestamp >= periodFinish
        ) {
            rewardRate = 0;
            periodFinish = block.timestamp;
            lastUpdateTime = block.timestamp;

            return;
        }

        uint256 remaining =
            (periodFinish - block.timestamp) *
            rewardRate;

        queuedRewards += remaining;

        rewardRate = 0;
        periodFinish = block.timestamp;
        lastUpdateTime = block.timestamp;
    }

    // ------------------------------------------------------------
    // TOKEN RESCUE
    // ------------------------------------------------------------

    /*
        Owner may recover unrelated tokens accidentally sent here.

        LP and SATO can NEVER be rescued by the owner.
    */

    function rescueToken(
        address token,
        address to,
        uint256 amount
    )
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        if (
            token == address(lpToken) ||
            token == address(sato)
        ) {
            revert ProtectedToken();
        }

        IERC20(token).safeTransfer(
            to,
            amount
        );
    }
}

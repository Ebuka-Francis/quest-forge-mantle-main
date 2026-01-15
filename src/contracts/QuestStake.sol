// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title QuestStake - User-Friendly Version
 * @notice Simplified staking contract with lower fees and better UX
 * @dev Reduced fees, grace period, progressive penalties, and no burn complications
 */
contract QuestStake is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    // Pool configurations
    struct PoolConfig {
        uint256 duration; // Lock duration
        uint256 apy; // Annual percentage yield (in basis points)
        uint256 totalStaked; // Total amount staked in pool
        bool active; // Is pool accepting stakes
    }

    // Staking info for each user
    struct StakeInfo {
        uint256 amount; // Amount staked (after entry fee)
        uint256 poolId; // Which pool they're in
        uint256 startTime; // When they staked
        uint256 endTime; // When lock period ends
        uint256 lastClaimTime; // Last time rewards were claimed
        uint256 rewardsClaimed; // Total rewards claimed
        bool withdrawn; // Has stake been withdrawn
    }

    struct YieldSource {
        string name; // Source of yield
        uint256 amount; // Amount from this source
        uint256 timestamp; // When it was added
    }

    // Mappings
    mapping(uint256 => PoolConfig) public pools;
    uint256 public poolCount;

    mapping(address => StakeInfo[]) public userStakes;
    mapping(address => uint256) public userStakeCount;

    YieldSource[] public yieldSources;
    uint256 public totalYieldGenerated;

    // REDUCED FEES - Much more user-friendly! 🎉
    uint256 public constant ENTRY_FEE = 100; // 1% (was 3%)
    uint256 public constant EXIT_FEE = 200; // 2% (was 4%)
    uint256 public constant EARLY_EXIT_PENALTY = 300; // 3% (was 7%)
    uint256 public constant REWARD_CLAIM_TAX = 100; // 1% (was 3%)
    uint256 public constant EMERGENCY_WITHDRAWAL_FEE = 500; // 5% (was 12%)

    // Grace period - no penalty for first 24 hours
    uint256 public constant GRACE_PERIOD = 1 days;

    // Fee distribution (simplified - no burn)
    uint256 public constant REWARD_POOL_PERCENTAGE = 6000; // 60% to rewards
    uint256 public constant TREASURY_PERCENTAGE = 4000; // 40% to treasury

    // Addresses
    address public treasury;
    address public rewardPool;

    // Statistics
    uint256 public totalStaked;
    uint256 public totalRewardsDistributed;
    uint256 public totalFeesCollected;

    // Events
    event Staked(
        address indexed user,
        uint256 indexed stakeId,
        uint256 poolId,
        uint256 amount,
        uint256 afterFee
    );
    event Unstaked(
        address indexed user,
        uint256 indexed stakeId,
        uint256 amount,
        uint256 fee
    );
    event RewardsClaimed(
        address indexed user,
        uint256 indexed stakeId,
        uint256 reward,
        uint256 tax
    );
    event PoolCreated(uint256 indexed poolId, uint256 duration, uint256 apy);
    event PoolStatusChanged(uint256 indexed poolId, bool active);
    event YieldSourceAdded(string name, uint256 amount);
    event FeesDistributed(uint256 toRewardPool, uint256 toTreasury);
    event EmergencyWithdrawal(address indexed user, uint256 amount);

    constructor(
        address _token,
        address _treasury,
        address _rewardPool
    ) Ownable(msg.sender) {
        require(_token != address(0), "Invalid token address");
        require(_treasury != address(0), "Invalid treasury address");
        require(_rewardPool != address(0), "Invalid reward pool address");

        token = IERC20(_token);
        treasury = _treasury;
        rewardPool = _rewardPool;

        _createDefaultPools();
    }

    /**
     * @dev Create default staking pools with BETTER APYs
     */
    function _createDefaultPools() internal {
        // 4 weeks - 5% APY (was 3%)
        pools[0] = PoolConfig({
            duration: 4 * 7 * 24 * 60 * 60,
            apy: 500,
            totalStaked: 0,
            active: true
        });

        // 8 weeks - 8% APY (was 5%)
        pools[1] = PoolConfig({
            duration: 8 * 7 * 24 * 60 * 60,
            apy: 800,
            totalStaked: 0,
            active: true
        });

        // 12 weeks - 12% APY (was 7%)
        pools[2] = PoolConfig({
            duration: 12 * 7 * 24 * 60 * 60,
            apy: 1200,
            totalStaked: 0,
            active: true
        });

        // 4 months - 15% APY (was 9%)
        pools[3] = PoolConfig({
            duration: 4 * 30 * 24 * 60 * 60,
            apy: 1500,
            totalStaked: 0,
            active: true
        });

        poolCount = 4;

        for (uint256 i = 0; i < poolCount; i++) {
            emit PoolCreated(i, pools[i].duration, pools[i].apy);
        }
    }

    /**
     * @notice Stake tokens in a pool
     * @param amount Amount to stake
     * @param poolId Pool to stake in
     */
    function stake(
        uint256 amount,
        uint256 poolId
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(poolId < poolCount, "Invalid pool ID");
        require(pools[poolId].active, "Pool is not active");

        PoolConfig storage pool = pools[poolId];

        // Calculate entry fee (only 1% now!)
        uint256 entryFee = (amount * ENTRY_FEE) / 10000;
        uint256 stakeAmount = amount - entryFee;

        require(stakeAmount > 0, "Stake amount too small");

        // Transfer tokens from user
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Create stake record
        uint256 stakeId = userStakeCount[msg.sender];
        userStakes[msg.sender].push(
            StakeInfo({
                amount: stakeAmount,
                poolId: poolId,
                startTime: block.timestamp,
                endTime: block.timestamp + pool.duration,
                lastClaimTime: block.timestamp,
                rewardsClaimed: 0,
                withdrawn: false
            })
        );

        userStakeCount[msg.sender]++;
        pool.totalStaked += stakeAmount;
        totalStaked += stakeAmount;

        // Distribute entry fee
        _distributeFees(entryFee, "Entry Fee");

        emit Staked(msg.sender, stakeId, poolId, amount, stakeAmount);
    }

    /**
     * @notice Unstake tokens with PROGRESSIVE PENALTY system
     * @param stakeId ID of the stake to withdraw
     */
    function unstake(uint256 stakeId) external nonReentrant {
        require(stakeId < userStakeCount[msg.sender], "Invalid stake ID");

        StakeInfo storage stakeInfo = userStakes[msg.sender][stakeId];
        require(!stakeInfo.withdrawn, "Already withdrawn");
        require(stakeInfo.amount > 0, "No stake found");

        // Calculate pending rewards
        uint256 pendingRewards = calculatePendingRewards(msg.sender, stakeId);

        // Calculate exit fee with PROGRESSIVE PENALTY
        uint256 exitFee = _calculateExitFee(stakeInfo);
        uint256 withdrawAmount = stakeInfo.amount - exitFee;

        // Update state
        stakeInfo.withdrawn = true;
        pools[stakeInfo.poolId].totalStaked -= stakeInfo.amount;
        totalStaked -= stakeInfo.amount;

        // Distribute exit fee
        bool isEarly = block.timestamp < stakeInfo.endTime;
        _distributeFees(exitFee, isEarly ? "Early Exit Fee" : "Exit Fee");

        // Transfer principal back to user
        token.safeTransfer(msg.sender, withdrawAmount);

        // Claim rewards if any
        if (pendingRewards > 0) {
            _claimRewards(msg.sender, stakeId, pendingRewards);
        }

        emit Unstaked(msg.sender, stakeId, withdrawAmount, exitFee);
    }

    /**
     * @dev Calculate exit fee with PROGRESSIVE PENALTY
     * Users pay less penalty the closer they are to maturity!
     */
    function _calculateExitFee(
        StakeInfo storage stakeInfo
    ) internal view returns (uint256) {
        // If past maturity, only normal exit fee
        if (block.timestamp >= stakeInfo.endTime) {
            return (stakeInfo.amount * EXIT_FEE) / 10000;
        }

        // Within grace period? Only normal exit fee (no penalty!)
        if (block.timestamp <= stakeInfo.startTime + GRACE_PERIOD) {
            return (stakeInfo.amount * EXIT_FEE) / 10000;
        }

        // Calculate time-based penalty reduction
        uint256 totalDuration = stakeInfo.endTime - stakeInfo.startTime;
        uint256 timeStaked = block.timestamp - stakeInfo.startTime;
        uint256 percentComplete = (timeStaked * 100) / totalDuration;

        // Progressive penalty based on completion percentage
        uint256 penaltyRate;
        if (percentComplete >= 90) {
            penaltyRate = 100; // Only 1% penalty if 90%+ complete
        } else if (percentComplete >= 75) {
            penaltyRate = 150; // 1.5% penalty if 75%+ complete
        } else if (percentComplete >= 50) {
            penaltyRate = 200; // 2% penalty if 50%+ complete
        } else {
            penaltyRate = EARLY_EXIT_PENALTY; // 3% penalty if less than 50%
        }

        uint256 penalty = (stakeInfo.amount * penaltyRate) / 10000;
        uint256 normalFee = (stakeInfo.amount * EXIT_FEE) / 10000;

        return normalFee + penalty;
    }

    /**
     * @notice Claim accumulated rewards
     * @param stakeId ID of the stake
     */
    function claimRewards(uint256 stakeId) external nonReentrant {
        require(stakeId < userStakeCount[msg.sender], "Invalid stake ID");

        StakeInfo storage stakeInfo = userStakes[msg.sender][stakeId];
        require(!stakeInfo.withdrawn, "Stake already withdrawn");

        uint256 pendingRewards = calculatePendingRewards(msg.sender, stakeId);
        require(pendingRewards > 0, "No rewards to claim");

        _claimRewards(msg.sender, stakeId, pendingRewards);
    }

    /**
     * @dev Internal function to claim rewards
     */
    function _claimRewards(
        address user,
        uint256 stakeId,
        uint256 rewardAmount
    ) internal {
        StakeInfo storage stakeInfo = userStakes[user][stakeId];

        // Calculate claim tax (only 1% now!)
        uint256 claimTax = (rewardAmount * REWARD_CLAIM_TAX) / 10000;
        uint256 netReward = rewardAmount - claimTax;

        // Check contract has enough balance
        uint256 contractBalance = token.balanceOf(address(this));
        require(
            contractBalance >= netReward,
            "Insufficient reward pool balance"
        );

        // Update state
        stakeInfo.lastClaimTime = block.timestamp;
        stakeInfo.rewardsClaimed += rewardAmount;
        totalRewardsDistributed += rewardAmount;

        // Distribute claim tax
        _distributeFees(claimTax, "Reward Claim Tax");

        // Transfer rewards to user
        token.safeTransfer(user, netReward);

        emit RewardsClaimed(user, stakeId, netReward, claimTax);
    }

    /**
     * @dev Distribute fees (SIMPLIFIED - no burn complications)
     */
    function _distributeFees(
        uint256 feeAmount,
        string memory feeType
    ) internal {
        if (feeAmount == 0) return;

        // 60% to reward pool, 40% to treasury
        uint256 rewardPoolAmount = (feeAmount * REWARD_POOL_PERCENTAGE) / 10000;
        uint256 treasuryAmount = feeAmount - rewardPoolAmount;

        // Send to reward pool
        if (rewardPoolAmount > 0) {
            token.safeTransfer(rewardPool, rewardPoolAmount);
            _addYieldSource(
                string(abi.encodePacked("Fee Distribution: ", feeType)),
                rewardPoolAmount
            );
        }

        // Send to treasury
        if (treasuryAmount > 0) {
            token.safeTransfer(treasury, treasuryAmount);
        }

        totalFeesCollected += feeAmount;

        emit FeesDistributed(rewardPoolAmount, treasuryAmount);
    }

    /**
     * @notice Calculate pending rewards for a stake
     * @param user User address
     * @param stakeId Stake ID
     * @return Pending reward amount
     */
    function calculatePendingRewards(
        address user,
        uint256 stakeId
    ) public view returns (uint256) {
        if (stakeId >= userStakeCount[user]) return 0;

        StakeInfo storage stakeInfo = userStakes[user][stakeId];
        if (stakeInfo.withdrawn || stakeInfo.amount == 0) return 0;

        PoolConfig storage pool = pools[stakeInfo.poolId];

        // Calculate time since last claim
        uint256 rewardEndTime = block.timestamp < stakeInfo.endTime
            ? block.timestamp
            : stakeInfo.endTime;

        // Don't allow rewards beyond pool end time
        if (rewardEndTime <= stakeInfo.lastClaimTime) return 0;

        uint256 stakingTime = rewardEndTime - stakeInfo.lastClaimTime;

        // Calculate reward: (amount × APY × time) / (365 days × 10000)
        uint256 reward = (stakeInfo.amount * pool.apy * stakingTime) /
            (365 days * 10000);

        return reward;
    }

    /**
     * @notice Get exit fee preview for a stake
     * @param user User address
     * @param stakeId Stake ID
     * @return fee The exit fee amount
     * @return isEarly Whether it's an early withdrawal
     * @return percentComplete Percentage of lock period completed
     */
    function previewExitFee(
        address user,
        uint256 stakeId
    )
        external
        view
        returns (uint256 fee, bool isEarly, uint256 percentComplete)
    {
        require(stakeId < userStakeCount[user], "Invalid stake ID");

        StakeInfo storage stakeInfo = userStakes[user][stakeId];
        require(!stakeInfo.withdrawn, "Already withdrawn");

        isEarly = block.timestamp < stakeInfo.endTime;

        if (isEarly) {
            uint256 totalDuration = stakeInfo.endTime - stakeInfo.startTime;
            uint256 timeStaked = block.timestamp - stakeInfo.startTime;
            percentComplete = (timeStaked * 100) / totalDuration;
        } else {
            percentComplete = 100;
        }

        fee = _calculateExitFee(stakeInfo);
    }

    /**
     * @dev Add yield source for tracking
     */
    function addYieldSource(
        string memory name,
        uint256 amount
    ) external onlyOwner {
        _addYieldSource(name, amount);
    }

    /**
     * @dev Internal function to add yield source
     */
    function _addYieldSource(string memory name, uint256 amount) internal {
        yieldSources.push(
            YieldSource({
                name: name,
                amount: amount,
                timestamp: block.timestamp
            })
        );

        totalYieldGenerated += amount;

        emit YieldSourceAdded(name, amount);
    }

    /**
     * @notice Get all stakes for a user
     * @param user User address
     * @return Array of user's stakes
     */
    function getUserStakes(
        address user
    ) external view returns (StakeInfo[] memory) {
        return userStakes[user];
    }

    /**
     * @notice Get specific stake info
     */
    function getStake(
        address user,
        uint256 stakeId
    )
        external
        view
        returns (
            uint256 amount,
            uint256 poolId,
            uint256 startTime,
            uint256 endTime,
            uint256 lastClaimTime,
            uint256 rewardsClaimed,
            bool withdrawn
        )
    {
        require(stakeId < userStakeCount[user], "Invalid stake ID");

        StakeInfo storage stakeInfo = userStakes[user][stakeId];
        return (
            stakeInfo.amount,
            stakeInfo.poolId,
            stakeInfo.startTime,
            stakeInfo.endTime,
            stakeInfo.lastClaimTime,
            stakeInfo.rewardsClaimed,
            stakeInfo.withdrawn
        );
    }

    /**
     * @notice Get pool information
     */
    function getPoolInfo(
        uint256 poolId
    ) external view returns (PoolConfig memory) {
        require(poolId < poolCount, "Invalid pool ID");
        return pools[poolId];
    }

    /**
     * @notice Get all pools
     */
    function getAllPools() external view returns (PoolConfig[] memory) {
        PoolConfig[] memory allPools = new PoolConfig[](poolCount);
        for (uint256 i = 0; i < poolCount; i++) {
            allPools[i] = pools[i];
        }
        return allPools;
    }

    /**
     * @notice Get yield sources
     */
    function getYieldSources() external view returns (YieldSource[] memory) {
        return yieldSources;
    }

    /**
     * @notice Get contract statistics
     */
    function getContractStats()
        external
        view
        returns (
            uint256 totalStaked_,
            uint256 totalRewardsDistributed_,
            uint256 totalFeesCollected_,
            uint256 totalYieldGenerated_,
            uint256 contractBalance
        )
    {
        totalStaked_ = totalStaked;
        totalRewardsDistributed_ = totalRewardsDistributed;
        totalFeesCollected_ = totalFeesCollected;
        totalYieldGenerated_ = totalYieldGenerated;
        contractBalance = token.balanceOf(address(this));
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Create new staking pool
     */
    function createPool(uint256 duration, uint256 apy) external onlyOwner {
        pools[poolCount] = PoolConfig({
            duration: duration,
            apy: apy,
            totalStaked: 0,
            active: true
        });

        emit PoolCreated(poolCount, duration, apy);
        poolCount++;
    }

    /**
     * @notice Toggle pool status
     */
    function togglePoolStatus(uint256 poolId) external onlyOwner {
        require(poolId < poolCount, "Invalid pool ID");
        pools[poolId].active = !pools[poolId].active;
        emit PoolStatusChanged(poolId, pools[poolId].active);
    }

    /**
     * @notice Update treasury address
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury address");
        treasury = newTreasury;
    }

    /**
     * @notice Update reward pool address
     */
    function updateRewardPool(address newRewardPool) external onlyOwner {
        require(newRewardPool != address(0), "Invalid reward pool address");
        rewardPool = newRewardPool;
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal (only when paused)
     */
    function emergencyWithdraw(uint256 stakeId) external nonReentrant {
        require(paused(), "Only available when paused");
        require(stakeId < userStakeCount[msg.sender], "Invalid stake ID");

        StakeInfo storage stakeInfo = userStakes[msg.sender][stakeId];
        require(!stakeInfo.withdrawn, "Already withdrawn");
        require(stakeInfo.amount > 0, "No stake found");

        // Calculate emergency withdrawal fee (5% instead of 12%)
        uint256 emergencyFee = (stakeInfo.amount * EMERGENCY_WITHDRAWAL_FEE) /
            10000;
        uint256 withdrawAmount = stakeInfo.amount - emergencyFee;

        // Update state
        stakeInfo.withdrawn = true;
        pools[stakeInfo.poolId].totalStaked -= stakeInfo.amount;
        totalStaked -= stakeInfo.amount;

        // Distribute emergency fee
        _distributeFees(emergencyFee, "Emergency Withdrawal Fee");

        // Transfer to user
        token.safeTransfer(msg.sender, withdrawAmount);

        emit EmergencyWithdrawal(msg.sender, withdrawAmount);
    }

    /**
     * @notice Admin emergency withdrawal
     */
    function adminEmergencyWithdraw(
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(
            amount <= token.balanceOf(address(this)),
            "Insufficient balance"
        );
        token.safeTransfer(owner(), amount);
    }

    /**
     * @notice Fund reward pool
     */
    function fundRewardPool(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        token.safeTransferFrom(msg.sender, address(this), amount);
        _addYieldSource("Manual Funding", amount);
    }
}

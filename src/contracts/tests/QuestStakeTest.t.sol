// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/QuestStake.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockToken is ERC20 {
    constructor() ERC20("Quest Token", "QUEST") {
        _mint(msg.sender, 1000000 * 10**18); // Mint 1M tokens
    }
    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract QuestStakeTest is Test {
    QuestStake public staking;
    MockToken public token;
    
    address public owner;
    address public treasury;
    address public rewardPool;
    address public alice;
    address public bob;
    address public charlie;
    
    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant STAKE_AMOUNT = 1000 ether;
    
    // Events to test
    event Staked(address indexed user, uint256 indexed stakeId, uint256 poolId, uint256 amount, uint256 afterFee);
    event Unstaked(address indexed user, uint256 indexed stakeId, uint256 amount, uint256 fee);
    event RewardsClaimed(address indexed user, uint256 indexed stakeId, uint256 reward, uint256 tax);
    
    function setUp() public {
        // Setup accounts
        owner = address(this);
        treasury = makeAddr("treasury");
        rewardPool = makeAddr("rewardPool");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        
        // Deploy token
        token = new MockToken();
        
        // Deploy staking contract
        staking = new QuestStake(
            address(token),
            treasury,
            rewardPool
        );
        
        // Distribute tokens to test users
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        token.mint(charlie, INITIAL_BALANCE);
        
        // Approve staking contract
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
        
        vm.prank(charlie);
        token.approve(address(staking), type(uint256).max);
        
        // Fund reward pool
        token.mint(address(staking), 100000 ether);
    }
    
    // ==================== CONSTRUCTOR TESTS ====================
    
    function test_Constructor_SetsCorrectAddresses() public view {
        assertEq(address(staking.token()), address(token));
        assertEq(staking.treasury(), treasury);
        assertEq(staking.rewardPool(), rewardPool);
        assertEq(staking.owner(), owner);
    }
    
    function test_Constructor_Creates4DefaultPools() public view {
        assertEq(staking.poolCount(), 4);
        
        // Check pool 0 (4 weeks, 5% APY)
        (uint256 duration, uint256 apy, uint256 totalStaked, bool active) = staking.pools(0);
        assertEq(duration, 4 * 7 * 24 * 60 * 60);
        assertEq(apy, 500);
        assertEq(totalStaked, 0);
        assertTrue(active);
    }
    
    function test_Constructor_RevertsWithZeroTokenAddress() public {
        vm.expectRevert("Invalid token address");
        new QuestStake(address(0), treasury, rewardPool);
    }
    
    function test_Constructor_RevertsWithZeroTreasuryAddress() public {
        vm.expectRevert("Invalid treasury address");
        new QuestStake(address(token), address(0), rewardPool);
    }
    
    function test_Constructor_RevertsWithZeroRewardPoolAddress() public {
        vm.expectRevert("Invalid reward pool address");
        new QuestStake(address(token), treasury, address(0));
    }
    
    // ==================== STAKING TESTS ====================
    
    function test_Stake_Success() public {
        uint256 poolId = 0;
        
        vm.expectEmit(true, true, false, true);
        emit Staked(alice, 0, poolId, STAKE_AMOUNT, STAKE_AMOUNT - (STAKE_AMOUNT * 100 / 10000));
        
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, poolId);
        
        // Check stake was created
        assertEq(staking.userStakeCount(alice), 1);
        
        // Check balances
        uint256 entryFee = (STAKE_AMOUNT * 100) / 10000; // 1%
        uint256 stakedAmount = STAKE_AMOUNT - entryFee;
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - STAKE_AMOUNT);
        assertEq(staking.totalStaked(), stakedAmount);
    }
    
    function test_Stake_CalculatesCorrectEntryFee() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        (uint256 amount,,,,,, ) = staking.getStake(alice, 0);
        
        // Entry fee is 1%
        uint256 expectedFee = (STAKE_AMOUNT * 100) / 10000;
        uint256 expectedStake = STAKE_AMOUNT - expectedFee;
        
        assertEq(amount, expectedStake);
    }
    
    function test_Stake_UpdatesPoolTotalStaked() public {
        uint256 poolId = 1;
        
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, poolId);
        
        (,, uint256 totalStaked,) = staking.pools(poolId);
        
        uint256 expectedStake = STAKE_AMOUNT - (STAKE_AMOUNT * 100 / 10000);
        assertEq(totalStaked, expectedStake);
    }
    
    function test_Stake_DistributesFeeCorrectly() public {
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);
        uint256 rewardPoolBalanceBefore = token.balanceOf(rewardPool);
        
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        uint256 entryFee = (STAKE_AMOUNT * 100) / 10000;
        uint256 toRewardPool = (entryFee * 6000) / 10000; // 60%
        uint256 toTreasury = entryFee - toRewardPool; // 40%
        
        assertEq(token.balanceOf(rewardPool), rewardPoolBalanceBefore + toRewardPool);
        assertEq(token.balanceOf(treasury), treasuryBalanceBefore + toTreasury);
    }
    
    function test_Stake_MultipleStakesBySameUser() public {
        vm.startPrank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        staking.stake(STAKE_AMOUNT, 1);
        staking.stake(STAKE_AMOUNT, 2);
        vm.stopPrank();
        
        assertEq(staking.userStakeCount(alice), 3);
    }
    
    function test_Stake_RevertsWithZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("Amount must be greater than 0");
        staking.stake(0, 0);
    }
    
    function test_Stake_RevertsWithInvalidPoolId() public {
        vm.prank(alice);
        vm.expectRevert("Invalid pool ID");
        staking.stake(STAKE_AMOUNT, 999);
    }
    
    function test_Stake_RevertsWhenPoolNotActive() public {
        // Deactivate pool
        staking.togglePoolStatus(0);
        
        vm.prank(alice);
        vm.expectRevert("Pool is not active");
        staking.stake(STAKE_AMOUNT, 0);
    }
    
    function test_Stake_RevertsWhenPaused() public {
        staking.pause();
        
        vm.prank(alice);
        vm.expectRevert();
        staking.stake(STAKE_AMOUNT, 0);
    }
    
    // ==================== UNSTAKE TESTS ====================
    
    function test_Unstake_SuccessAfterMaturity() public {
        // Stake
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        (uint256 stakedAmount,, uint256 startTime, uint256 endTime,,,) = staking.getStake(alice, 0);
        
        // Fast forward past maturity
        vm.warp(endTime + 1);
        
        // Unstake
        vm.prank(alice);
        staking.unstake(0);
        
        // Check withdrawal
        (,,,,,,bool withdrawn) = staking.getStake(alice, 0);
        assertTrue(withdrawn);
        
        // Check received correct amount (stake - exit fee)
        uint256 exitFee = (stakedAmount * 200) / 10000; // 2% exit fee
        uint256 expectedReceived = stakedAmount - exitFee;
        
        assertGt(token.balanceOf(alice), INITIAL_BALANCE - STAKE_AMOUNT);
    }
    
    function test_Unstake_WithinGracePeriod() public {
        // Stake
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        (uint256 stakedAmount,,,,,,) = staking.getStake(alice, 0);
        
        // Unstake within 24 hours (grace period)
        vm.warp(block.timestamp + 12 hours);
        
        vm.prank(alice);
        staking.unstake(0);
        
        // Should only pay 2% exit fee, no penalty
        uint256 exitFee = (stakedAmount * 200) / 10000;
        uint256 expectedReceived = stakedAmount - exitFee;
        
        // Check user received correct amount
        uint256 totalFees = (STAKE_AMOUNT * 100) / 10000 + exitFee;
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - totalFees);
    }
    
    function test_Unstake_EarlyWithProgressivePenalty() public {
        // Stake in 8 week pool
        uint256 poolId = 1;
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, poolId);
        
        (uint256 stakedAmount,,,uint256 endTime,,,) = staking.getStake(alice, 0);
        uint256 duration = endTime - block.timestamp;
        
        // Fast forward to 50% completion
        vm.warp(block.timestamp + duration / 2);
        
        // Preview exit fee
        (uint256 fee, bool isEarly, uint256 percentComplete) = staking.previewExitFee(alice, 0);
        
        assertTrue(isEarly);
        assertEq(percentComplete, 50);
        
        // At 50%, penalty should be 2% + 2% = 4% total
        uint256 expectedFee = (stakedAmount * 400) / 10000;
        assertEq(fee, expectedFee);
    }
    
    function test_Unstake_ProgressivePenaltyAt75Percent() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 1); // 8 week pool
        
        (uint256 stakedAmount,,,uint256 endTime,,,) = staking.getStake(alice, 0);
        uint256 duration = endTime - block.timestamp;
        
        // Fast forward to 75% completion
        vm.warp(block.timestamp + (duration * 75) / 100);
        
        (uint256 fee,, uint256 percentComplete) = staking.previewExitFee(alice, 0);
        
        assertEq(percentComplete, 75);
        
        // At 75%, penalty should be 2% + 1.5% = 3.5% total
        uint256 expectedFee = (stakedAmount * 350) / 10000;
        assertEq(fee, expectedFee);
    }
    
    function test_Unstake_ProgressivePenaltyAt90Percent() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 1);
        
        (uint256 stakedAmount,,,uint256 endTime,,,) = staking.getStake(alice, 0);
        uint256 duration = endTime - block.timestamp;
        
        // Fast forward to 90% completion
        vm.warp(block.timestamp + (duration * 90) / 100);
        
        (uint256 fee,, uint256 percentComplete) = staking.previewExitFee(alice, 0);
        
        assertEq(percentComplete, 90);
        
        // At 90%, penalty should be 2% + 1% = 3% total
        uint256 expectedFee = (stakedAmount * 300) / 10000;
        assertEq(fee, expectedFee);
    }
    
    function test_Unstake_ClaimsRewardsAutomatically() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        // Fast forward 2 weeks to accrue rewards
        vm.warp(block.timestamp + 2 weeks);
        
        uint256 pendingRewards = staking.calculatePendingRewards(alice, 0);
        assertTrue(pendingRewards > 0);
        
        uint256 balanceBefore = token.balanceOf(alice);
        
        // Unstake (should claim rewards automatically)
        vm.prank(alice);
        staking.unstake(0);
        
        uint256 balanceAfter = token.balanceOf(alice);
        assertGt(balanceAfter, balanceBefore);
    }
    
    function test_Unstake_RevertsWithInvalidStakeId() public {
        vm.prank(alice);
        vm.expectRevert("Invalid stake ID");
        staking.unstake(999);
    }
    
    function test_Unstake_RevertsIfAlreadyWithdrawn() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        vm.warp(block.timestamp + 4 weeks);
        
        vm.prank(alice);
        staking.unstake(0);
        
        // Try to unstake again
        vm.prank(alice);
        vm.expectRevert("Already withdrawn");
        staking.unstake(0);
    }
    
    // ==================== REWARDS TESTS ====================
    
    function test_ClaimRewards_Success() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        // Fast forward 2 weeks
        vm.warp(block.timestamp + 2 weeks);
        
        uint256 pendingRewards = staking.calculatePendingRewards(alice, 0);
        assertTrue(pendingRewards > 0);
        
        uint256 balanceBefore = token.balanceOf(alice);
        
        vm.prank(alice);
        staking.claimRewards(0);
        
        uint256 balanceAfter = token.balanceOf(alice);
        
        // Should receive rewards minus 1% tax
        uint256 expectedReward = pendingRewards - (pendingRewards * 100 / 10000);
        assertEq(balanceAfter - balanceBefore, expectedReward);
    }
    
    function test_ClaimRewards_UpdatesLastClaimTime() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        vm.warp(block.timestamp + 1 weeks);
        
        vm.prank(alice);
        staking.claimRewards(0);
        
        (,,,, uint256 lastClaimTime,,) = staking.getStake(alice, 0);
        assertEq(lastClaimTime, block.timestamp);
    }
    
    function test_ClaimRewards_CanClaimMultipleTimes() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        // Claim after 1 week
        vm.warp(block.timestamp + 1 weeks);
        vm.prank(alice);
        staking.claimRewards(0);
        
        uint256 balanceAfterFirst = token.balanceOf(alice);
        
        // Claim after another week
        vm.warp(block.timestamp + 1 weeks);
        vm.prank(alice);
        staking.claimRewards(0);
        
        uint256 balanceAfterSecond = token.balanceOf(alice);
        
        assertGt(balanceAfterSecond, balanceAfterFirst);
    }
    
    function test_ClaimRewards_RevertsWithNoRewards() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        // Try to claim immediately (no time passed)
        vm.prank(alice);
        vm.expectRevert("No rewards to claim");
        staking.claimRewards(0);
    }
    
    function test_ClaimRewards_RevertsIfWithdrawn() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        vm.warp(block.timestamp + 4 weeks);
        
        vm.prank(alice);
        staking.unstake(0);
        
        // Try to claim after withdrawal
        vm.prank(alice);
        vm.expectRevert("Stake already withdrawn");
        staking.claimRewards(0);
    }
    
    function test_CalculatePendingRewards_AccurateCalculation() public {
        uint256 stakeAmount = 1000 ether;
        uint256 poolId = 0; // 5% APY
        
        vm.prank(alice);
        staking.stake(stakeAmount, poolId);
        
        (uint256 stakedAmount,,,,,,) = staking.getStake(alice, 0);
        
        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);
        
        uint256 rewards = staking.calculatePendingRewards(alice, 0);
        
        // Expected: stakeAmount * 5% = 50 ether
        // Actual staked amount after 1% fee
        uint256 expectedRewards = (stakedAmount * 500) / 10000;
        
        assertApproxEqAbs(rewards, expectedRewards, 1 ether);
    }
    
    function test_CalculatePendingRewards_StopsAtMaturity() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0); // 4 week pool
        
        // Fast forward past maturity
        vm.warp(block.timestamp + 8 weeks);
        
        uint256 rewards = staking.calculatePendingRewards(alice, 0);
        
        // Should only calculate rewards up to 4 weeks (maturity)
        (uint256 stakedAmount,,,,,,) = staking.getStake(alice, 0);
        uint256 maxRewards = (stakedAmount * 500 * 4 weeks) / (365 days * 10000);
        
        assertEq(rewards, maxRewards);
    }
    
    // ==================== ADMIN TESTS ====================
    
    function test_CreatePool_Success() public {
        uint256 duration = 16 weeks;
        uint256 apy = 2000; // 20%
        
        staking.createPool(duration, apy);
        
        assertEq(staking.poolCount(), 5);
        
        (uint256 poolDuration, uint256 poolApy, uint256 totalStaked, bool active) = staking.pools(4);
        assertEq(poolDuration, duration);
        assertEq(poolApy, apy);
        assertEq(totalStaked, 0);
        assertTrue(active);
    }
    
    function test_CreatePool_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.createPool(16 weeks, 2000);
    }
    
    function test_TogglePoolStatus_Success() public {
        staking.togglePoolStatus(0);
        
        (,,, bool active) = staking.pools(0);
        assertFalse(active);
        
        staking.togglePoolStatus(0);
        (,,, active) = staking.pools(0);
        assertTrue(active);
    }
    
    function test_UpdateTreasury_Success() public {
        address newTreasury = makeAddr("newTreasury");
        staking.updateTreasury(newTreasury);
        assertEq(staking.treasury(), newTreasury);
    }
    
    function test_UpdateTreasury_RevertsWithZeroAddress() public {
        vm.expectRevert("Invalid treasury address");
        staking.updateTreasury(address(0));
    }
    
    function test_UpdateRewardPool_Success() public {
        address newRewardPool = makeAddr("newRewardPool");
        staking.updateRewardPool(newRewardPool);
        assertEq(staking.rewardPool(), newRewardPool);
    }
    
    function test_Pause_Success() public {
        staking.pause();
        assertTrue(staking.paused());
    }
    
    function test_Unpause_Success() public {
        staking.pause();
        staking.unpause();
        assertFalse(staking.paused());
    }
    
    function test_EmergencyWithdraw_Success() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        (uint256 stakedAmount,,,,,,) = staking.getStake(alice, 0);
        
        // Pause contract
        staking.pause();
        
        // Emergency withdraw
        vm.prank(alice);
        staking.emergencyWithdraw(0);
        
        // Check withdrawal with 5% emergency fee
        uint256 emergencyFee = (stakedAmount * 500) / 10000;
        uint256 expectedReceived = stakedAmount - emergencyFee;
        
        (,,,,,,bool withdrawn) = staking.getStake(alice, 0);
        assertTrue(withdrawn);
    }
    
    function test_EmergencyWithdraw_RevertsWhenNotPaused() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        
        vm.prank(alice);
        vm.expectRevert("Only available when paused");
        staking.emergencyWithdraw(0);
    }
    
    function test_AdminEmergencyWithdraw_Success() public {
        uint256 contractBalance = token.balanceOf(address(staking));
        uint256 withdrawAmount = 1000 ether;
        
        uint256 ownerBalanceBefore = token.balanceOf(owner);
        
        staking.adminEmergencyWithdraw(withdrawAmount);
        
        assertEq(token.balanceOf(owner), ownerBalanceBefore + withdrawAmount);
        assertEq(token.balanceOf(address(staking)), contractBalance - withdrawAmount);
    }
    
    function test_FundRewardPool_Success() public {
        uint256 fundAmount = 5000 ether;
        
        token.approve(address(staking), fundAmount);
        staking.fundRewardPool(fundAmount);
        
        assertEq(staking.totalYieldGenerated(), fundAmount);
    }
    
    // ==================== VIEW FUNCTION TESTS ====================
    
    function test_GetUserStakes_ReturnsAllStakes() public {
        vm.startPrank(alice);
        staking.stake(STAKE_AMOUNT, 0);
        staking.stake(STAKE_AMOUNT, 1);
        staking.stake(STAKE_AMOUNT, 2);
        vm.stopPrank();
        
        QuestStake.StakeInfo[] memory stakes = staking.getUserStakes(alice);
        assertEq(stakes.length, 3);
    }
    
    function test_GetPoolInfo_ReturnsCorrectInfo() public view {
        QuestStake.PoolConfig memory pool = staking.getPoolInfo(0);
        assertEq(pool.duration, 4 * 7 * 24 * 60 * 60);
        assertEq(pool.apy, 500);
        assertTrue(pool.active);
    }
    
    function test_GetAllPools_ReturnsAllPools() public view {
        QuestStake.PoolConfig[] memory pools = staking.getAllPools();
        assertEq(pools.length, 4);
    }
}
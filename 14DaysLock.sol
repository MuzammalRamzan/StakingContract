/ SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Staking is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    IERC20 public lpToken;
    uint256 public lockPeriod = 2 minutes;
    uint256 public rewardPerBlock = 1e14;
    uint256 public blockPerMinutes = 20;

    struct Stake {
        uint256 stakedAmount;
        uint256 stakeTime;
        uint256 unstakeTime;
        uint256 startBlock;
        uint256 lastClaimedBlock;
        uint256 claimedRewards;
    }

    struct UserInfo {
        Stake[] stakes;
    }

    mapping(address => UserInfo) private userInfo;

    event Staked(address indexed user, uint256 amount,uint256 startTime, uint256 endTime);
    event RewardWithdrawn(address indexed user, uint256 reward);
    event Unstaked(address indexed user, uint256 reward,uint256 unstakeAmount );

    constructor(IERC20 _rewardToken) {
        lpToken = _rewardToken;
    }

    function stake(uint256 _tokenAmount) external nonReentrant {
        // require(msg.sender != owner(), "Owner cannot stake!");
        require(_tokenAmount > 0, "Staking amount must be greater than 0!");

        uint256 _stakeTime = block.timestamp;
        uint256 _unstakeTime = _stakeTime.add(lockPeriod);

        userInfo[msg.sender].stakes.push(Stake({
            stakedAmount: _tokenAmount,
            stakeTime: _stakeTime,
            unstakeTime : _unstakeTime,
            startBlock : block.number,
            lastClaimedBlock: block.number,
            claimedRewards: 0
        }));
        require(lpToken.transferFrom(msg.sender, address(this), _tokenAmount), "Token transfer failed!");

        emit Staked(msg.sender, _tokenAmount, _stakeTime, _unstakeTime);
    }

    function unstake() external {
        UserInfo storage user = userInfo[msg.sender];

        uint256 totalUnstakeAmount = 0;
        uint256 totalReward = 0;

        // Store indexes of stakes that need to be removed
        uint256[] memory toRemoveIndexes = new uint256[](user.stakes.length);
        uint256 removeCount = 0;

        for (uint256 i = 0; i < user.stakes.length; i++) {
            if (block.timestamp >= user.stakes[i].stakeTime.add(lockPeriod)) {
                uint256 stakeReward = calculateRewardForStake(msg.sender, i);
                totalReward = totalReward.add(stakeReward);
                totalUnstakeAmount = totalUnstakeAmount.add(user.stakes[i].stakedAmount);

                if (stakeReward > 0) {
                    withdrawReward();
                }
                toRemoveIndexes[removeCount] = i;
                removeCount++;
            }
        }

        require(removeCount > 0, "Lock time not completed yet.");

        for (uint256 j = removeCount; j > 0; j--) {
            if (toRemoveIndexes[j - 1] != user.stakes.length - 1) {
                user.stakes[toRemoveIndexes[j - 1]] = user.stakes[user.stakes.length - 1];
            }
            user.stakes.pop();
        }

        require(lpToken.transfer(msg.sender, totalUnstakeAmount), "Failed to transfer LP tokens.");

        emit Unstaked(msg.sender, totalReward, totalUnstakeAmount);
    }

    function calculatePercentage(address user) public view returns(uint256) {
        UserInfo storage userInformation = userInfo[user];
        uint256 userTotalStake = 0;
        for (uint256 i = 0; i < userInformation.stakes.length; i++) {
            userTotalStake = userTotalStake.add(userInformation.stakes[i].stakedAmount);
        }

        uint256 totalPoolBalance = lpToken.balanceOf(address(this));
        if (totalPoolBalance == 0) {
            return 0;
        }

        uint256 percentage = userTotalStake.mul(10000).div(totalPoolBalance); 
        return percentage;
    }
 
    function getUserRewardForBlock(address user) public view returns (uint256) {
        uint256 userPercentage = calculatePercentage(user);
        uint256 userReward = rewardPerBlock.mul(userPercentage).div(10000); 
        return userReward;
    }

    function withdrawReward() public  {
        require(msg.sender == tx.origin, "invalid caller!");
        UserInfo storage user = userInfo[msg.sender];
        uint256 totalRewards = 0;

        for (uint256 i = 0; i < user.stakes.length; i++) {
            Stake storage stakeInfo = user.stakes[i];
            uint256 reward = calculateRewardForStake(msg.sender, i); 
            
            totalRewards = totalRewards.add(reward);

            if (reward > 0) {
            stakeInfo.lastClaimedBlock = block.number;
            stakeInfo.claimedRewards = stakeInfo.claimedRewards.add(reward);
            }
        }

        require(totalRewards > 0, "No rewards to withdraw");
        require(address(this).balance >= totalRewards, "insufficient ETH Balance!");
        payable(msg.sender).transfer(totalRewards);

        emit RewardWithdrawn(msg.sender, totalRewards);
    }

    function calculateRewardForStake(address user, uint256 stakeIndex) public view returns (uint256) {
        Stake storage stakeInfo = userInfo[user].stakes[stakeIndex];

        uint256 endBlock = stakeInfo.startBlock.add(blockPerMinutes.mul(2));
        uint256 blockToCalculateUntil = (block.number < endBlock) ? block.number : endBlock;

        if (stakeInfo.lastClaimedBlock >= blockToCalculateUntil) {
            return 0;
        }

        uint256 blocksSinceLastClaim = blockToCalculateUntil.sub(stakeInfo.lastClaimedBlock);
        return getUserRewardForBlock(user).mul(blocksSinceLastClaim);
    }

    function calculateRewardSinceLastClaim(address user) public view returns (uint256) {
        uint256 totalReward = 0;
        for (uint256 i = 0; i < userInfo[user].stakes.length; i++) {
            totalReward = totalReward.add(calculateRewardForStake(user, i));
        }
        return totalReward;
    }

    function checkRemainingTimeAndBlocks(address user) public view returns(uint256[] memory remainingTimes, uint256[] memory remainingBlocks){
        UserInfo storage userInformation = userInfo[user];
        
        uint256[] memory _remainingTimes = new uint256[](userInformation.stakes.length);
        uint256[] memory _remainingBlocks = new uint256[](userInformation.stakes.length);

        for(uint256 i = 0; i < userInformation.stakes.length; i++) {
            Stake storage stakeInfo = userInformation.stakes[i];
            
            uint256 endBlock = stakeInfo.startBlock.add(blockPerMinutes.mul(2));
            _remainingBlocks[i] = (block.number >= endBlock) ? 0 : endBlock.sub(block.number);
            _remainingTimes[i] = _remainingBlocks[i].mul(3); // Assuming an average block time of 13 seconds for Ethereum
            
            if(block.timestamp >= stakeInfo.unstakeTime) {
                _remainingTimes[i] = 0; 
            }
        }
        return (_remainingTimes, _remainingBlocks);
    }

    function checkRemainingTime(address user) external view returns(uint256[] memory){
        UserInfo storage userInformation = userInfo[user];
        uint256[] memory remainingTimes = new uint256[](userInformation.stakes.length);

        for(uint256 i = 0; i < userInformation.stakes.length; i++) {
            Stake storage stakeInfo = userInformation.stakes[i];
            if(block.timestamp < stakeInfo.unstakeTime) {
                remainingTimes[i] = stakeInfo.unstakeTime.sub(block.timestamp);
            } else {
                remainingTimes[i] = 0; 
            }
        }
        return remainingTimes;
    }

    function getAllStakeDetails(address _user) external view returns (uint256[] memory stakeIndices, Stake[] memory stakes) {
        UserInfo storage user = userInfo[_user];
        stakeIndices = new uint256[](user.stakes.length);
        stakes = user.stakes;

        for (uint256 i = 0; i < user.stakes.length; i++) {
            stakeIndices[i] = i;
        }

        return (stakeIndices, stakes);
    }

    function getCurrentBlock() public view returns(uint256) {
        return block.number;
    }
    function updateBlockPerMinutes(uint256 _blockPerMinute) external onlyOwner  {
    blockPerMinutes=_blockPerMinute;

    }

    function emergencyWithdrawLpTokens()external  onlyOwner{
        uint256 balanceOfContract=lpToken.balanceOf(address(this));
        lpToken.transfer(owner(), balanceOfContract);
    }

    function withdrawETH() external onlyOwner {
        payable (owner()).transfer(address(this).balance);
    }
    receive() external payable {}
}
please check here emergencyWithdrawLpTokens and updateBlockPerMinutes are correct? do I need to update anything here?
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract free_Staking is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    IERC20 public lpToken;

    uint256 public rewardPerBlock ;
    uint256 public blockPerMinutes ;
    uint256 public unstakeAfterTime ;
    uint256 public unstakeRequestTime;

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

    struct UnstakeRequest {
        address user;
        uint256 stakeIndex;
    }

    UnstakeRequest[] private unstakeRequestList;

    mapping(address => UserInfo) private userInfo;
    mapping(address => mapping(uint256 => bool)) private unstakeApproval;
    mapping(address => mapping(uint256 => bool)) private unstakeRequestMap;


    event Staked(address indexed user, uint256 amount,uint256 startTime);
    event RewardWithdrawn(address indexed user, uint256 reward);
    event Unstaked(address indexed user, uint256 reward,uint256 unstakeAmount );

    constructor(IERC20 _stakeToken) {
        lpToken = _stakeToken;
        blockPerMinutes = 20;
        rewardPerBlock = 1e14;
        unstakeRequestTime = 2 minutes;
        unstakeAfterTime = 3 minutes;
    }

    function stake(uint256 _tokenAmount) external {
        require(msg.sender == tx.origin, "Invalid caller!");
        require(_tokenAmount > 0, "Staking amount must be greater than 0!");
        _stakeTokens(msg.sender, _tokenAmount);
    }

    function _stakeTokens(address user, uint256 amount) internal {
        uint256 _stakeTime = block.timestamp;
        userInfo[user].stakes.push(Stake({
            stakedAmount: amount,
            stakeTime: _stakeTime,
            unstakeTime: 0,
            startBlock: block.number,
            lastClaimedBlock: block.number,
            claimedRewards: 0
        }));

        require(lpToken.transferFrom(user, address(this), amount), "Token transfer failed!");
        emit Staked(user, amount, _stakeTime);
    }

    // Users call this function to request unstaking
    function requestUnstake(uint256 stakeIndex) external {
        UserInfo storage user = userInfo[msg.sender];
        require(stakeIndex < user.stakes.length, "Invalid stake index");
        require(!unstakeRequestMap[msg.sender][stakeIndex], "Unstake request already made for this index");
        
        Stake storage stakeInfo = user.stakes[stakeIndex];
        require(block.timestamp >= stakeInfo.stakeTime.add(unstakeRequestTime), "Minimum staking time not met. Can't request unstake yet.");
        
        unstakeRequestMap[msg.sender][stakeIndex] = true;
        unstakeRequestList.push(UnstakeRequest({
            user: msg.sender,
            stakeIndex: stakeIndex
        }));
    }

    function approvalUnstakeRequest(address user, uint256 stakeIndex) external onlyOwner {
        Stake storage stakeInfo = userInfo[user].stakes[stakeIndex];
        require(unstakeRequestMap[user][stakeIndex] == true, "Unstake request not found for this index");
        stakeInfo.unstakeTime = block.timestamp.add(unstakeAfterTime);
        unstakeApproval[user][stakeIndex] = true;

        // Find the correct index in the unstakeRequestList
        uint256 requestListIndex;
        bool found = false;
        for(uint256 i = 0; i < unstakeRequestList.length; i++) {
            if(unstakeRequestList[i].user == user && unstakeRequestList[i].stakeIndex == stakeIndex) {
                requestListIndex = i;
                found = true;
                break;
            }
        }

        require(found, "Unstake request not found in the list");

        // Remove from the unstakeRequestList
        if (requestListIndex < unstakeRequestList.length - 1) {
            unstakeRequestList[requestListIndex] = unstakeRequestList[unstakeRequestList.length - 1];
        }
        unstakeRequestList.pop();

        // Clear the request map
        unstakeRequestMap[user][stakeIndex] = false;
    }

    function unstake(uint256 stakeIndex) external {
        UserInfo storage user = userInfo[msg.sender];
        
        require(stakeIndex < user.stakes.length, "Invalid stake index");
        require(user.stakes[stakeIndex].unstakeTime > 0, "Unstaking has not been approved for this stake yet");
        require(block.timestamp >= user.stakes[stakeIndex].unstakeTime, "The unstake time has not been reached yet");

        uint256 stakeReward = calculateRewardForStake(msg.sender, stakeIndex);
        uint256 totalUnstakeAmount = user.stakes[stakeIndex].stakedAmount;

        if (stakeReward > 0) {
            withdrawReward();
        }
        if (stakeIndex != user.stakes.length - 1) {
            user.stakes[stakeIndex] = user.stakes[user.stakes.length - 1];
        }
        user.stakes.pop();

        require(totalUnstakeAmount > 0, "No stakes found.");
        require(lpToken.transfer(msg.sender, totalUnstakeAmount), "Failed to transfer LP tokens.");

        emit Unstaked(msg.sender, stakeReward, totalUnstakeAmount);
    }

    function canUnstakeAny(address user) public view returns(bool, uint256[] memory) {
        UserInfo storage userInformation = userInfo[user];

        // Counting how many stakes can be unstaked
        uint256 count = 0;
        for(uint256 i = 0; i < userInformation.stakes.length; i++) {
            if(userInformation.stakes[i].unstakeTime > 0 && block.timestamp >= userInformation.stakes[i].unstakeTime) {
                count++;
            }
        }

        uint256[] memory completedStakeIndices = new uint256[](count);

        uint256 j = 0;
        for(uint256 i = 0; i < userInformation.stakes.length && j < count; i++) {
            if(userInformation.stakes[i].unstakeTime > 0 && block.timestamp >= userInformation.stakes[i].unstakeTime) {
                completedStakeIndices[j] = i;
                j++;
            }
        }

        if (j == 0) { // No stakes are available for unstaking
            return (false, new uint256[](0));
        } else {
            return (true, completedStakeIndices);
        }
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
        uint256 blockToCalculateUntil = block.number; 

        if(stakeInfo.unstakeTime > 0) {
            uint256 elapsedSeconds = stakeInfo.unstakeTime.sub(stakeInfo.stakeTime);
            uint256 elapsedBlocks = elapsedSeconds.div(60).mul(blockPerMinutes);
            uint256 unstakeBlock = stakeInfo.startBlock.add(elapsedBlocks);

            if (unstakeBlock < blockToCalculateUntil) {
                blockToCalculateUntil = unstakeBlock; 
            }
        }
        if (stakeInfo.lastClaimedBlock >= blockToCalculateUntil) {
            return 0;
        }

        uint256 blocksSinceLastClaim = blockToCalculateUntil.sub(stakeInfo.lastClaimedBlock);
        return getUserRewardForBlock(user).mul(blocksSinceLastClaim);
    }

    function calculateRewardSinceLastClaim(address user) external view returns (uint256) {
        uint256 totalReward = 0;
        for (uint256 i = 0; i < userInfo[user].stakes.length; i++) {
            totalReward = totalReward.add(calculateRewardForStake(user, i));
        }
        return totalReward;
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

    function updateRequestTime(uint256 _time) external {
        unstakeRequestTime = _time.mul(1 minutes);
    }

    function updateUnstakeTime(uint256 _time) external {
        unstakeAfterTime = _time.mul(1 minutes);
    }

    function emergencyWithdrawLP() external onlyOwner{
        uint256 balance = IERC20(lpToken).balanceOf(address(this));
        require(balance > 0,"insufficint LP Balance!");
        require(IERC20(lpToken).transfer(msg.sender,balance),"transfer failed!");
    }

    function withdrawETH() external  onlyOwner{
        payable (owner()).transfer(address(this).balance);
    }
 
    function readyToUnstakeRequest(address _user) external view returns(uint256[] memory) {
        UserInfo storage userInformation = userInfo[_user];
        uint256 count = 0;
        for(uint256 i = 0; i < userInformation.stakes.length; i++) {
            if(block.timestamp >= userInformation.stakes[i].stakeTime.add(unstakeRequestTime) && !unstakeRequestMap[_user][i]) {
                count++;
            }
        }

        uint256[] memory readyIndices = new uint256[](count);
        uint256 j = 0;
        for(uint256 i = 0; i < userInformation.stakes.length && j < count; i++) {
            if(block.timestamp >= userInformation.stakes[i].stakeTime.add(unstakeRequestTime) && !unstakeRequestMap[_user][i]) {
                readyIndices[j] = i;
                j++;
            }
        }
        return readyIndices;
    }

    function getAllUnstakeRequests() external view returns(UnstakeRequest[] memory) {
        return unstakeRequestList;
    }

    receive() external payable {}
}
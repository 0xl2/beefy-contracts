// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;
pragma abicoder v1;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../interfaces/common/IUniswapRouterETH.sol";

contract BeefyFeeBatch is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address public wNative ;
    address public bifi;

    address public treasury;
    address public rewardPool;
    address public unirouter;

    // Fee constants
    uint constant public TREASURY_FEE = 140;
    uint constant public REWARD_POOL_FEE = 860;
    uint constant public MAX_FEE = 1000;

    address[] public wNativeToBifiRoute;

    constructor(
        address _treasury,
        address _rewardPool,
        address _unirouter,
        address _bifi,
        address _wNative
    ) {
        treasury = _treasury;
        rewardPool = _rewardPool;
        unirouter = _unirouter;
        bifi = _bifi;
        wNative  = _wNative ;

        wNativeToBifiRoute = [wNative, bifi];

        IERC20(wNative).safeApprove(unirouter, type(uint256).max);
    }

    event NewRewardPool(address oldRewardPool, address newRewardPool);
    event NewTreasury(address oldTreasury, address newTreasury);
    event NewUnirouter(address oldUnirouter, address newUnirouter);
    event NewBifiRoute(address[] oldRoute, address[] newRoute);

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "!EOA");
        _;
    }

    // Main function. Divides Beefy's profits.
    function harvest() public onlyEOA {
        uint256 wNativeBal = IERC20(wNative).balanceOf(address(this));

        uint256 treasuryHalf = wNativeBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wNative).safeTransfer(treasury, treasuryHalf);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wNativeToBifiRoute, treasury, block.timestamp);

        uint256 rewardsFeeAmount = wNativeBal.mul(REWARD_POOL_FEE).div(MAX_FEE);
        IERC20(wNative).safeTransfer(rewardPool, rewardsFeeAmount);
    }

    // Manage the contract
    function setRewardPool(address _rewardPool) external onlyOwner {
        emit NewRewardPool(rewardPool, _rewardPool);
        rewardPool = _rewardPool;
    }

    function setTreasury(address _treasury) external onlyOwner {
        emit NewTreasury(treasury, _treasury);
        treasury = _treasury;
    }

    function setUnirouter(address _unirouter) external onlyOwner {
        emit NewUnirouter(unirouter, _unirouter);

        IERC20(wNative).safeApprove(_unirouter, type(uint256).max);
        IERC20(wNative).safeApprove(unirouter, 0);

        unirouter = _unirouter;
    }

    function setNativeToBifiRoute(address[] memory _route) external onlyOwner {
        require(_route[0] == wNative);
        require(_route[_route.length - 1] == bifi);

        emit NewBifiRoute(wNativeToBifiRoute, _route);
        wNativeToBifiRoute = _route;
    }

    // Rescue locked funds sent by mistake
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        require(_token != wNative, "!safe");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }
}
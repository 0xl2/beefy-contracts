// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;
pragma abicoder v1;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../../interfaces/common/IUniswapRouter.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/common/IMultiFeeDistribution.sol";
import "../../interfaces/ellipsis/IEps2LP.sol";
import "../../interfaces/ellipsis/ILpStaker.sol";
import "../../utils/GasThrottler.sol";

/**
 * @dev Implementation of a strategy to get yields from farming RenBTC LP on Ellipsis.
 */
contract StrategyEllipsisRen is Ownable, Pausable, GasThrottler {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb, btcb} - Required for liquidity routing when doing swaps.
     * {eps} - Token generated by staking our funds. In this case it's the EPS token.
     * {bifi} - BeefyFinance token, used to send funds to the treasury.
     * {want} - Token that the strategy maximizes. The same token that users deposit in the vault. btcEPS
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public btcb = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant public eps  = address(0xA7f552078dcC247C2684336020c03648500C6d9F);
    address constant public bifi = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    address constant public want = address(0x2a435Ecb3fcC0E316492Dc1cdd62d0F189be5640);

    /**
     * @dev Third Party Contracts:
     * {unirouter} - PancakeSwap unirouter
     * {stakingPool} - LpTokenStaker contract
     * {feeDistribution} - MultiFeeDistribution contract
     * {poolLP} - RenBTC LP contract to deposit renBTC/BTCB and mint {want}
     * {poolId} - LpTokenStaker pool id
     */
    address constant public unirouter       = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address constant public stakingPool     = address(0xcce949De564fE60e7f96C85e55177F8B9E4CF61b);
    address constant public feeDistribution = address(0x4076CC26EFeE47825917D0feC3A79d0bB9a6bB5c);
    address constant public poolLp          = address(0x2477fB288c5b4118315714ad3c7Fd7CC69b00bf9);
    uint8 constant public poolId = 3;

    /**
     * @dev Beefy Contracts:
     * {rewards} - Reward pool where the strategy fee earnings will go.
     * {treasury} - Address of the BeefyFinance treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     */
    address constant public rewards  = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address constant public treasury = address(0x4A32De8c248533C28904b24B4cFCFE18E9F2ad01);
    address public vault;
    address public strategist;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 4.5% for fees.
     *
     * {REWARDS_FEE} - 3% goes to BIFI holders through the {rewards} pool.
     * {CALL_FEE} - 0.5% goes to whoever executes the harvest function as gas subsidy.
     * {TREASURY_FEE} - 0.5% goes to the treasury.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public REWARDS_FEE    = 665;
    uint constant public CALL_FEE       = 111;
    uint constant public TREASURY_FEE   = 112;
    uint constant public STRATEGIST_FEE = 112;
    uint constant public MAX_FEE        = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using PancakeSwap.
     * {epsToWbnbRoute} - Route we take to go from {eps} into {wbnb}.
     * {wbnbToBifiRoute} - Route we take to go from {wbnb} into {bifi}.
     * {epsToBtcbRoute} - Route we take to get from {eps} into {btcb}.
     */
    address[] public epsToWbnbRoute  = [eps, wbnb];
    address[] public wbnbToBifiRoute = [wbnb, bifi];
    address[] public epsToBtcbRoute  = [eps, wbnb, btcb];

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _vault, address _strategist) {
        vault = _vault;
        strategist = _strategist;

        IERC20(want).safeApprove(stakingPool, type(uint).max);
        IERC20(eps).safeApprove(unirouter, type(uint).max);
        IERC20(wbnb).safeApprove(unirouter, type(uint).max);
        IERC20(btcb).safeApprove(poolLp, type(uint).max);
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {want} in the Pool to farm {eps}
     */
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            ILpStaker(stakingPool).deposit(poolId, wantBal);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {want} from the Pool.
     * The available {want} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            ILpStaker(stakingPool).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFee = wantBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFee));
        }
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the Pool.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {eps} token for {btcb}.
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function harvest() external whenNotPaused gasThrottle {
        require(tx.origin == msg.sender, "!contract");

        uint256[] memory pids = new uint256[](1);
        pids[0] = poolId;
        ILpStaker(stakingPool).claim(pids);
        IMultiFeeDistribution(feeDistribution).exit();

        chargeFees();
        swapRewards();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards.
     * 0.5% -> Call Fee
     * 0.5% -> Treasury fee
     * 0.5% -> Strategist fee
     * 3.0% -> BIFI Holders
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(eps).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouter(unirouter).swapExactTokensForTokens(toWbnb, 0, epsToWbnbRoute, address(this), block.timestamp.add(600));

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);

        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        IUniswapRouter(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToBifiRoute, treasury, block.timestamp.add(600));

        uint256 rewardsFee = wbnbBal.mul(REWARDS_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFee);

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Swaps {eps} rewards earned for {btcb} and adds to Eps LP.
     */
    function swapRewards() internal {
        uint256 epsBal = IERC20(eps).balanceOf(address(this));
        IUniswapRouter(unirouter).swapExactTokensForTokens(epsBal, 0, epsToBtcbRoute, address(this), block.timestamp.add(600));

        uint256 btcbBal = IERC20(btcb).balanceOf(address(this));
        uint256[2] memory amounts = [btcbBal, 0];
        IEps2LP(poolLp).add_liquidity(amounts, 0);
    }

    /**
     * @dev Function to calculate the total underlying {want} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the Pool.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {want} the contract holds.
     */
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {want} the strategy has allocated in the Pool
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = ILpStaker(stakingPool).userInfo(poolId, address(this));
        return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        ILpStaker(stakingPool).emergencyWithdraw(poolId);

        uint256 pairBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, pairBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the Pool, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        ILpStaker(stakingPool).emergencyWithdraw(poolId);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(want).safeApprove(stakingPool, 0);
        IERC20(eps).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
        IERC20(btcb).safeApprove(poolLp, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(want).safeApprove(stakingPool, type(uint).max);
        IERC20(eps).safeApprove(unirouter, type(uint).max);
        IERC20(wbnb).safeApprove(unirouter, type(uint).max);
        IERC20(btcb).safeApprove(poolLp, type(uint).max);
    }

    /**
     * @dev Updates address where strategist fee earnings will go.
     * @param _strategist new strategist address.
     */
    function setStrategist(address _strategist) external {
        require(msg.sender == strategist, "!strategist");
        strategist = _strategist;
    }
}
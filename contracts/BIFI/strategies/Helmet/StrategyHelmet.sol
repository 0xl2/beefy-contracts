// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;
pragma abicoder v1;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/helmet/IStakingRewards.sol";

/**
 * @dev Implementation of a strategy to get yields from farming HELMET in Helmet Insure.
 * PancakeSwap is an automated market maker (“AMM”) that allows two tokens to be exchanged on the Binance Smart Chain.
 * It is fast, cheap, and allows anyone to participate. PancakeSwap is aiming to be the #1 liquidity provider on BSC.
 *
 * This strategy simply deposits whatever funds it receives from the vault into the selected StakingRewards pool.
 * HELMET rewards from providing liquidity are farmed every few minutes and sold.
 * The corresponding pair of assets are bought and more liquidity is added to the StakingRewards pool.
 */
contract StrategyHelmet is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {helmet} - Token generated by staking our funds. In this case it's the HELMETs token.
     * {bifi} - BeefyFinance token, used to send funds to the treasury.
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public helmet = address(0x948d2a81086A075b3130BAc19e4c6DEe1D2E3fE8);
    address constant public bifi = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);

    /**
     * @dev Third Party Contracts:
     * {unirouter} - PancakeSwap unirouter
     * {stakingRewards} - IStakingRewards contract
     */
    address constant public unirouter  = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address constant public stakingRewards = address(0x279a073C491C873DF040B05cc846A3c47252b52c);

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
     * {helmetToWbnbRoute} - Route we take to get from {helmet} into {wbnb}.
     * {wbnbToBifiRoute} - Route we take to get from {wbnb} into {bifi}.
     */
    address[] public helmetToWbnbRoute = [helmet, wbnb];
    address[] public wbnbToBifiRoute = [wbnb, bifi];

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

        IERC20(helmet).safeApprove(stakingRewards, type(uint).max);
        IERC20(helmet).safeApprove(unirouter, type(uint).max);
        IERC20(wbnb).safeApprove(unirouter, type(uint).max);
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {helmet} in the stakingRewards to farm {helmet}
     */
    function deposit() public whenNotPaused {
        uint256 helmetBal = IERC20(helmet).balanceOf(address(this));

        if (helmetBal > 0) {
            IStakingRewards(stakingRewards).stake(helmetBal);
        }
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {helmet} from the StakingRewards.
     * The available {helmet} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 helmetBal = IERC20(helmet).balanceOf(address(this));

        if (helmetBal < _amount) {
            IStakingRewards(stakingRewards).withdraw(_amount.sub(helmetBal));
            IStakingRewards(stakingRewards).getReward();
            helmetBal = IERC20(helmet).balanceOf(address(this));
        }

        if (helmetBal > _amount) {
            helmetBal = _amount;
        }

        uint256 withdrawalFee = helmetBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
        IERC20(helmet).safeTransfer(vault, helmetBal.sub(withdrawalFee));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the StakingRewards.
     * 2. It charges the system fees to simplify the split.
     * 3. It deposits the new tokens.
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IStakingRewards(stakingRewards).getReward();
        chargeFees();
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
        uint256 toWbnb = IERC20(helmet).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toWbnb, 0, helmetToWbnbRoute, address(this), block.timestamp.add(600));

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);

        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToBifiRoute, treasury, block.timestamp.add(600));

        uint256 rewardsFee = wbnbBal.mul(REWARDS_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFee);

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Function to calculate the total underlaying {helmet} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the StakingRewards.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfHelmet().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {helmet} the contract holds.
     */
    function balanceOfHelmet() public view returns (uint256) {
        return IERC20(helmet).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {helmet} the strategy has allocated in the IStakingRewards
     */
    function balanceOfPool() public view returns (uint256) {
        return IStakingRewards(stakingRewards).balanceOf(address(this));
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IStakingRewards(stakingRewards).withdraw(balanceOfPool());

        uint256 helmetBal = IERC20(helmet).balanceOf(address(this));
        IERC20(helmet).transfer(vault, helmetBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the StakingRewards, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IStakingRewards(stakingRewards).withdraw(balanceOfPool());
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(helmet).safeApprove(stakingRewards, 0);
        IERC20(helmet).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(helmet).safeApprove(stakingRewards, type(uint).max);
        IERC20(helmet).safeApprove(unirouter, type(uint).max);
        IERC20(wbnb).safeApprove(unirouter, type(uint).max);
    }
}

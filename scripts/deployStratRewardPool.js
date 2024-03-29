const hardhat = require("hardhat");

const registerSubsidy = require("../utils/registerSubsidy");
const predictAddresses = require("../utils/predictAddresses");
const getNetworkRpc = require("../utils/getNetworkRpc");

const ethers = hardhat.ethers;

const config = {
  want: "0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51",
  output: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
  targetRewardPool: "0xCADc8CB26c8C7cB46500E61171b5F27e9bd7889D",
  mooName: "Moo Bunny",
  mooSymbol: "mooBunny",
  delay: 21600,
  keeper: "0x9295E05d5cd1cfA617875Ba1cF984D65830d1a4c",
  strategist: "0xB60d9512CC129f539313b7Bdbd13bBa1Fd2fE3C3",
};

async function main() {
  await hardhat.run("compile");

  const Vault = await ethers.getContractFactory("BeefyVaultV5");
  const Strategy = await ethers.getContractFactory("StrategyRewardPoolBsc");

  const [deployer] = await ethers.getSigners();
  const rpc = getNetworkRpc(hardhat.network.name);

  console.log("Deploying:", config.mooName);

  const predictedAddresses = await predictAddresses({ creator: deployer.address, rpc });

  const vault = await Vault.deploy(
    config.want,
    predictedAddresses.strategy,
    config.mooName,
    config.mooSymbol,
    config.delay,
    { gasLimit: 4000000, gasPrice: 6000000000 }
  );
  await vault.deployed();

  const strategy = await Strategy.deploy(
    config.want,
    config.output,
    config.targetRewardPool,
    predictedAddresses.vault,
    config.keeper,
    config.strategist,
    { gasLimit: 4000000, gasPrice: 6000000000 }
  );
  await strategy.deployed();

  console.log("Vault deployed to:", vault.address);
  console.log("Strategy deployed to:", strategy.address);

  await registerSubsidy(vault.address, deployer);
  await registerSubsidy(strategy.address, deployer);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

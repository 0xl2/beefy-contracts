const hardhat = require("hardhat");

const ethers = hardhat.ethers;

const config = {
  staked: "0xD65eA2c4AaC316f410CF64ED5c2F36A2D455BAFc",
  rewards: "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83",
  bsFTM: '0xD65eA2c4AaC316f410CF64ED5c2F36A2D455BAFc',
};

async function main() {
  await hardhat.run("compile");

  const Pool = await ethers.getContractFactory("BeefybsFTMRewardPool");
  const pool = await Pool.deploy(config.staked, config.rewards, config.bsFTM);
  await pool.deployed();

  console.log("Reward pool deployed to:", pool.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });

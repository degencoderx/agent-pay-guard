import "dotenv/config";
import { ethers, network } from "hardhat";

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
];

function fmtUsdc(amount: bigint): string {
  return ethers.formatUnits(amount, 6);
}

async function main(): Promise<void> {
  const [buyer, provider] = await ethers.getSigners();

  console.log(`\nLocal hardhat network`);
  console.log(`Buyer:    ${buyer.address}`);
  console.log(`Provider: ${provider.address}`);

  const MockUSDC = await ethers.getContractFactory("MockUSDC", buyer);
  const mock = await MockUSDC.deploy();
  await mock.waitForDeployment();

  const mockAddr = await mock.getAddress();
  console.log(`MockUSDC: ${mockAddr}`);

  // Mint buyer 1000 USDC
  await (await mock.mint(buyer.address, ethers.parseUnits("1000", 6))).wait();

  const AgentPayGuard = await ethers.getContractFactory("AgentPayGuard", buyer);
  const guard = await AgentPayGuard.deploy(mockAddr);
  await guard.waitForDeployment();

  const guardAddr = await guard.getAddress();
  console.log(`AgentPayGuard: ${guardAddr}`);

  const usdc = new ethers.Contract(mockAddr, ERC20_ABI, buyer);

  const maxPerIntent = ethers.parseUnits("5", 6);
  const timelockSeconds = 60;
  const disputeWindowSeconds = 60;

  await (await guard.setPolicy(maxPerIntent, timelockSeconds, disputeWindowSeconds)).wait();
  await (await guard.setRecipientAllowed(provider.address, true)).wait();

  const depositAmount = ethers.parseUnits("10", 6);
  await (await usdc.approve(guardAddr, depositAmount)).wait();
  await (await guard.deposit(depositAmount)).wait();

  const chain = await ethers.provider.getNetwork();
  const now = Math.floor(Date.now() / 1000);

  const intent = {
    owner: buyer.address,
    recipient: provider.address,
    amount: ethers.parseUnits("2", 6),
    jobId: ethers.id("JOB-LOCAL"),
    nonce: 1n,
    expiry: now + 3600,
  };

  const domain = {
    name: "AgentPayGuard",
    version: "1",
    chainId: chain.chainId,
    verifyingContract: guardAddr,
  };

  const types = {
    PaymentIntent: [
      { name: "owner", type: "address" },
      { name: "recipient", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "jobId", type: "bytes32" },
      { name: "nonce", type: "uint256" },
      { name: "expiry", type: "uint48" },
    ],
  } as const;

  const sig = await buyer.signTypedData(domain, types, intent);

  const intentHash = await guard.hashIntent(intent);

  await (await guard.connect(provider).createIntent(intent, sig)).wait();
  await (await guard.connect(provider).claimIntent(intentHash, ethers.id("EVIDENCE:local"))).wait();

  console.log(`\nBalances (before finalize)`);
  const [bb, pb] = await Promise.all([
    usdc.balanceOf(buyer.address) as Promise<bigint>,
    usdc.balanceOf(provider.address) as Promise<bigint>,
  ]);
  console.log(`  buyer:    ${fmtUsdc(bb)} USDC`);
  console.log(`  provider: ${fmtUsdc(pb)} USDC`);

  // Fast-forward local time
  await network.provider.send("evm_increaseTime", [timelockSeconds + 1]);
  await network.provider.send("evm_mine");

  await (await guard.finalizeIntent(intentHash)).wait();

  console.log(`\nBalances (after finalize)`);
  const [ba, pa] = await Promise.all([
    usdc.balanceOf(buyer.address) as Promise<bigint>,
    usdc.balanceOf(provider.address) as Promise<bigint>,
  ]);
  console.log(`  buyer:    ${fmtUsdc(ba)} USDC`);
  console.log(`  provider: ${fmtUsdc(pa)} USDC`);

  console.log("\nDone.");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});

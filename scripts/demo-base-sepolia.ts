import "dotenv/config";
import { ethers } from "hardhat";

const USDC_BASE_SEPOLIA = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const BASESCAN_TX = (txHash: string) => `https://sepolia.basescan.org/tx/${txHash}`;

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)",
];

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v || v.trim() === "") {
    throw new Error(`Missing env var: ${name}`);
  }
  return v;
}

function fmtUsdc(amount: bigint): string {
  return ethers.formatUnits(amount, 6);
}

async function main(): Promise<void> {
  const providerPk = requireEnv("PROVIDER_PRIVATE_KEY");

  const buyer = (await ethers.getSigners())[0];
  const provider = new ethers.Wallet(providerPk, ethers.provider);

  const chain = await ethers.provider.getNetwork();
  console.log(`\nNetwork: ${chain.name} (chainId=${chain.chainId})`);
  console.log(`Buyer:    ${buyer.address}`);
  console.log(`Provider: ${provider.address}`);

  const usdc = new ethers.Contract(USDC_BASE_SEPOLIA, ERC20_ABI, buyer);

  const [buyerBalBefore, providerBalBefore] = await Promise.all([
    usdc.balanceOf(buyer.address) as Promise<bigint>,
    usdc.balanceOf(provider.address) as Promise<bigint>,
  ]);

  console.log(`\nUSDC balances (before)`);
  console.log(`  buyer:    ${fmtUsdc(buyerBalBefore)} USDC`);
  console.log(`  provider: ${fmtUsdc(providerBalBefore)} USDC`);

  const AgentPayGuard = await ethers.getContractFactory("AgentPayGuard", buyer);
  const guard = await AgentPayGuard.deploy(USDC_BASE_SEPOLIA);
  await guard.waitForDeployment();

  const guardAddr = await guard.getAddress();
  console.log(`\nDeployed AgentPayGuard: ${guardAddr}`);

  // Policy: cap + short timelock (to avoid waiting forever on real testnet)
  const maxPerIntent = ethers.parseUnits("5", 6); // 5 USDC cap
  const timelockSeconds = 15;
  const disputeWindowSeconds = 15;

  {
    const tx = await guard.setPolicy(maxPerIntent, timelockSeconds, disputeWindowSeconds);
    const receipt = await tx.wait();
    console.log(`Policy set: cap=5 USDC timelock=${timelockSeconds}s dispute=${disputeWindowSeconds}s`);
    if (receipt) console.log(`  ${BASESCAN_TX(receipt.hash)}`);
  }

  {
    const tx = await guard.setRecipientAllowed(provider.address, true);
    const receipt = await tx.wait();
    console.log(`Recipient allowlisted: ${provider.address}`);
    if (receipt) console.log(`  ${BASESCAN_TX(receipt.hash)}`);
  }

  const depositAmount = ethers.parseUnits("10", 6); // 10 USDC

  {
    const allowance = (await usdc.allowance(buyer.address, guardAddr)) as bigint;
    if (allowance < depositAmount) {
      const tx = await usdc.approve(guardAddr, depositAmount);
      const receipt = await tx.wait();
      console.log(`\nApproved vault to spend ${fmtUsdc(depositAmount)} USDC`);
      if (receipt) console.log(`  ${BASESCAN_TX(receipt.hash)}`);
    }
  }

  {
    const tx = await guard.deposit(depositAmount);
    const receipt = await tx.wait();
    console.log(`Deposited ${fmtUsdc(depositAmount)} USDC into vault`);
    if (receipt) console.log(`  ${BASESCAN_TX(receipt.hash)}`);
  }

  const now = Math.floor(Date.now() / 1000);
  const expiry = now + 60 * 30; // 30 minutes

  const intent = {
    owner: buyer.address,
    recipient: provider.address,
    amount: ethers.parseUnits("2", 6),
    jobId: ethers.id("JOB-123"),
    nonce: 1n,
    expiry,
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

  const signature = await buyer.signTypedData(domain, types, intent);

  console.log(`\nCreate intent: pay 2 USDC to provider (nonce=1)`);
  const createTx = await guard.connect(provider).createIntent(intent, signature);
  const createRc = await createTx.wait();
  if (createRc) console.log(`  ${BASESCAN_TX(createRc.hash)}`);

  const intentHash = await guard.hashIntent(intent);
  console.log(`Intent hash: ${intentHash}`);

  console.log(`\nClaim intent (provider)`);
  const evidenceHash = ethers.id("EVIDENCE:demo");
  const claimTx = await guard.connect(provider).claimIntent(intentHash, evidenceHash);
  const claimRc = await claimTx.wait();
  if (claimRc) console.log(`  ${BASESCAN_TX(claimRc.hash)}`);

  console.log(`\nAttack harness (expected failures)`);

  // 1) Wrong recipient (not allowlisted)
  {
    const attacker = ethers.Wallet.createRandom().address;
    const badIntent = { ...intent, recipient: attacker, nonce: 2n };
    const badSig = await buyer.signTypedData(domain, types, badIntent);

    try {
      await guard.connect(provider).createIntent(badIntent, badSig);
      console.log("  [unexpected] wrong-recipient intent succeeded");
    } catch (e: any) {
      console.log("  [ok] wrong recipient blocked");
      console.log(`       ${e.shortMessage ?? e.message}`);
    }
  }

  // 2) Overspend beyond cap
  {
    const bigIntent = { ...intent, amount: ethers.parseUnits("6", 6), nonce: 3n };
    const bigSig = await buyer.signTypedData(domain, types, bigIntent);

    try {
      await guard.connect(provider).createIntent(bigIntent, bigSig);
      console.log("  [unexpected] overspend intent succeeded");
    } catch (e: any) {
      console.log("  [ok] overspend blocked");
      console.log(`       ${e.shortMessage ?? e.message}`);
    }
  }

  // 3) Replay (same nonce/intent)
  {
    try {
      await guard.connect(provider).createIntent(intent, signature);
      console.log("  [unexpected] replay succeeded");
    } catch (e: any) {
      console.log("  [ok] replay blocked");
      console.log(`       ${e.shortMessage ?? e.message}`);
    }
  }

  console.log(`\nWaiting ${timelockSeconds + 2}s for timelock...`);
  await new Promise((r) => setTimeout(r, (timelockSeconds + 2) * 1000));

  console.log(`Finalize intent (anyone)`);
  const finTx = await guard.finalizeIntent(intentHash);
  const finRc = await finTx.wait();
  if (finRc) console.log(`  ${BASESCAN_TX(finRc.hash)}`);

  const [buyerBalAfter, providerBalAfter] = await Promise.all([
    usdc.balanceOf(buyer.address) as Promise<bigint>,
    usdc.balanceOf(provider.address) as Promise<bigint>,
  ]);

  console.log(`\nUSDC balances (after)`);
  console.log(`  buyer:    ${fmtUsdc(buyerBalAfter)} USDC`);
  console.log(`  provider: ${fmtUsdc(providerBalAfter)} USDC`);

  console.log("\nDone.");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});

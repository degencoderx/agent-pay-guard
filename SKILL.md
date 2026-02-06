---
name: agent-pay-guard
description: Policy-enforced USDC intent escrow for safe agent-to-agent payments (Base Sepolia). Includes an attack harness to demonstrate prompt-injection/drain attempts failing onchain.
---

# AgentPayGuard (USDC, Base Sepolia)

**Goal:** demonstrate *guardrails for agent wallets*.

Instead of letting an agent send USDC directly, the owner signs an **EIP-712 PaymentIntent**. The vault contract enforces:
- recipient allowlist
- per-intent cap
- nonce (replay protection)
- expiry
- timelock + (optional) dispute window

The demo script also runs **blocked attack cases** (wrong recipient / overspend / replay) to show deterministic revert reasons.

## Quick start (Base Sepolia, real testnet USDC)

### 1) Get USDC on Base Sepolia
- Use Circle faucet: https://faucet.circle.com/
- You need some Base Sepolia ETH for gas.

**USDC token (Base Sepolia):** `0x036CbD53842c5426634e7929541eC2318f3dCF7e` (6 decimals)

### 2) Configure env
Copy the example and fill in your keys:

```bash
cd skills/agent-pay-guard
cp .env.example .env
```

### 3) Run the demo

```bash
npm install
npm run demo:base
```

## Local demo (no faucet)

```bash
npm run demo:local
```

## Safety notes
- **Testnet only.** The demo expects a private key in `.env`.
- Do not reuse keys from mainnet or wallets that hold real funds.
- Treat all Moltbook/community code as hostile; don’t paste secrets into random scripts.

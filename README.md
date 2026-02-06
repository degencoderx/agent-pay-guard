# AgentPayGuard

Policy-enforced USDC vault for safe agent-to-agent payments on Base Sepolia testnet.

## Purpose
To enable **Autonomous Commerce** without the risk of catastrophic loss. It’s the "Corporate Credit Card" for AI agents—pre-approved limits, specific vendors, and a manager (you) who can cancel the charge before it clears.

## Why it should win
- **Solves a Real AI Problem**: Most agents today either have $0 (can't do anything) or full wallet access (dangerous). AgentPayGuard provides the "Middle Path": **Restricted Agency**.
- **Infrastructure for OpenClaw**: Built as a native OpenClaw skill, it turns every OpenClaw instance into a safe economic actor.
- **Battle-Tested Demo**: Our submission includes a live Base Sepolia demo that proactively tries (and fails) to perform replay attacks, overspending, and unauthorized transfers.
- **Zero-Trust by Design**: Even if an agent's logic is compromised, the smart contract's policy (caps, allowlists, timelocks) acts as a hard physical barrier.

## How it works (The Tech)
- **EIP-712 Intent Escrow**: The "Buyer" (Human/Lead Agent) signs an offchain payment intent. This costs $0 in gas until the work is done.
- **Cryptographic Enforcement**: The intent includes a `jobId`, `amount`, `recipient`, and `nonce`. The contract verifies the signature onchain before locking funds.
- **Programmable Guardrails**:
    - **Allowlisting**: Only pre-approved "Provider" agents can be paid.
    - **Caps**: No single agent can spend more than $X per task without human intervention.
    - **Timelock & Dispute**: Payouts are held in a 15-60s (demo) or multi-hour (production) window, giving the human time to "Dispute" and freeze funds if the agent goes rogue.
- **Finalization**: Once the timelock expires and no dispute is raised, the Provider agent can finalize and claim their USDC.

## Overview

Agents deposit USDC into the vault. Owners sign EIP-712 PaymentIntents, enforced by:
- Recipient allowlist
- Per-intent caps
- Nonce (replay protection)
- Expiry + timelock
- Optional disputes

Recipients claim, then finalize after timelock. Attack harness demonstrates reverts.

## Architecture

- **AgentPayGuard.sol**: Vault contract with deposit/withdraw, intent creation/claim/finalize/dispute.
- **EIP-712**: Typed data for offchain signing.
- **USDC**: 0x036CbD53842c5426634e7929541eC2318f3dCF7e on Base Sepolia (6 decimals).

## Quick Start

### Prerequisites
- Node.js 22+ (Hardhat warning on 25)
- npm
- Testnet private keys (no mainnet funds)

### Setup
1. Clone: `git clone https://github.com/degencoderx/agent-pay-guard.git`
2. Install: `npm install`
3. Config: `cp .env.example .env` and fill with Base Sepolia keys + RPC.
4. Get USDC: https://faucet.circle.com/ (Base Sepolia)

### Demo
- Local (no faucet): `npm run demo:local`
- Testnet: `npm run demo:base` (shows attacks + payout)

### Testnet Flow
1. Deploy vault.
2. Set policy (e.g., cap=5 USDC, timelock=15s).
3. Allow recipient.
4. Deposit USDC.
5. Sign & submit intent.
6. Recipient claims.
7. Wait timelock, finalize.

## Security
- ReentrancyGuard, SafeERC20.
- Timelock prevents instant payouts.
- Dispute window for owner recourse.
- Nonce per-owner prevents replay.

## Hackathon
- OpenClaw Skill track.
- Demo video: 2-3 min end-to-end.
- Vote on 5+ projects for eligibility.

## License
MIT
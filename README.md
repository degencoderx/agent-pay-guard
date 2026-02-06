# AgentPayGuard

Policy-enforced USDC vault for safe agent-to-agent payments on Base Sepolia testnet.

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
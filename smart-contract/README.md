# Arcelo Smart Contracts

Arcelo is an on-chain arcade game hub for Celo. Players deposit USDC, spend a fixed bet to start lightweight game sessions, earn weekly ARC score through backend-signed exits, and compete for weekly USDC prize pools. CELO is still part of the user experience because every transaction on Celo needs CELO for gas, while the in-game economy stays denominated in USDC.

This repository contains the Foundry smart contract project for Arcelo.

## Why Celo

Arcelo targets Celo Mainnet because the chain is built for mobile-friendly payments and stablecoin UX. The contract uses Celo USDC as the only game token, which keeps deposits, prize pools, and revenue easy to reason about for users. Wallets still need a small CELO balance to pay gas for actions like deposit, start game, exit game, claim prize, or withdraw.

Native CELO is intentionally not accepted as a deposit or bet token in this version. That separation keeps CELO focused on network fees and keeps gameplay accounting in USDC.

## Contract

`src/Arcelo.sol` is a UUPS upgradeable contract deployed behind an `ERC1967Proxy`.

Core behavior:

- Supports exactly one game token: USDC on the target Celo network.
- Native CELO, cUSD, USDT, and other ERC20 tokens are not accepted for deposits, bets, prize pools, or revenue.
- Player deposits are internal USDC balances, separated from prize pools and revenue.
- Starting a game burns the bet into accounting: 80% weekly prize pool, 20% platform revenue. Integer dust goes to the prize pool.
- ARC is non-transferable weekly score, stored by `weekId`.
- Weekly resets use epochs from `genesisWeekStart`; there is no global player loop.
- Leaderboard storage is bounded to the top 10 players per week.
- Prize distribution is bounded, credits claimable USDC to the stored top 10, and rolls unpaid or rounding remainder into the current week.
- EIP-712 signature-gated exits are required for game settlement.

OpenZeppelin v5.6 uses a stateless namespaced `ReentrancyGuard` in `@openzeppelin/contracts`; it is safe for this upgradeable deployment style and is used with `Initializable`, `OwnableUpgradeable`, `UUPSUpgradeable`, `PausableUpgradeable`, and `EIP712Upgradeable`.

## Game Flow

1. A player approves USDC and calls `deposit`.
2. The player calls `startGame` with a bet and game id.
3. The backend validates gameplay and signs an EIP-712 exit payload.
4. The player calls `exitGame` with the signed result.
5. ARC score updates the weekly leaderboard.
6. After the week ends plus `maxSessionDuration`, the owner distributes weekly prizes.
7. Winners claim USDC with `claimPrize`.

The contract keeps leaderboard operations bounded to the top 10 players, so weekly prize distribution does not need to loop through every player.

## Celo Mainnet Deployment

Arcelo is deployed on Celo Mainnet. Use the proxy address for frontend and backend integrations:

```text
Proxy: 0x58CCC5CdA23ece428Bc6F80F3bB10cB27619aF40
Implementation: 0x7d039DD45c6E1F2F12B6BA5499573f7b4F45cb4f
USDC: 0xcebA9300f2b948710d2653dD7B07f33A8B32118C
```

Users need CELO in their wallet for gas, but gameplay funds use USDC only. Native CELO is not accepted as a bet, deposit, prize pool asset, or revenue token.

ABI for frontend integration:

```text
abi/Arcelo.json
```

## Local Commands

```bash
forge fmt
forge build
forge test
forge build --sizes
```

## Deployment

Set environment values before broadcasting:

```bash
export PRIVATE_KEY=...
export CELO_RPC_URL=...
export EXPECTED_CHAIN_ID=42220
export ARCELO_OWNER=0x...
export BACKEND_SIGNER=0x...
export GENESIS_WEEK_START=...
export MAX_SESSION_DURATION=7200
export USDC_TOKEN=0x...
export USDC_MIN_BET=100000
export USDC_MAX_BET=1000000000
```

`GENESIS_WEEK_START` must be a Monday 00:00 UTC Unix timestamp and must not be in the future.

`USDC_MIN_BET` and `USDC_MAX_BET` are raw USDC units. USDC has 6 decimals, so `100000` means `0.1 USDC`.

Deploy:

```bash
forge script script/DeployArcelo.s.sol --rpc-url $CELO_RPC_URL --broadcast --verify
```

If Celo Blockscout verification requires explicit settings, add the Blockscout verifier flags for the active explorer endpoint used by official Celo docs.

The deployer wallet must have enough CELO to pay deployment gas. The owner wallet also needs CELO for owner-only operations such as configuration, pausing, prize distribution, revenue withdrawal, and upgrades.

## USDC Configuration

Always verify chain id, RPC URL, explorer URL, and the USDC token address from official Celo or Circle docs before broadcasting. Celo Mainnet chain id is `42220`.

The configuration script can update the USDC min/max bet range or re-enable USDC after an emergency disable. It cannot add cUSD, USDT, native CELO, or any other token.

```bash
export PRIVATE_KEY=...
export CELO_RPC_URL=...
export EXPECTED_CHAIN_ID=42220
export ARCELO_PROXY=0x...
export USDC_TOKEN=0x...
export USDC_MIN_BET=100000
export USDC_MAX_BET=1000000000

forge script script/ConfigureCeloMainnet.s.sol --rpc-url $CELO_RPC_URL --broadcast
```

## Upgrade

The owner upgrades through UUPS:

```bash
export PRIVATE_KEY=...
export EXPECTED_CHAIN_ID=42220
export ARCELO_PROXY=0x...
forge script script/UpgradeArcelo.s.sol --rpc-url $CELO_RPC_URL --broadcast --verify
```

The upgrade test covers preservation of player balances, prize pool, platform revenue, active session-derived state, ARC balances, leaderboard rank, and the configured USDC game token after upgrading to a V2 implementation.

## Security Notes

- Direct native CELO sends revert.
- `expireSession` is callable by anyone after `maxSessionDuration` so stale sessions cannot lock players.
- `distributeWeeklyPrize` only works after the target week has ended plus `maxSessionDuration`, and can only run once per week.
- `withdrawRevenue` can only withdraw `platformRevenue[USDC]`; prize pools and claimable prizes are separate accounting.
- Signature mode verifies the EIP-712 domain, player, session, game id, week id, checkpoint count, and deadline.
- No function loops over all players; loops are bounded to 10 leaderboard entries.

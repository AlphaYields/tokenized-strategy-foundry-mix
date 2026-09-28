# Audit scope

## What to audit

| File | Lines | Why it is in scope |
|---|---:|---|
| `src/HbarxLoopStrategy.sol` | **155** | All custom logic: the leverage loop, AMM swaps, NAV reporting, Bonzo integration |
| `src/hedera/MinimalFactory.sol` | 20 | Returns Yearn's protocol fee config. One view function, no funds held |
| `patches/0001-*.patch` | 1 | One-line address change to upstream `BaseStrategy` |

**Total custom surface: ~175 lines.**

## What is NOT in scope, and why

`lib/tokenized-strategy` (Yearn V3 `TokenizedStrategy`, apiVersion 3.1.0) is deployed
**verbatim from upstream** and holds everything a vault normally gets wrong:

- ERC-4626 share maths and rounding
- First-depositor / inflation-attack protection
- Deposit, mint, withdraw, redeem accounting
- Performance fee accrual and profit unlocking
- Access control (management / keeper / emergency)
- Emergency withdraw path

It is audited upstream. Verify rather than re-audit: build `lib/tokenized-strategy` at the
pinned submodule commit and compare against the deployed bytecode at `0.0.10757286`.

**Reproducibility confirmed.** `TokenizedStrategy.sol` at the pinned commit
`8c8929f1878e8c5ad78aa0a6dabc877a890f68d9` is byte-identical to the source deployed
(sha256 `1023633f187e02b286c1d82a2c9ff1921395ec5109c7fec983ebb4294b759924`, 2,372 lines,
`API_VERSION = "3.1.0"`), and the live contract reports `apiVersion() = "3.1.0"`.

## Architecture

```
user ──► HbarxLoopStrategy (0.0.10757461)
           │
           ├── fallback ──delegatecall──► TokenizedStrategy (0.0.10757286)  [AUDITED, verbatim]
           │                               ERC-4626 accounting, shares, fees, access control
           │
           └── strategy logic (IN SCOPE)
                 ├── Bonzo Lend    supply / withdraw / borrow / repay
                 └── SaucerSwap    WHBAR <-> HBARX via direct pair swap
```

The strategy implements only the three functions `BaseStrategy` requires —
`_deployFunds`, `_freeFunds`, `_harvestAndReport` — plus `leverUp` / `deleverage`
(management-gated) and view helpers.

## Reviewer notes

1. **NAV uses an AMM mid-price.** `_harvestAndReport` values WHBAR debt through the
   SaucerSwap pair, because Bonzo's oracle has no configured price sources on testnet
   (see `HEDERA_FINDINGS.md` F3). **This is manipulable by design and must be replaced
   with the lending-market oracle before mainnet.** Treat it as a known finding, not an
   oversight — it is flagged here deliberately.
2. **Leverage sizing is off-chain.** `leverUp` takes an explicit `borrowPerLoop` rather
   than reading available borrowing power, to avoid the oracle dependency. Health-factor
   safety therefore rests on the caller plus Bonzo's own `validateBorrow`.
3. **Loops are capped** at `MAX_LOOPS = 5` for Hedera's child-transaction limit.
4. **Swaps go directly against the Uniswap-V2-style pair**, not a router; `minOut` is
   computed from live reserves with a caller-supplied slippage bound.
5. **HTS approvals are deferred** to `initApprovals()` — HTS `approve()` reverts inside a
   constructor (F9). The call is permissionless and idempotent; confirm that is acceptable.
6. **The borrow path has never executed** anywhere. Bonzo testnet lacks oracle prices and
   Bonzo mainnet is paused. `leverUp`/`deleverage` are unexercised code.

## Deployed (Hedera testnet, chain 296)

| Contract | EVM | Hedera | Audited |
|---|---|---|---|
| TokenizedStrategy | `0xccC8Ee9a1A559Fa814a886A2303F03239678eC8e` | `0.0.10757286` | upstream |
| HbarxLoopStrategy | `0xcA41b1679961Eb0C4644ab0004Fce2B805d062dB` | `0.0.10757461` | **in scope** |
| MinimalFactory | `0xdb5A2cf26E6d0956330bF507441Aaa59D5aB742c` | `0.0.10757284` | **in scope** |

Verified live: ERC-4626 surface resolves through the delegatecall — `symbol()` = `ysHBARX`,
`decimals()` = 8, `apiVersion()` = `3.1.0`, `performanceFee()` = 1000.

## Integration addresses

| | EVM address |
|---|---|
| HBARX (HTS) | `0x0000000000000000000000000000000000220cED` |
| WHBAR (HTS) | `0x0000000000000000000000000000000000003aD2` |
| Bonzo LendingPool | `0xf67DBe9bD1B331cA379c44b5562EAa1CE831EbC2` |
| Bonzo aHBARX | `0x259f2be6542bf882b6ea4ab157f4112f4cec0666` |
| Bonzo variableDebtWHBAR | `0xf9f8309a8f55e8e480b214b6725f8419fa029d57` |
| SaucerSwap WHBAR/HBARX pair | `0xb0d84d87b45b99ed1c5f04bc84a9b5eb310dee16` |

The pair address is the **EVM alias**, not the long-zero form. Using long-zero makes
contract-to-contract calls return empty data and revert on decode (F2).

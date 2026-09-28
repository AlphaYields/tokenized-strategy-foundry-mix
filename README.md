# HBARX Loop Strategy — Hedera

Yearn V3 tokenized strategy running the HBARX-collateral / WHBAR-borrow loop on
[Bonzo Lend](https://bonzo.finance), with HBARX↔WHBAR swaps on SaucerSwap.

Forked from [`yearn/tokenized-strategy-foundry-mix`](https://github.com/yearn/tokenized-strategy-foundry-mix).

## Why Yearn V3

All ERC-4626 accounting — share maths, inflation-attack protection, fees, access control,
emergency paths — lives in Yearn's `TokenizedStrategy`, deployed verbatim from upstream.
This repository's custom surface is **155 lines of strategy logic**.

Start at **[`docs/AUDIT_SCOPE.md`](docs/AUDIT_SCOPE.md)**.

## Status

Deployed to Hedera testnet (chain 296). The ERC-4626 interface is verified working through
the delegatecall to the audited singleton.

**The leverage path has not executed.** Bonzo's testnet oracle has no configured price
sources, so `borrow()` cannot succeed; Bonzo mainnet is paused. Supply works; leverage is
unexercised. See [`docs/HEDERA_FINDINGS.md`](docs/HEDERA_FINDINGS.md).

## Hedera integration notes

Ten measured findings in [`docs/HEDERA_FINDINGS.md`](docs/HEDERA_FINDINGS.md). The ones
that cost the most time:

- Contract-to-contract calls **must use the EVM alias**, never the long-zero address —
  long-zero returns empty data and reverts on decode, while direct RPC calls work at both.
- HTS `approve()` **reverts inside a constructor**; HIP-904 auto-association fires only on
  first receipt.
- `forge create` needs `--legacy`; the relay rejects EIP-1559 fee fields.

## Build

```bash
git submodule update --init --recursive
git apply -p1 --directory=lib/tokenized-strategy \
  patches/0001-hedera-tokenizedstrategy-address.patch
forge build
```

## Licence

AGPL-3.0, inherited from Yearn's tokenized-strategy.

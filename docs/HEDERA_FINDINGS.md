# Hedera integration findings

Measured on Hedera testnet (chain 296) while building and deploying this strategy.
Each item cost real debugging time; they are recorded so the next integration does not repeat them.

## F1 — Bonzo Lend testnet is live, unlike mainnet

paused()=false; HBARX LTV 70%/LT 75%, WHBAR LTV 75%/LT 80%, both active, unfrozen, borrowEnabled. Mainnet is paused since the 2026-07-11 oracle exploit.

**Impact.** Testnet supply path is open.

## F2 — Contract-to-contract calls must use the EVM alias, not the long-zero address

Calling SaucerSwap pair 0.0.2661051 at long-zero 0x...289abb from a contract returns success with ZERO bytes of return data, so Solidity reverts on abi.decode. The same call at its EVM alias 0xb0d84d87b45b99ed1c5f04bc84a9b5eb310dee16 returns 96 bytes correctly. Direct JSON-RPC calls succeed at BOTH addresses, so this only appears once logic runs inside a contract.

**Impact.** Silent failure mode. Any Hedera integration must resolve EVM aliases via the mirror node before hardcoding addresses.

*Evidence:* Prober contract 0x100c27ff9c338E06cDbbaaAcecf66021AD72628d, probe(address) on both forms.

## F3 — Bonzo testnet price oracle has no configured sources - borrowing is impossible

getAssetPrice reverts with 0x24a01144 for ALL SIX reserves (XSAUCE, USDC, KARATE, HBARX, SAUCE, WHBAR). getSourceOfAsset(HBARX) = 0x0. BASE_CURRENCY = 0x0. Fallback oracle 0xF6e755.. also reverts. Both the addresses-provider oracle (0x9B940a1e..) and the documented one (0xF6e755..) fail.

**Impact.** BLOCKER for the loop on testnet. Aave-V2 validateBorrow requires prices, so borrow() cannot succeed. Supply/deposit does not touch the oracle and still works.

## F4 — Documented Bonzo oracle address is stale

docs.bonzo.finance lists PriceOracle 0xF6e755380518589dE02f0F6BaA1D291C016992Cb (0.0.4999375). LendingPoolAddressesProvider.getPriceOracle() returns 0x9B940a1e60D652bCaf09C1d2224d1A4a544FDFb0. Always resolve through the provider.

**Impact.** Hardcoding from docs points at the wrong contract.

## F5 — Hedera relay rejects forge's EIP-1559 fee fields

forge create without --legacy fails with 'Insufficient funds for transfer' even when the balance far exceeds gasLimit x gasPrice. Adding --legacy --gas-price <eth_gasPrice> deploys normally.

**Impact.** Deployment tooling note.

## F6 — Contract bytecode fits comfortably

18,153 B deploy / 16,570 B runtime against the 24,576 limit; deployed for 4.63 HBAR at 114 tinybar/gas (4,062,576 gas).

**Impact.** Answers open question 5 in the prior research (bytecode size limit on Hedera).

## F7 — Contracts get unlimited HTS auto-association

The deployed vault shows max_automatic_token_associations = -1 (HIP-904), so the explicit associate() call is not needed and ~4.5 HBAR of association fees are avoided.

**Impact.** Simplifies the Hedera integration.

## F8 — Testnet pool pricing is not economically meaningful

SaucerSwap pool 6 holds 673,284 WHBAR / 44,085 HBARX = 15.27 WHBAR per HBARX, versus ~1.43 on mainnet.

**Impact.** Mechanism is testable; APY figures from testnet are meaningless.

## F9 — HTS approve() reverts during contract construction

Calling approve() on an HTS token inside a constructor reverts. The contract is not yet associated with the token, and HIP-904 auto-association fires only on first RECEIPT, not at deployment. Confirmed: the deployed strategy shows max_automatic_token_associations=-1 but 0 associated tokens.

**Impact.** Move all HTS approvals out of constructors into a post-deploy call, and send a dust amount of each token to the contract first to trigger association.

*Evidence:* Deploy with constructor approvals reverted (eth_estimateGas also reverted); identical contract without them estimated 2,072,657 gas and deployed successfully.

## F10 — Yearn V3 TokenizedStrategy works on Hedera with HTS assets

The delegatecall singleton pattern functions correctly against an HTS token. Deployed verbatim (apiVersion 3.1.0) and the full ERC-4626 surface resolves through the strategy: name, symbol (ysHBARX), decimals 8 (read from the HTS facade inside delegatecall), asset, totalAssets, totalSupply, management, keeper, performanceFee 1000, profitMaxUnlockTime 864000.

**Impact.** The audited Yearn core is usable on Hedera. Reduces the custom, audit-requiring surface from ~600 lines to 155.

#!/usr/bin/env bash
# Deploy HederaLoopVault to Hedera testnet and wire it up.
set -euo pipefail
cd "$(dirname "$0")/.."
RPC=${RPC:-https://testnet.hashio.io/api}
PK=$(python3 -c "import json;print(json.load(open('data/deployer_wallet.json'))[0]['private_key'])")
ADDR=$(python3 -c "import json;print(json.load(open('data/deployer_wallet.json'))[0]['address'])")

HBARX=0x0000000000000000000000000000000000220cED
WHBAR_T=0x0000000000000000000000000000000000003aD2
WHBAR_C=0x0000000000000000000000000000000000003aD1
POOL=0xf67DBe9bD1B331cA379c44b5562EAa1CE831EbC2
PAIR=0x0000000000000000000000000000000000289abb
ORACLE=0xF6e755380518589dE02f0F6BaA1D291C016992Cb
AHBARX=0x259f2be6542bf882b6ea4ab157f4112f4cec0666
DEBTW=0xf9f8309a8f55e8e480b214b6725f8419fa029d57

echo "deployer $ADDR"
echo "balance  $(cast balance $ADDR --rpc-url $RPC)"

echo "==> deploying HederaLoopVault"
OUT=$(forge create src/HederaLoopVault.sol:HederaLoopVault \
  --rpc-url "$RPC" --private-key "$PK" --broadcast --gas-limit 15000000 --json \
  --constructor-args $HBARX $WHBAR_T $WHBAR_C $POOL $PAIR $ORACLE $AHBARX $DEBTW)
echo "$OUT" > data/deploy_raw.json
VAULT=$(python3 -c "import json;print(json.load(open('data/deploy_raw.json'))['deployedTo'])")
echo "VAULT: $VAULT"
python3 - "$VAULT" "$ADDR" << 'PY'
import json,sys
d={"vault":sys.argv[1],"deployer":sys.argv[2],"network":"hedera-testnet","chainId":296}
json.dump(d,open('data/deployment.json','w'),indent=1); print("saved data/deployment.json")
PY
echo "==> associating HTS tokens on the vault (HBARX, WHBAR, aHBARX, debtWHBAR)"
cast send "$VAULT" "associate()" --rpc-url "$RPC" --private-key "$PK" --gas-limit 4000000 >/dev/null
echo "associated=$(cast call "$VAULT" "associated()(bool)" --rpc-url $RPC)"
echo "==> done. vault=$VAULT"

#!/bin/sh

echo 'Checking if contracts already exist...'
CONTRACTS_EXIST=true

for chain_id in $(echo $1 | tr ',' ' '); do
  echo "Checking chain_id: $chain_id"
  if [ ! -f /network-data/state.json ]; then
    echo "state.json not found"
    CONTRACTS_EXIST=false
    break
  fi

  BRIDGE_PROXY=$(jq -r '.opChainDeployments[0].L1StandardBridgeProxy' /network-data/state.json 2>/dev/null || echo "null")
  OUTPUT_ORACLE=$(jq -r '.opChainDeployments[0].L2OutputOracleProxy' /network-data/state.json 2>/dev/null || echo "null")
  SYSTEM_CONFIG=$(jq -r '.opChainDeployments[0].SystemConfigProxy' /network-data/state.json 2>/dev/null || echo "null")

  echo "Bridge Proxy: $BRIDGE_PROXY"
  echo "Output Oracle: $OUTPUT_ORACLE"
  echo "System Config: $SYSTEM_CONFIG"

  if [ "$BRIDGE_PROXY" = "null" ] || [ "$OUTPUT_ORACLE" = "null" ] || [ "$SYSTEM_CONFIG" = "null" ]; then
    echo "One or more contracts are not deployed"
    CONTRACTS_EXIST=false
    break
  fi
done

echo "$CONTRACTS_EXIST"
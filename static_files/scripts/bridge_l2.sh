#!/usr/bin/env bash

set -euo pipefail

export ETH_RPC_URL="$L1_RPC_URL"

BRIDGE_ADDRESS="$1"
PREFUNDED_ACCOUNTS="$2"
PRIVATE_KEY="$3"

echo "$PREFUNDED_ACCOUNTS" | jq -r 'to_entries[] | "\(.key) \(.value.balance)"' | while read -r address balance; do
    if [ "$address" != "null" ] && [ "$balance" != "null" ]; then
        echo "Bridging $balance from L1 to L2 for address $address"
        
        if [[ $balance == *"ETH" ]]; then
            balance_wei=$(cast --to-wei "${balance%ETH}")
        else
            balance_wei="$balance"
        fi
        
        cast send "$BRIDGE_ADDRESS" \
            "depositETH(address,uint32,bytes)" \
            "$address" \
            "200000" \
            "0x" \
            --value "$balance_wei" \
            --private-key "$PRIVATE_KEY" \
            --gas-limit 300000 \
            --gas-price 2gwei \
            --timeout 60
        
        echo "Successfully bridged $balance to L2 for $address"
    fi
done

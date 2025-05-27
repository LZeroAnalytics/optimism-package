#!/usr/bin/env bash

set -euo pipefail

export ETH_RPC_URL="$L1_RPC_URL"

BRIDGE_ADDRESS="$1"
PREFUNDED_ACCOUNTS="$2"
PRIVATE_KEY="$3"

echo "Bridge address: $BRIDGE_ADDRESS"
echo "L2 RPC URL: $L2_RPC_URL"

echo "$PREFUNDED_ACCOUNTS" | jq -r 'to_entries[] | "\(.key) \(.value.balance)"' | while read -r address balance; do
    if [ "$address" != "null" ] && [ "$balance" != "null" ]; then
        echo "Checking L2 balance for $address before bridging..."
        if [ -n "$L2_RPC_URL" ]; then
            L2_BALANCE_BEFORE=$(cast balance "$address" --rpc-url "$L2_RPC_URL" || echo "Failed to get L2 balance")
            echo "L2 balance before bridging: $L2_BALANCE_BEFORE wei"
        else
            echo "Warning: L2_RPC_URL not set, skipping L2 balance check"
        fi
        
        echo "Bridging $balance from L1 to L2 for address $address"
        
        if [[ $balance == *"ETH" ]]; then
            balance_wei=$(cast --to-wei "${balance%ETH}")
            echo "Converted balance: $balance_wei wei from ${balance%ETH} ETH"
        else
            balance_wei="$balance"
            echo "Using raw balance: $balance_wei wei"
        fi
        
        if [ -z "$balance_wei" ]; then
            echo "Error: Failed to convert balance to wei"
            continue
        fi
        
        echo "Sending $balance_wei wei to bridge contract $BRIDGE_ADDRESS for recipient $address"
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
        
        # Wait a bit for the L2 transaction to be processed
        echo "Waiting 10 seconds for L2 transaction to be processed..."
        sleep 10
        
        if [ -n "$L2_RPC_URL" ]; then
            L2_BALANCE_AFTER=$(cast balance "$address" --rpc-url "$L2_RPC_URL" || echo "Failed to get L2 balance")
            echo "L2 balance after bridging: $L2_BALANCE_AFTER wei"
            
            if [ "$L2_BALANCE_BEFORE" != "Failed to get L2 balance" ] && [ "$L2_BALANCE_AFTER" != "Failed to get L2 balance" ]; then
                echo "L2 balance change: $((L2_BALANCE_AFTER - L2_BALANCE_BEFORE)) wei"
            fi
        else
            echo "Warning: L2_RPC_URL not set, skipping L2 balance check"
        fi
    fi
done

#!/usr/bin/env bash

set -euo pipefail

export ETH_RPC_URL="$L1_RPC_URL"

BRIDGE_ADDRESS="$1"
PREFUNDED_ACCOUNTS="$2"
PRIVATE_KEY="$3"

echo "PREFUNDED_ACCOUNTS: $PREFUNDED_ACCOUNTS"
echo "PRIVATE_KEY: $PRIVATE_KEY"
echo "BRIDGE_ADDRESS: $BRIDGE_ADDRESS"

# Get the address from private key
SENDER_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Sender address: $SENDER_ADDRESS"

# Get sender's balance
SENDER_BALANCE=$(cast balance "$SENDER_ADDRESS")
echo "Sender balance: $SENDER_BALANCE wei"

if echo "$PREFUNDED_ACCOUNTS" | jq -e 'type == "object"' > /dev/null; then
    echo "$PREFUNDED_ACCOUNTS" | jq -r 'to_entries[] | "\(.key) \(.value.balance)"' | while read -r address balance; do
        echo "Address: $address, Balance: $balance"
        if [ "$address" != "null" ] && [ "$balance" != "null" ]; then
            echo "Bridging $balance from L1 to L2 for address $address"

            if [[ $balance == *"ETH" ]]; then
                balance_wei=$(cast --to-wei "${balance%ETH}")
            else
                balance_wei="$balance"
            fi

            echo "Bridge address $BRIDGE_ADDRESS"

            TX_RESPONSE=$(cast send "$BRIDGE_ADDRESS" \
                "depositETHTo(address,uint32,bytes)" \
                "$address" \
                "20000000" \
                "0x" \
                --value "$balance_wei" \
                --private-key "$PRIVATE_KEY" \
                --gas-limit 1000000 \
                --legacy \
                --json \
                --rpc-url "$L1_RPC_URL" 2>&1)  

            if echo "$TX_RESPONSE" | jq -e 'has("transactionHash")' > /dev/null 2>&1; then
            TX_HASH=$(echo "$TX_RESPONSE" | jq -r '.transactionHash')
            echo "Transaction hash: $TX_HASH"

            sleep 5 
            RECEIPT=$(cast receipt "$TX_HASH" --rpc-url "$L1_RPC_URL" --json 2>&1)

            if echo "$RECEIPT" | jq -e 'has("status")' > /dev/null 2>&1; then
                TX_STATUS=$(echo "$RECEIPT" | jq -r '.status')
                if [ "$TX_STATUS" == "0x1" ]; then
                    echo "✅ Transaction succeeded"
                else
                    echo "❌ Transaction failed with status $TX_STATUS"
                fi
            else
                echo "❌ Failed to fetch transaction receipt for $TX_HASH"
                echo "Receipt output: $RECEIPT"
            fi
        else
            echo "❌ Transaction failed to broadcast:"
            echo "$TX_RESPONSE"
        fi

        fi
    done
fi

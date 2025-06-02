#!/usr/bin/env bash

# set -euo pipefail

BRIDGE_ADDRESS="$1"
ADDRESS="$2"
BALANCE="$3"
PRIVATE_KEY="$4"

echo "ADDRESS: $ADDRESS"
echo "BALANCE: $BALANCE"
echo "PRIVATE_KEY: $PRIVATE_KEY"
echo "BRIDGE_ADDRESS: $BRIDGE_ADDRESS"
echo "L1 RPC URL: $L1_RPC_URL"

# Get the address from private key
SENDER_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Sender address: $SENDER_ADDRESS"

# Get sender's balance
SENDER_BALANCE=$(cast balance "$SENDER_ADDRESS" --rpc-url "$L1_RPC_URL")
echo "Sender balance: $SENDER_BALANCE wei"

GAS_PRICE=$(cast gas-price --rpc-url "$L1_RPC_URL")
GAS_PRICE=$((GAS_PRICE * 12 / 10))
echo "Using gas price: $GAS_PRICE wei"

if [ "$ADDRESS" != "null" ] && [ "$BALANCE" != "null" ]; then
    echo "Bridging $BALANCE from L1 to L2 for address $ADDRESS"

    if [[ $BALANCE == *"ETH" ]]; then
        balance_wei=$(cast --to-wei "${BALANCE%ETH}")
    else
        balance_wei="$BALANCE"
    fi

    echo "Bridge address $BRIDGE_ADDRESS"

    TIMESTAMP=$(date +%s)
    echo "TIMESTAMP: $TIMESTAMP"

    SALT_BYTES="0x$(cast --to-bytes32 "${TIMESTAMP}" | cut -c 3-)"
    echo $SALT_BYTES

    TX_RESPONSE=$(cast send "$BRIDGE_ADDRESS" \
        "depositETHTo(address,uint32,bytes)" \
        "$ADDRESS" \
        "200000" \
        "$SALT_BYTES" \
        --value "$balance_wei" \
        --private-key "$PRIVATE_KEY" \
        --gas-limit 1000000 \
        --legacy \
        --json \
        --rpc-url "$L1_RPC_URL")

    echo "Raw transaction response: $TX_RESPONSE"

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

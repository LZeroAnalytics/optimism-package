#!/usr/bin/env bash

set -euo pipefail

export ETH_RPC_URL="$L1_RPC_URL"

addr=$(cast wallet address "$FUND_PRIVATE_KEY")
nonce=$(cast nonce "$addr")

deployer_addr=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")

mnemonic="test test test test test test test test test test test junk"
roles=("l2ProxyAdmin" "l1ProxyAdmin" "baseFeeVaultRecipient" "l1FeeVaultRecipient" "sequencerFeeVaultRecipient" "systemConfigOwner")
funded_roles=("proposer" "batcher" "sequencer" "challenger")

IFS=',';read -r -a chain_ids <<< "$1"

write_keyfile() {
  echo "{\"address\":\"$1\",\"privateKey\":\"$2\"}" > "/network-data/$3.json"
}

send() {
  cast send $1 --value "$FUND_VALUE" --private-key "$FUND_PRIVATE_KEY" --timeout 60 --nonce "$nonce" --priority-gas-price 1gwei &
  nonce=$((nonce+1))
}

# Create a JSON object to store all the wallet addresses and private keys, start with an empty one
wallets_json=$(jq -n '{}')
for chain_id in "${chain_ids[@]}"; do
  chain_wallets=$(jq -n '{}')

  for index in "${!funded_roles[@]}"; do
    role="${funded_roles[$index]}"
    role_idx=$((index+1))

    # private_key=$(cast wallet private-key "$mnemonic" "m/44'/60'/2'/$chain_id/$role_idx")
    private_key=$FUND_PRIVATE_KEY
    address=$(cast wallet address "${private_key}")
    write_keyfile "${address}" "${private_key}" "${role}-$chain_id"
    send "${address}"

    chain_wallets=$(echo "$chain_wallets" | jq \
      --arg role "$role" \
      --arg private_key "$private_key" \
      --arg address "$address" \
      '.[$role + "PrivateKey"] = $private_key | .[$role + "Address"] = $address')
  done

  for index in "${!roles[@]}"; do
    role="${roles[$index]}"

    write_keyfile "${deployer_addr}" "${DEPLOYER_PRIVATE_KEY}" "${role}-$chain_id"

    chain_wallets=$(echo "$chain_wallets" | jq \
      --arg role "$role" \
      --arg private_key "$DEPLOYER_PRIVATE_KEY" \
      --arg address "$deployer_addr" \
      '.[$role + "PrivateKey"] = $private_key | .[$role + "Address"] = $address')
  done

  # Add the L1 and L2 faucet information to each chain's wallet data
  # Use chain 20 from the ethereum_package to prevent conflicts

  chain_wallets=$(echo "$chain_wallets" | jq \
    --arg addr "$deployer_addr" \
    --arg private_key "$FUND_PRIVATE_KEY" \
    '.["l1FaucetPrivateKey"] = $private_key | .["l1FaucetAddress"] = $addr')

  chain_wallets=$(echo "$chain_wallets" | jq \
    --arg addr "$deployer_addr" \
    --arg private_key "$FUND_PRIVATE_KEY" \
    '.["l2FaucetPrivateKey"] = $private_key | .["l2FaucetAddress"] = $addr')

  # Add this chain's wallet information to the main JSON object
  wallets_json=$(echo "$wallets_json" | jq \
    --arg chain_id "$chain_id" \
    --argjson chain_wallets "$chain_wallets" \
    '.[$chain_id] = $chain_wallets')
done

echo "Wallet private key and addresses"
echo "$wallets_json" > "/network-data/wallets.json"
echo "$wallets_json"

wait

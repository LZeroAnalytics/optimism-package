#!/usr/bin/env starlark

utils = import_module("../util.star")

DEPLOYER_IMAGE = "us-docker.pkg.dev/oplabs-tools-artifacts/images/op-deployer:v0.4.0-rc.2"


def deploy_contracts(
    plan,
    optimism_args,
    l1_config_env_vars,
    jwt_file,
    fund_script_artifact,
):
    l2_chain_ids = []
    l2_chain_ids_list = []
    for chain in optimism_args.chains:
        l2_chain_ids.append(str(chain.network_params.network_id))
        l2_chain_ids_list.append(str(chain.network_params.network_id))

    # Initialize the deployer
    op_deployer_init = plan.run_sh(
        name="op-deployer-init",
        description="Initialize the deployer",
        image=DEPLOYER_IMAGE,
        env_vars=l1_config_env_vars,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        run="op-deployer init --l1-rpc-url $L1_RPC_URL --l1-deployer-key $DEPLOYER_PRIVATE_KEY --l1-funder-key $FUND_PRIVATE_KEY --outdir /network-data",
    )

    # Generate the config
    op_deployer_config = plan.run_sh(
        name="op-deployer-config",
        description="Generate the config",
        image=DEPLOYER_IMAGE,
        env_vars=l1_config_env_vars,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        files={
            "/network-data": op_deployer_init.files_artifacts[0],
            "/jwt": jwt_file,
        },
        run="op-deployer config --l1-rpc-url $L1_RPC_URL --l1-deployer-key $DEPLOYER_PRIVATE_KEY --l1-funder-key $FUND_PRIVATE_KEY --outdir /network-data --l2-chain-id {0} --l2-blocktime 2 --l2-jwt-secret /jwt/jwtsecret --l2-engine-sync-enabled true --l2-genesis-timestamp $(date +%s) --l2-genesis-delay 0".format(
            ",".join(l2_chain_ids)
        ),
    )

    # Deploy the contracts
    op_deployer_output = plan.run_sh(
        name="op-deployer-deploy",
        description="Deploy the contracts",
        image=DEPLOYER_IMAGE,
        env_vars=l1_config_env_vars,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        files={
            "/network-data": op_deployer_config.files_artifacts[0],
            "/jwt": jwt_file,
        },
        run="op-deployer deploy --l1-rpc-url $L1_RPC_URL --l1-deployer-key $DEPLOYER_PRIVATE_KEY --l1-funder-key $FUND_PRIVATE_KEY --outdir /network-data",
    )

    # Fund the accounts
    plan.run_sh(
        name="op-deployer-fund",
        description="Fund the accounts",
        image=utils.DEPLOYMENT_UTILS_IMAGE,
        env_vars=l1_config_env_vars,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        files={
            "/network-data": op_deployer_output.files_artifacts[0],
            "/fund-script": fund_script_artifact,
        },
        run="bash /fund-script/fund.sh \"{0}\" '{1}'".format(
            ",".join(l2_chain_ids),
            json.encode(get_prefunded_accounts_for_chains(optimism_args.chains)),
        ),
    )

    hardfork_schedule = []
    for chain in optimism_args.chains:
        if (
            hasattr(chain.network_params, "prague_time_offset")
            and chain.network_params.prague_time_offset != 0
        ):
            hardfork_schedule.append(
                {
                    "chain_id": chain.network_params.network_id,
                    "hardfork": "prague",
                    "time_offset": chain.network_params.prague_time_offset,
                }
            )
        if (
            hasattr(chain.network_params, "fjord_time_offset")
            and chain.network_params.fjord_time_offset != 0
        ):
            hardfork_schedule.append(
                {
                    "chain_id": chain.network_params.network_id,
                    "hardfork": "fjord",
                    "time_offset": chain.network_params.fjord_time_offset,
                }
            )
        if (
            hasattr(chain.network_params, "granite_time_offset")
            and chain.network_params.granite_time_offset != 0
        ):
            hardfork_schedule.append(
                {
                    "chain_id": chain.network_params.network_id,
                    "hardfork": "granite",
                    "time_offset": chain.network_params.granite_time_offset,
                }
            )

    if len(hardfork_schedule) > 0:
        apply_cmds = []
        for hardfork in hardfork_schedule:
            apply_cmds.append(
                "op-deployer apply-hardfork --l1-rpc-url $L1_RPC_URL --l1-deployer-key $DEPLOYER_PRIVATE_KEY --l1-funder-key $FUND_PRIVATE_KEY --outdir /network-data --l2-chain-id {0} --hardfork {1} --time-offset {2}".format(
                    hardfork["chain_id"], hardfork["hardfork"], hardfork["time_offset"]
                )
            )

        plan.run_sh(
            name="op-deployer-apply-hardfork",
            description="Apply hardfork",
            image=DEPLOYER_IMAGE,
            env_vars=l1_config_env_vars,
            store=[
                StoreSpec(
                    src="/network-data",
                    name="op-deployer-configs",
                )
            ],
            files={
                "/network-data": op_deployer_output.files_artifacts[0],
                "/jwt": jwt_file,
            },
            run=" && ".join(apply_cmds),
        )

    # Update wallets.json with actual bridge addresses after contract deployment
    plan.run_sh(
        name="op-deployer-update-bridge-addresses",
        description="Update wallets with L1StandardBridge addresses",
        image=utils.DEPLOYMENT_UTILS_IMAGE,
        env_vars=l1_config_env_vars,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        files={
            "/network-data": op_deployer_output.files_artifacts[0],
            "/fund-script": fund_script_artifact,
        },
        run="""for chain_id in {0}; do
  echo "Updating bridge address for chain $chain_id"
  hex_chain_id=$(printf '0x%064x' $chain_id)
  echo "Chain ID in hex format: $hex_chain_id"
  bridge_addr=$(jq -r '.opChainDeployments[] | select(.id=="'$hex_chain_id'") | .L1StandardBridgeProxy' /network-data/state.json)
  echo "Retrieved bridge address: $bridge_addr"
  if [ -n "$bridge_addr" ] && [ "$bridge_addr" != "null" ]; then
    echo "Updating wallets.json with bridge address: $bridge_addr for chain $chain_id"
    jq --arg chain_id "$chain_id" --arg bridge_addr "$bridge_addr" '(.[$chain_id].l1BridgeAddress) = $bridge_addr' /network-data/wallets.json > /tmp/wallets_updated.json
    mv /tmp/wallets_updated.json /network-data/wallets.json
    cat /network-data/wallets.json | grep l1BridgeAddress
  else
    echo "Warning: Could not find bridge address for chain $chain_id"
  fi
done""".format(" ".join(l2_chain_ids_list)),
    )

    for chain in optimism_args.chains:
        plan.run_sh(
            name="op-deployer-generate-chainspec",
            description="Generate chainspec",
            image=utils.DEPLOYMENT_UTILS_IMAGE,
            env_vars={"CHAIN_ID": str(chain.network_params.network_id)},
            store=[
                StoreSpec(
                    src="/network-data",
                    name="op-deployer-configs",
                )
            ],
            files={
                "/network-data": op_deployer_output.files_artifacts[0],
                "/fund-script": fund_script_artifact,
            },
            run='jq --from-file /fund-script/gen2spec.jq < "/network-data/genesis-$CHAIN_ID.json" > "/network-data/chainspec-$CHAIN_ID.json"',
        )

    return op_deployer_output.files_artifacts[0]


def chain_key(index, key):
    return "chains.[{0}].{1}".format(index, key)


def read_chain_cmd(filename, l2_chain_id):
    return "`jq -r .address /network-data/{0}-{1}.json`".format(filename, l2_chain_id)


def get_prefunded_accounts_for_chains(chains):
    """Extract prefunded_accounts from the first chain that has them defined."""
    for chain in chains:
        if (
            hasattr(chain.network_params, "prefunded_accounts")
            and chain.network_params.prefunded_accounts
        ):
            return chain.network_params.prefunded_accounts
    return {}

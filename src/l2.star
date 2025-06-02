participant_network = import_module("./participant_network.star")
blockscout = import_module("github.com/LZeroAnalytics/blockscout-package@dev/main.star")
da_server_launcher = import_module("./alt-da/da-server/da_server_launcher.star")
contract_deployer = import_module("./contracts/contract_deployer.star")
input_parser = import_module("./package_io/input_parser.star")
util = import_module("./util.star")
tx_fuzzer = import_module("./transaction_fuzzer/transaction_fuzzer.star")


def launch_l2(
    plan,
    l2_num,
    l2_services_suffix,
    l2_args,
    jwt_file,
    deployment_output,
    l1_config,
    l1_priv_key,
    l1_rpc_url,
    global_log_level,
    global_node_selectors,
    global_tolerations,
    persistent,
    observability_helper,
    supervisors_params,
    registry=None,
):
    network_params = l2_args.network_params
    proxyd_params = l2_args.proxyd_params
    batcher_params = l2_args.batcher_params
    proposer_params = l2_args.proposer_params
    mev_params = l2_args.mev_params
    tx_fuzzer_params = l2_args.tx_fuzzer_params
    blockscout_params = l2_args.blockscout_params

    plan.print("Deploying L2 with name {0}".format(network_params.name))

    # we need to launch da-server before launching the participant network
    # because op-batcher and op-node(s) need to know the da-server url, if present
    da_server_context = da_server_launcher.disabled_da_server_context()
    if "da_server" in l2_args.additional_services:
        da_server_image = l2_args.da_server_params.image
        plan.print("Launching da-server")
        da_server_context = da_server_launcher.launch_da_server(
            plan,
            "da-server",
            da_server_image,
            l2_args.da_server_params.cmd,
        )
        plan.print("Successfully launched da-server")

    l2 = participant_network.launch_participant_network(
        plan=plan,
        participants=l2_args.participants,
        jwt_file=jwt_file,
        network_params=network_params,
        proxyd_params=proxyd_params,
        batcher_params=batcher_params,
        proposer_params=proposer_params,
        mev_params=mev_params,
        deployment_output=deployment_output,
        l1_config_env_vars=l1_config,
        l2_num=l2_num,
        l2_services_suffix=l2_services_suffix,
        global_log_level=global_log_level,
        global_node_selectors=global_node_selectors,
        global_tolerations=global_tolerations,
        persistent=persistent,
        additional_services=l2_args.additional_services,
        observability_helper=observability_helper,
        supervisors_params=supervisors_params,
        da_server_context=da_server_context,
        registry=registry,
    )

    all_el_contexts = []
    all_cl_contexts = []
    for participant in l2.participants:
        all_el_contexts.append(participant.el_context)
        all_cl_contexts.append(participant.cl_context)

    network_id_as_hex = util.to_hex_chain_id(network_params.network_id)
    l1_bridge_address = util.read_network_config_value(
        plan,
        deployment_output,
        "state",
        '.opChainDeployments[] | select(.id=="{0}") | .L1StandardBridgeProxy'.format(
            network_id_as_hex
        ),
    )
    plan.print("Raw l1_bridge_address: {0}".format(l1_bridge_address))

    # Debug logging for prefunded accounts
    plan.print("Checking prefunded accounts configuration...")
    plan.print("Has prefunded_accounts attribute: {0}".format(hasattr(network_params, "prefunded_accounts")))

    fund_script_artifact = plan.upload_files(
        src="../static_files/scripts",
        name="bridge-l2-script",
    )

    if hasattr(network_params, "prefunded_accounts") and network_params.prefunded_accounts:
        plan.print("Bridging prefunded accounts to L2...")
        
        prefunded_accounts = json.decode(network_params.prefunded_accounts)
        plan.print("Prefunded accounts: {0}".format(prefunded_accounts))

        plan.print("rpc url for l1")
        plan.print(l1_rpc_url)

        # Iterate through each prefunded account
        for address, details in prefunded_accounts.items():
            balance = details["balance"]
            plan.print("Bridging {0} to address {1}".format(balance, address))
            plan.run_sh(
                name="bridge-prefunded-account-{}".format(address),
                description="Bridge prefunded account to L2",
                image=util.DEPLOYMENT_UTILS_IMAGE,
                env_vars={
                    "L1_RPC_URL": l1_rpc_url,
                    "FUND_PRIVATE_KEY": l1_priv_key,
                },
                files={
                    "/fund-script": fund_script_artifact,
                },
                run="bash /fund-script/bridge_l2.sh \"{0}\" \"{1}\" \"{2}\" \"{3}\"".format(
                    l1_bridge_address,
                    address,
                    balance,
                    l1_priv_key,
                ),
            )
        plan.print("Successfully bridged all prefunded accounts to L2")
    else:
        plan.print("Skipping bridging step - no prefunded accounts configured")

    if hasattr(l2_args.network_params, "faucet_params"):
        plan.print("Faucet params: {0}".format(l2_args.network_params.faucet_params))
        faucet_private_key = l2_args.network_params.faucet_params["private_key"]
        plan.print("Faucet private key: {0}".format(faucet_private_key))
        
        # Use cast to derive address from private key
        faucet_address = plan.run_sh(
            name="derive-faucet-address",
            description="Derive faucet address from private key",
            image=util.DEPLOYMENT_UTILS_IMAGE,
            run="cast wallet address --private-key {}".format(faucet_private_key),
        )
        plan.print("Faucet address: {0}".format(faucet_address))

        # Bridge funds to faucet address
        plan.print("Bridging funds to faucet address...")
        # fund_script_artifact = plan.upload_files(
        #     src="../static_files/scripts",
        #     name="bridge-l2-script",
        # )
        
        plan.run_sh(
            name="bridge-faucet-account",
            description="Bridge funds to faucet address",
            image=util.DEPLOYMENT_UTILS_IMAGE,
            env_vars={
                "L1_RPC_URL": l1_rpc_url,
                "FUND_PRIVATE_KEY": l1_priv_key,
            },
            files={
                "/fund-script": fund_script_artifact,
            },
            run="bash /fund-script/bridge_l2.sh \"{0}\" \"{1}\" \"{2}\" \"{3}\"".format(
                l1_bridge_address,
                faucet_address,
                "1ETH",
                l1_priv_key,
            ),
        )
        plan.print("Successfully bridged funds to faucet address")
    else:
        plan.print("Skipping faucet setup - no faucet params configured")

    for additional_service in l2_args.additional_services:
        if additional_service == "blockscout":
            plan.print("Launching op-blockscout")
            
            # Get L2 RPC URL from the first participant's execution layer
            l2_rpc_url = "http://{0}:{1}".format(
                all_el_contexts[0].ip_addr,
                all_el_contexts[0].rpc_port_num,
            )
            optimism_enabled = True  # Since this is an Optimism L2
            
            plan.print("Network name: {0}".format(network_params.name))
            plan.print("Network id: {0}".format(network_params.network_id))
            # Configure general arguments
            general_args = {
                "network_name": network_params.name,
                "network_id": str(network_params.network_id),
                # "api_protocol": "https",
                # "ws_protocol": "wss",
            }

            if blockscout_params.frontend_url and blockscout_params.backend_url:
                plan.print("Using public backend URL: " + blockscout_params.backend_url)
                general_args["app_host"] = blockscout_params.frontend_url
                general_args["api_host"] = blockscout_params.backend_url

            
            ethereum_args = {}

            rollup_filename = "rollup-{0}".format(str(network_params.network_id))
            l1_deposit_start_block = util.read_network_config_value(
                plan, deployment_output, rollup_filename, ".genesis.l1.number"
            )
            plan.print("l1_deposit_start_block")
            plan.print(l1_deposit_start_block)

            portal_address = util.read_network_config_value(
                plan, deployment_output, rollup_filename, ".deposit_contract_address"
            )
            plan.print("portal_address")
            plan.print(portal_address)
            
            # Configure Optimism arguments
            optimism_args = {
                "optimism_enabled": True,
                "l1_rpc_url": l1_rpc_url,
                "l2_rpc_url": l2_rpc_url,
                "network_name": network_params.name,
                "portal_address": portal_address, 
                "l1_deposit_start_block": l1_deposit_start_block, 
                "l1_withdrawals_start_block": l1_deposit_start_block,  
                "output_oracle_address": "0x0000000000000000000000000000000000000000",  
            }
            
            blockscout_output = blockscout.run(
                plan,
                general_args=general_args,
                ethereum_args=ethereum_args,
                optimism_args=optimism_args,
                persistent=persistent,
                node_selectors=global_node_selectors,
            )
            
            plan.print("Successfully launched op-blockscout")
            plan.print("Blockscout URL: {0}".format(blockscout_output["blockscout_url"]))
        # if additional_service == "blockscout":
        #     plan.print("Launching op-blockscout")
        #     blockscout.launch_blockscout(
        #         plan,
        #         l2_services_suffix,
        #         l1_rpc_url,
        #         all_el_contexts[0],  # first l2 EL url
        #         network_params.name,
        #         deployment_output,
        #         network_params.network_id,
        #     )
        #     plan.print("Successfully launched op-blockscout")
        
        elif additional_service == "tx_fuzzer":
            plan.print("Launching transaction spammer")
            fuzz_target = "http://{0}:{1}".format(
                all_el_contexts[0].ip_addr,
                all_el_contexts[0].rpc_port_num,
            )
            tx_fuzzer.launch(
                plan,
                "op-transaction-fuzzer-{0}".format(network_params.name),
                fuzz_target,
                tx_fuzzer_params,
                global_node_selectors,
            )
            plan.print("Successfully launched transaction spammer")

    plan.print(l2.participants)
    plan.print(
        "Begin your L2 adventures by depositing some L1 Kurtosis ETH to: {0}".format(
            l1_bridge_address
        )
    )
    return l2

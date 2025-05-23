ethereum_package_shared_utils = import_module(
    "github.com/ethpandaops/ethereum-package/src/shared_utils/shared_utils.star"
)

ethereum_package_el_context = import_module(
    "github.com/ethpandaops/ethereum-package/src/el/el_context.star"
)
ethereum_package_el_admin_node_info = import_module(
    "github.com/ethpandaops/ethereum-package/src/el/el_admin_node_info.star"
)

ethereum_package_node_metrics = import_module(
    "github.com/ethpandaops/ethereum-package/src/node_metrics_info.star"
)
ethereum_package_constants = import_module(
    "github.com/ethpandaops/ethereum-package/src/package_io/constants.star"
)

ethereum_package_input_parser = import_module(
    "github.com/ethpandaops/ethereum-package/src/package_io/input_parser.star"
)

constants = import_module("../../package_io/constants.star")
util = import_module("../../util.star")
observability = import_module("../../observability/observability.star")

RPC_PORT_NUM = 8545
WS_PORT_NUM = 8546
DISCOVERY_PORT_NUM = 30303
ENGINE_RPC_PORT_NUM = 9551

# The min/max CPU/memory that the execution node can use
EXECUTION_MIN_CPU = 100
EXECUTION_MIN_MEMORY = 256

# Paths
METRICS_PATH = "/metrics"

# The dirpath of the execution data directory on the client container
EXECUTION_DATA_DIRPATH_ON_CLIENT_CONTAINER = "/data/op-reth/execution-data"


def get_used_ports(discovery_port=DISCOVERY_PORT_NUM):
    used_ports = {
        constants.RPC_PORT_ID: ethereum_package_shared_utils.new_port_spec(
            RPC_PORT_NUM,
            ethereum_package_shared_utils.TCP_PROTOCOL,
            ethereum_package_shared_utils.HTTP_APPLICATION_PROTOCOL,
        ),
        constants.WS_PORT_ID: ethereum_package_shared_utils.new_port_spec(
            WS_PORT_NUM, ethereum_package_shared_utils.TCP_PROTOCOL
        ),
        constants.TCP_DISCOVERY_PORT_ID: ethereum_package_shared_utils.new_port_spec(
            discovery_port, ethereum_package_shared_utils.TCP_PROTOCOL
        ),
        constants.UDP_DISCOVERY_PORT_ID: ethereum_package_shared_utils.new_port_spec(
            discovery_port, ethereum_package_shared_utils.UDP_PROTOCOL
        ),
        constants.ENGINE_RPC_PORT_ID: ethereum_package_shared_utils.new_port_spec(
            ENGINE_RPC_PORT_NUM, ethereum_package_shared_utils.TCP_PROTOCOL
        ),
    }
    return used_ports


VERBOSITY_LEVELS = {
    ethereum_package_constants.GLOBAL_LOG_LEVEL.error: "v",
    ethereum_package_constants.GLOBAL_LOG_LEVEL.warn: "vv",
    ethereum_package_constants.GLOBAL_LOG_LEVEL.info: "vvv",
    ethereum_package_constants.GLOBAL_LOG_LEVEL.debug: "vvvv",
    ethereum_package_constants.GLOBAL_LOG_LEVEL.trace: "vvvvv",
}


def launch(
    plan,
    launcher,
    service_name,
    participant,
    global_log_level,
    persistent,
    tolerations,
    node_selectors,
    existing_el_clients,
    sequencer_enabled,
    sequencer_context,
    observability_helper,
    supervisors_params,
):
    log_level = ethereum_package_input_parser.get_client_log_level_or_default(
        participant.el_log_level, global_log_level, VERBOSITY_LEVELS
    )

    cl_client_name = service_name.split("-")[4]

    config = get_config(
        plan,
        launcher,
        service_name,
        participant,
        log_level,
        persistent,
        tolerations,
        node_selectors,
        existing_el_clients,
        cl_client_name,
        sequencer_enabled,
        sequencer_context,
        observability_helper,
    )

    service = plan.add_service(service_name, config)
    http_url = util.make_service_http_url(service, constants.RPC_PORT_ID)

    enode = ethereum_package_el_admin_node_info.get_enode_for_node(
        plan, service_name, constants.RPC_PORT_ID
    )

    metrics_info = observability.new_metrics_info(
        observability_helper, service, METRICS_PATH
    )

    return ethereum_package_el_context.new_el_context(
        client_name="reth",
        enode=enode,
        ip_addr=service.ip_address,
        rpc_port_num=RPC_PORT_NUM,
        ws_port_num=WS_PORT_NUM,
        engine_rpc_port_num=ENGINE_RPC_PORT_NUM,
        rpc_http_url=http_url,
        service_name=service_name,
        el_metrics_info=[metrics_info],
    )


def get_config(
    plan,
    launcher,
    service_name,
    participant,
    log_level,
    persistent,
    tolerations,
    node_selectors,
    existing_el_clients,
    cl_client_name,
    sequencer_enabled,
    sequencer_context,
    observability_helper,
):
    discovery_port = DISCOVERY_PORT_NUM
    ports = dict(get_used_ports(discovery_port))

    cmd = [
        "node",
        "-{0}".format(log_level),
        "--datadir=" + EXECUTION_DATA_DIRPATH_ON_CLIENT_CONTAINER,
        "--chain={0}".format(
            launcher.network
            if launcher.network in ethereum_package_constants.PUBLIC_NETWORKS
            else ethereum_package_constants.GENESIS_CONFIG_MOUNT_PATH_ON_CONTAINER
            + "/genesis-{0}.json".format(launcher.network_id)
        ),
        "--http",
        "--http.port={0}".format(RPC_PORT_NUM),
        "--http.addr=0.0.0.0",
        "--http.corsdomain=*",
        # WARNING: The admin info endpoint is enabled so that we can easily get ENR/enode, which means
        #  that users should NOT store private information in these Kurtosis nodes!
        "--http.api=admin,net,eth,web3,debug,trace",
        "--ws",
        "--ws.addr=0.0.0.0",
        "--ws.port={0}".format(WS_PORT_NUM),
        "--ws.api=net,eth",
        "--ws.origins=*",
        "--nat=extip:" + ethereum_package_constants.PRIVATE_IP_ADDRESS_PLACEHOLDER,
        "--authrpc.port={0}".format(ENGINE_RPC_PORT_NUM),
        "--authrpc.jwtsecret=" + ethereum_package_constants.JWT_MOUNT_PATH_ON_CONTAINER,
        "--authrpc.addr=0.0.0.0",
        "--discovery.port={0}".format(discovery_port),
        "--port={0}".format(discovery_port),
        "--rpc.eth-proof-window=302400",
    ]

    # configure files

    files = {
        ethereum_package_constants.GENESIS_DATA_MOUNTPOINT_ON_CLIENTS: launcher.deployment_output,
        ethereum_package_constants.JWT_MOUNTPOINT_ON_CLIENTS: launcher.jwt_file,
    }
    if persistent:
        files[EXECUTION_DATA_DIRPATH_ON_CLIENT_CONTAINER] = Directory(
            persistent_key="data-{0}".format(service_name),
            size=int(participant.el_volume_size)
            if int(participant.el_volume_size) > 0
            else constants.VOLUME_SIZE[launcher.network][
                constants.EL_TYPE.op_reth + "_volume_size"
            ],
        )

    # configure environment variables

    env_vars = participant.el_extra_env_vars

    # apply customizations

    if observability_helper.enabled:
        cmd.append("--metrics=0.0.0.0:{0}".format(observability.METRICS_PORT_NUM))

        observability.expose_metrics_port(ports)

    if not sequencer_enabled:
        cmd.append("--rollup.sequencer-http={0}".format(sequencer_context.rpc_http_url))

    if len(existing_el_clients) > 0:
        cmd.append(
            "--bootnodes="
            + ",".join(
                [
                    ctx.enode
                    for ctx in existing_el_clients[
                        : ethereum_package_constants.MAX_ENODE_ENTRIES
                    ]
                ]
            )
        )

    cmd += participant.el_extra_params

    config_args = {
        "image": participant.el_image,
        "ports": ports,
        "cmd": cmd,
        "files": files,
        "private_ip_address_placeholder": ethereum_package_constants.PRIVATE_IP_ADDRESS_PLACEHOLDER,
        "env_vars": env_vars,
        "labels": ethereum_package_shared_utils.label_maker(
            client=constants.EL_TYPE.op_reth,
            client_type=constants.CLIENT_TYPES.el,
            image=util.label_from_image(participant.el_image),
            connected_client=cl_client_name,
            extra_labels=participant.el_extra_labels,
        ),
        "tolerations": tolerations,
        "node_selectors": node_selectors,
    }

    # configure resources

    if participant.el_min_cpu > 0:
        config_args["min_cpu"] = participant.el_min_cpu
    if participant.el_max_cpu > 0:
        config_args["max_cpu"] = participant.el_max_cpu
    if participant.el_min_mem > 0:
        config_args["min_memory"] = participant.el_min_mem
    if participant.el_max_mem > 0:
        config_args["max_memory"] = participant.el_max_mem

    return ServiceConfig(**config_args)


def new_op_reth_launcher(
    deployment_output,
    jwt_file,
    network,
    network_id,
):
    return struct(
        deployment_output=deployment_output,
        jwt_file=jwt_file,
        network=network,
        network_id=network_id,
    )

constants = import_module("../../package_io/constants.star")
util = import_module("../../util.star")

ethereum_package_shared_utils = import_module(
    "github.com/ethpandaops/ethereum-package/src/shared_utils/shared_utils.star"
)

SERVICE_NAME = "grafana"
HTTP_PORT_NUMBER_UINT16 = 3000

TEMPLATES_FILEPATH = "./templates"

DATASOURCE_CONFIG_TEMPLATE_FILEPATH = TEMPLATES_FILEPATH + "/datasource.yml.tmpl"
DATASOURCE_CONFIG_REL_FILEPATH = "datasources/datasource.yml"

CONFIG_DIRPATH_ON_SERVICE = "/config"

USED_PORTS = {
    constants.HTTP_PORT_ID: ethereum_package_shared_utils.new_port_spec(
        HTTP_PORT_NUMBER_UINT16,
        ethereum_package_shared_utils.TCP_PROTOCOL,
        ethereum_package_shared_utils.HTTP_APPLICATION_PROTOCOL,
    )
}


def launch_grafana(
    plan,
    prometheus_url,
    loki_url,
    global_node_selectors,
    grafana_params,
):
    datasource_config_template = read_file(DATASOURCE_CONFIG_TEMPLATE_FILEPATH)

    config_artifact_name = create_config_artifact(
        plan,
        datasource_config_template,
        prometheus_url,
        loki_url,
    )

    config = get_config(
        config_artifact_name,
        global_node_selectors,
        grafana_params,
    )

    service = plan.add_service(SERVICE_NAME, config)

    service_url = util.make_service_http_url(service)

    provision_dashboards(plan, service_url, grafana_params.dashboard_sources)

    return service_url


def create_config_artifact(
    plan,
    datasource_config_template,
    prometheus_url,
    loki_url,
):
    datasource_data = new_datasource_config_template_data(prometheus_url, loki_url)
    datasource_template_and_data = ethereum_package_shared_utils.new_template_and_data(
        datasource_config_template, datasource_data
    )

    template_and_data_by_rel_dest_filepath = {
        DATASOURCE_CONFIG_REL_FILEPATH: datasource_template_and_data,
    }

    config_artifact_name = plan.render_templates(
        template_and_data_by_rel_dest_filepath, name="grafana-config"
    )

    return config_artifact_name


def new_datasource_config_template_data(prometheus_url, loki_url):
    return {
        "PrometheusUID": "grafanacloud-prom",
        "PrometheusURL": prometheus_url,
        "LokiUID": "grafanacloud-logs",
        "LokiURL": loki_url,
    }


def get_config(
    config_artifact_name,
    node_selectors,
    grafana_params,
):
    return ServiceConfig(
        image=grafana_params.image,
        ports=USED_PORTS,
        env_vars={
            "GF_PATHS_PROVISIONING": CONFIG_DIRPATH_ON_SERVICE,
            "GF_AUTH_ANONYMOUS_ENABLED": "true",
            "GF_AUTH_ANONYMOUS_ORG_ROLE": "Admin",
            "GF_AUTH_ANONYMOUS_ORG_NAME": "Main Org.",
        },
        files={
            CONFIG_DIRPATH_ON_SERVICE: config_artifact_name,
        },
        min_cpu=grafana_params.min_cpu,
        max_cpu=grafana_params.max_cpu,
        min_memory=grafana_params.min_mem,
        max_memory=grafana_params.max_mem,
        node_selectors=node_selectors,
    )


# The dashboards pointed by the dashboard_sources locators are uploaded
# as file artifacts, then mounted into a container and pushed to the Grafana
# instance using https://grafana.github.io/grizzly/.
def provision_dashboards(plan, service_url, dashboard_sources):
    if len(dashboard_sources) == 0:
        return

    def grr_push(dir):
        return 'grr push "{0}" -e --disable-reporting'.format(dir)

    def grr_push_dashboards(name):
        return [
            grr_push("{0}/folders".format(name)),
            grr_push("{0}/dashboards".format(name)),
        ]

    grr_commands = [
        "grr config create-context kurtosis",
    ]

    files = {}
    for index, dashboard_src in enumerate(dashboard_sources):
        dashboard_name = "dashboards-{0}".format(index)
        dashboard_artifact_name = plan.upload_files(dashboard_src, name=dashboard_name)

        files["/" + dashboard_name] = dashboard_artifact_name
        grr_commands += grr_push_dashboards(dashboard_name)

    plan.run_sh(
        description="upload dashboards",
        # latest version, no tagged release yet
        image="grafana/grizzly:main-0b88d01",
        env_vars={
            "GRAFANA_URL": service_url,
        },
        files=files,
        run=util.join_cmds(grr_commands),
    )

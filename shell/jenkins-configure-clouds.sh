#!/bin/bash -l
# SPDX-License-Identifier: EPL-1.0
##############################################################################
# Copyright (c) 2018 The Linux Foundation and others.
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Eclipse Public License v1.0
# which accompanies this distribution, and is available at
# http://www.eclipse.org/legal/epl-v10.html
##############################################################################
# Pulls global variable definitions out of a file.
#
# Configuration is read from $WORKSPACE/jenkins-config/clouds/openstack/$cloud/cloud.cfg
#
# Requirements: lftools must be installed to /tmp/v/lftools
#
# Parameters:
#
#     WORKSPACE:  The path to the local ci-management repository.
#     jenkins_silos:  Space separated list of Jenkins silos to push
#                     configuration to. This must match a configuration section
#                     in the config file located at
#                     ~/.config/jenkins_jobs/jenkins_jobs.ini config file.
#                     (default: jenkins)
#
# Local testing can be performed by exporting the parameters "WORKSPACE" and
# "jenkins_silos" as environment variables. For example:
#
#    export WORKSPACE=/tmp/ci-management
#    export jenkins_silos=sandbox
#    bash ./global-jjb/shell/jenkins-configure-clouds.sh
echo "---> jenkins-configure-clouds.sh"

if [ ! -d "$WORKSPACE/jenkins-config/clouds" ]; then
    echo "WARN: jenkins-config/clouds does not exist. Skipping cloud management..."
    exit 0
fi

GROOVY_SCRIPT_FILE="global-jjb/jenkins-admin/manage_clouds.groovy"
OS_CLOUD_DIR="$WORKSPACE/jenkins-config/clouds/openstack"
SCRIPT_DIR="$WORKSPACE/archives/groovy-inserts"
mkdir -p "$SCRIPT_DIR"

silos="${jenkins_silos:-jenkins}"


set -eu -o pipefail

testversion() {
    local current_val="$1" operator="$2" test_value="$3"
    awk -vv1="$current_val" -vv2="$test_value" 'BEGIN {
        split(v1, a, /\:/);
        if (a[2] == '"$test_value"') {
            exit (a[2] == '"$test_value"') ? 0 : 1
        }
        else {
            exit (a[2] '"$operator"' '"$test_value"') ? 0 : 1
        }
    }'
}

get_cfg() {
    if [ -z ${3+x} ]; then
        >&2 echo "Usage: get_cfg CFG_FILE SETTING DEFAULT"
        exit 1
    fi

    local cfg_file="$1"
    local setting="$2"
    local default="$3"

    if [ ! -f "$cfg_file" ]; then
        >&2 echo "ERROR: Configuration file $cfg_file not found."
        exit 1
    fi

    cfg=$(grep "^${setting^^}=" "$cfg_file" | tail -1 | awk -F'=' '{print $2}')
    cfg=${cfg:-"$default"}
    echo "$cfg"
}
export get_cfg


get_cloud_cfg() {
    if [ -z "$1" ]; then
        >&2 echo "Usage: get_cloud_cfg CFG_DIR"
        exit 1
    fi

    local cfg_dir="$1"
    local silo="$2"
    local cfg_file="$cfg_dir/cloud.cfg"

    cloud_name=$(basename "$cfg_dir")
    cloud_url=$(get_cfg "$cfg_file" CLOUD_URL "")
    cloud_ignore_ssl=$(get_cfg "$cfg_file" CLOUD_IGNORE_SSL "false")
    cloud_zone=$(get_cfg "$cfg_file" CLOUD_ZONE "")
    cloud_credential_id=$(get_cfg "$cfg_file" CLOUD_CREDENTIAL_ID "os-cloud")

    echo "default_options = new SlaveOptions("
    get_minion_options "$cfg_file" "$silo"
    echo ")"

    echo "cloud = new JCloudsCloud("
    echo "    \"$cloud_name\","
    echo "    \"$cloud_url\","
    echo "    $cloud_ignore_ssl,"
    echo "    \"$cloud_zone\","
    echo "    default_options,"
    echo "    templates,"
    echo "    \"$cloud_credential_id\""
    echo ")"
}


get_launcher_factory() {
    if [ -z "$1" ]; then
        >&2 echo "Usage: get_launcher_factory JNLP|SSH"
        exit 1
    fi

    local connection_type="$1"

    if [ "$connection_type" == "JNLP" ]; then
        echo "new LauncherFactory.JNLP()"
    elif [ "$connection_type" == "SSH" ]; then
        echo "new LauncherFactory.SSH(\"$key_pair_name\", \"\")"
    else
        >&2 echo "Unknown connection type $connection_type"
        exit 1
    fi
}


get_minion_options() {
    if [ -z "$1" ]; then
        >&2 echo "Usage: get_minion_options CFG_FILE"
        exit 1
    fi

    local cfg_file="$1"
    local silo="${2:-}"

    # Create a flavor mapping to manage hardware_id until OpenStack Cloud
    # plugin supports using names
    declare -A flavors
    # ShellCheck 0.4.4 incorrectly flags these as unused vars
    # Fails on first instance of each different associatve array prefix
    # Fails when using single/double/no quotes, all of which are valid bash
    # shellcheck disable=SC2154
    flavors["acumos-highcpu-4-avx"]="c720c1f8-62e9-4695-823d-f7f54db46c86"
    flavors["lf-highcpu-2"]="1051d06a-61ea-45e3-b9b4-93de92880b27"
    flavors["lf-highcpu-4"]="35eb8e11-490f-4d1a-9f19-76091fc04547"
    flavors["lf-highcpu-8"]="68af673f-54ee-4255-871c-158c18e4f643"
    flavors["lf-standard-1"]="7d76cbb0-f547-4c2c-beaf-554f33832721"
    flavors["lf-standard-2"]="ef454088-7839-42a0-bf23-5e0ab6386a27"
    flavors["lf-standard-4"]="bd74e1e6-c2ed-475b-ab3f-2ce13936a215"
    flavors["lf-standard-8"]="32d74024-8418-41b6-9675-b77816748148"
    flavors["odl-highcpu-2"]="def1b86f-b7f8-4943-b430-4a0599170006"
    flavors["odl-highcpu-4"]="0c8ec795-2ff8-4623-98cf-b4c1d92bb37c"
    flavors["odl-highcpu-8"]="458d6499-e2c8-4580-aa88-a4a04a33ee25"
    flavors["odl-standard-1"]="35800a3f-0c69-428d-b5cb-136d17d46c48"
    flavors["odl-standard-2"]="8ead227a-acfe-4290-be70-fbab92e6dd2f"
    flavors["odl-standard-4"]="f76fb18d-d5fb-4175-95c1-b29d8039d102"
    flavors["odl-standard-8"]="ba38b1af-4f87-4e4e-860e-94e8329d0d78"
    flavors["v1-standard-1"]="bbcb7eb5-5c8d-498f-9d7e-307c575d3566"
    flavors["v1-standard-2"]="ca2a6e9c-2236-4107-8905-7ae9427132ff"
    flavors["v1-standard-4"]="5cf64088-893b-46b5-9bb1-ee020277635d"
    flavors["v1-standard-8"]="6eec77b4-2286-4e3b-b3f0-cac67aa2c727"
    flavors["v1-standard-16"]="2f8730dd-7688-4b72-a512-99fb9a482414"
    flavors["v1-standard-32"]="0da688af-bb0c-4116-a158-cbf37240a8b1"
    flavors["v1-standard-48"]="69471d69-61fb-40dd-bdf3-e6b7f4e6daa3"
    flavors["v1-standard-64"]="0c1d9008-f546-4608-9e8f-f8bdaec8dddd"
    flavors["v1-standard-96"]="5741c775-92a4-4488-bd77-dd7b08e2be81"
    flavors["v1-standard-128"]="e82d0a5b-8031-4526-9a5d-a15f7b4d48ff"
    flavors["v2-highcpu-1"]="c04abb7a-2b61-4ed3-8ce8-6c40ad9df750"
    flavors["v2-highcpu-2"]="03bdf34e-8905-46bc-a4b9-8dbf94b6e06d"
    flavors["v2-highcpu-4"]="3b72e578-7875-4e0e-91b7-71ed292f3ca2"
    flavors["v2-highcpu-8"]="221de281-95ec-414f-8e42-c86c9e0b318d"
    flavors["v2-highcpu-16"]="ddd6863a-ef4f-475c-9aee-61d46898651d"
    flavors["v2-highcpu-32"]="21dfb8a3-c472-4a2c-a8e1-4da8de415ff8"
    flavors["v2-standard-1"]="52a01f6b-e660-48b5-8c06-5fb2a0fab0ec"
    flavors["v2-standard-2"]="ac2c4d17-8d6f-4e3c-a9eb-57c155f0a949"
    flavors["v2-standard-4"]="d9115351-defe-4fac-986b-1a1187e2c31c"
    flavors["v2-standard-8"]="e6fe2e37-0e38-438c-8fa5-fc2d79d0a7bb"
    flavors["v2-standard-16"]="9e4b01cd-6744-4120-aafe-1b5e17584919"
    flavors["v3-standard-2"]="d6906d2a-e83f-42be-b33e-fbaeb5c511cb"
    flavors["v3-standard-4"]="5f1eb09f-e764-4642-a16f-a7230ec025e7"
    flavors["v3-standard-8"]="47d3707a-c6c6-46ea-a15b-095e336b1edc"
    flavors["v3-standard-16"]="8587d458-69de-4fc5-be51-c5e671bc35d5"
    flavors["v3-standard-32"]="3e01b39f-45a9-4b7b-b6dc-14378433dc36"
    flavors["v3-standard-48"]="06a0e8b7-949a-439d-a185-208ae9e645b2"
    flavors["v3-standard-64"]="402a2759-cc01-481d-a8b7-2c7056f153f7"
    flavors["v3-standard-96"]="883b0564-dec6-4e51-88c7-83d86994fcf0"

    image_name=$(get_cfg "$cfg_file" IMAGE_NAME "")
    volume_size=$(get_cfg "$cfg_file" VOLUME_SIZE "")
    hardware_id=$(get_cfg "$cfg_file" HARDWARE_ID "")
    network_id=$(get_cfg "$cfg_file" NETWORK_ID "")
    udi_default="$(get_cfg "$(dirname "$cfg_file")/cloud.cfg" USER_DATA_ID "jenkins-init-script")"
    user_data_id=$(get_cfg "$cfg_file" USER_DATA_ID "$udi_default")

    # Handle Sandbox systems that might have a different cap.
    if [ "$silo" == "sandbox" ]; then
        instance_cap=$(get_cfg "$cfg_file" SANDBOX_CAP "null")
    else
        instance_cap=$(get_cfg "$cfg_file" INSTANCE_CAP "null")
    fi

    floating_ip_pool=$(get_cfg "$cfg_file" FLOATING_IP_POOL "")
    security_groups=$(get_cfg "$cfg_file" SECURITY_GROUPS "default")
    availability_zone=$(get_cfg "$cfg_file" AVAILABILITY_ZONE "")
    start_timeout=$(get_cfg "$cfg_file" START_TIMEOUT "600000")
    kpn_default="$(get_cfg "$(dirname "$cfg_file")/cloud.cfg" KEY_PAIR_NAME "jenkins-ssh")"
    key_pair_name=$(get_cfg "$cfg_file" KEY_PAIR_NAME "$kpn_default")
    num_executors=$(get_cfg "$cfg_file" NUM_EXECUTORS "1")
    jvm_options=$(get_cfg "$cfg_file" JVM_OPTIONS "")
    fs_root=$(get_cfg "$cfg_file" FS_ROOT "/w")
    connection_type=$(get_cfg "$cfg_file" CONNECTION_TYPE "SSH")
    launcher_factory=$(get_launcher_factory "$connection_type")
    node_properties=$(get_cfg "$cfg_file" NODE_PROPERTIES, "null")
    retention_time=$(get_cfg "$cfg_file" RETENTION_TIME "0")
    config_drive=$(get_cfg "$cfg_file" CONFIG_DRIVE, "null")


    if [ -n "$volume_size" ]; then
        echo "    new BootSource.VolumeFromImage(\"$image_name\", $volume_size),"
    else
        echo "    new BootSource.Image(\"$image_name\"),"
    fi

    echo "    \"${flavors[${hardware_id}]}\","
    echo "    \"$network_id\","
    echo "    \"$user_data_id\","
    echo "    $instance_cap,"

    # Handle specifying the minimum instance count across different versions
    if testversion "$os_plugin_version" '>=' '2.47'
    then
        instance_min=$(get_cfg "$cfg_file" INSTANCE_MIN "null")
        echo "    $instance_min,"
    else
        instance_min=$(get_cfg "$cfg_file" INSTANCE_MIN_CAPMAX "null")
        echo "    $instance_min,"
    fi

    echo "    \"$floating_ip_pool\","
    echo "    \"$security_groups\","
    echo "    \"$availability_zone\","
    echo "    $start_timeout,"
    echo "    \"$key_pair_name\","
    echo "    $num_executors,"
    echo "    \"$jvm_options\","
    echo "    \"$fs_root\","
    echo "    $launcher_factory,"

    if testversion "$os_plugin_version" '>=' '2.47'
    then
        echo "    $node_properties,"
        echo "    $retention_time",
        echo "    $config_drive"
    else
        echo "    $retention_time"
    fi


}

get_template_cfg() {
    if [ -z "$2" ]; then
        >&2 echo "Usage: get_template_cfg CFG_FILE SILO [MINION_PREFIX]"
        exit 1
    fi

    local cfg_file="$1"
    local silo="${2}"
    local minion_prefix="${3:-}"


    template_name=$(basename "$cfg_file" .cfg)
    labels=$(get_cfg "$cfg_file" LABELS "")

    echo "minion_options = new SlaveOptions("
    get_minion_options "$cfg_file" "$silo"
    echo ")"

    echo "template = new JCloudsSlaveTemplate("
    # TODO: Figure out how to insert the "prd / snd" prefix into template name.
    echo "    \"${minion_prefix}${template_name}\","
    echo "    \"$template_name $labels\","
    echo "    minion_options,"
    echo ")"
}

# shellcheck disable=SC1090
. ~/lf-env.sh

lf-activate-venv --python python3 lftools

mapfile -t clouds < <(ls -d1 "$OS_CLOUD_DIR"/*/)

for silo in $silos; do

    script_file="$SCRIPT_DIR/${silo}-cloud-cfg.groovy"
    cp "$GROOVY_SCRIPT_FILE" "$script_file"

    # Linux Foundation Jenkins systems use "prd-" and "snd-" to mark
    # production and sandbox servers.
    if [ "$silo" == "releng" ] || [ "$silo" == "production" ]; then
        node_prefix="prd-"
    elif [ "$silo" == "sandbox" ]; then
        node_prefix="snd-"
    else
        node_prefix="${silo}-"
    fi

    set +x  # Disable `set -x` to prevent printing passwords
    echo "Configuring $silo"
    JENKINS_URL=$(crudini --get "$HOME"/.config/jenkins_jobs/jenkins_jobs.ini "$silo" url)
    JENKINS_USER=$(crudini --get "$HOME"/.config/jenkins_jobs/jenkins_jobs.ini "$silo" user)
    JENKINS_PASSWORD=$(crudini --get "$HOME"/.config/jenkins_jobs/jenkins_jobs.ini "$silo" password)
    export JENKINS_URL
    export JENKINS_USER
    export JENKINS_PASSWORD

    # JENKINS_{URL,USER,PASSWORD} env vars are required for the "lftools jenkins
    # plugins list" call
    os_plugin_version="$(lftools jenkins plugins list \
        | grep -i 'OpenStack Cloud Plugin')"

    echo "-----> Groovy script $script_file"
    for cloud in "${clouds[@]}"; do
        cfg_dir="${cloud}"
        echo "Processing $cfg_dir"
        insert_file="$SCRIPT_DIR/$silo/$(basename "$cloud")/cloud-cfg.txt"
        mkdir -p "$(dirname "$insert_file")"
        rm -f "$insert_file"

        {
            echo ""
            echo "//////////////////////////////////////////////////"
            echo "// Cloud config for $(basename "$cloud")"
            echo "//////////////////////////////////////////////////"
            echo ""
        } >> "$insert_file"


        echo "templates = []" >> "$insert_file"
        mapfile -t templates < <(find "$cfg_dir" -maxdepth 1 -not -type d -not -name "cloud.cfg")
        for template in "${templates[@]}"; do
            get_template_cfg "$template" "$silo" "$node_prefix" >> "$insert_file"
            echo "templates.add(template)" >> "$insert_file"
        done

        get_cloud_cfg "$cfg_dir" "$silo" >> "$insert_file"
        echo "clouds.add(cloud)" >> "$insert_file"

        cat "$insert_file" >> "$script_file"
    done

    lftools jenkins groovy "$script_file"
done

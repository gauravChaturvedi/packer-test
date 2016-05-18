#!/bin/bash

set -e

READ_TIMEOUT="-t 20"
PINNED_DOCKER_VERSION="1.9.1"
MIN_DOCKER_VERSION="1.7.1"
SKIP_DOCKER_INSTALL=1
SKIP_OPERATOR_INSTALL=0
NO_PROXY=1
AIRGAP=0
REPLICATED_INSTALL_HOST="get.replicated.com"
REPLICATED_DOCKER_HOST="quay.io"
RELEASE_CHANNEL="stable"
REPLICATED_TAG=$REPLICATED_TAG
REPLICATED_UI_TAG=$REPLICATED_UI_TAG
REPLICATED_OPERATOR_TAG=$REPLICATED_OPERATOR_TAG
OPERATOR_TAGS="local"

if [ ! -d /data/replicated ]; then
    mkdir -p /data/replicated
fi

sudo ln -s /data/replicated /var/lib/replicated


command_exists() {
    command -v "$@" > /dev/null 2>&1
}

detect_init_system() {
    if [[ "`systemctl 2>/dev/null`" =~ -\.mount ]]; then
        INIT_SYSTEM=systemd
    else
        echo >&2 "Error: failed to detect init system or unsupported."
        exit 1
    fi
}

read_replicated_conf() {
    unset REPLICATED_CONF_VALUE
    if [ -f /etc/replicated.conf ]; then
        echo "displaying file"
        cat /etc/replicated.conf
        REPLICATED_CONF_VALUE=$(cat /etc/replicated.conf | grep -o "\"$1\":\s*\"[^\"]*" | sed "s/\"$1\":\s*\"//") || true
    fi
}

read_replicated_opts() {
    REPLICATED_OPTS_VALUE="$(echo "$REPLICATED_OPTS" | grep -o "$1=[^ ]*" | cut -d'=' -f2)"
}

ask_for_private_ip() {
    _count=0
    _regex="^[[:digit:]]+: ([^[:space:]]+)[[:space:]]+[[:alnum:]]+ ([[:digit:].]+)"
    while read -r _line; do
        [[ $_line =~ $_regex ]]
        if [ "${BASH_REMATCH[1]}" != "lo" ]; then
            _iface_names[$((_count))]=${BASH_REMATCH[1]}
            _iface_addrs[$((_count))]=${BASH_REMATCH[2]}
            let "_count += 1"
        fi
    done <<< "$(ip -4 -o addr)"
    if [ "$_count" -eq "0" ]; then
        echo >&2 "Error: The installer couldn't discover any valid network interfaces on this machine."
        echo >&2 "Check your network configuration and re-run this script again."
        echo >&2 "If you want to skip this discovery process, pass the 'local-address' arg to this script, e.g. 'sudo ./install.sh local-address=1.2.3.4'"
        exit 1
    elif [ "$_count" -eq "1" ]; then
        PRIVATE_ADDRESS=${_iface_addrs[0]}
        printf "The installer will use network interface '%s' (with IP address '%s')\n" ${_iface_names[0]} ${_iface_addrs[0]}
        return
    fi
    printf "The installer was unable to automatically detect the private IP address of this machine.\n"
    printf "Please choose one of the following network interfaces:\n"
    for i in $(seq 0 $((_count-1))); do
        printf "[%d] %-5s\t%s\n" $i ${_iface_names[$i]} ${_iface_addrs[$i]}
    done
    while true; do
        printf "Enter desired number (0-%d): " $((_count-1))
        set +e
        read -t 60 chosen < /dev/tty
        set -e
        if [ -z "$chosen" ]; then
            continue
        fi
        if [ "$chosen" -ge "0" ] && [ "$chosen" -lt "$_count" ]; then
            PRIVATE_ADDRESS=${_iface_addrs[$chosen]}
            printf "The installer will use network interface '%s' (with IP address '%s').\n" ${_iface_names[$chosen]} $PRIVATE_ADDRESS
            return
        fi
    done
}

discover_private_ip() {
    if [ -n "$PRIVATE_ADDRESS" ]; then
        return
    fi

    read_replicated_conf "LocalAddress"
    if [ -n "$REPLICATED_CONF_VALUE" ]; then
        PRIVATE_ADDRESS="$REPLICATED_CONF_VALUE"
        printf "The installer will use local address '%s' (imported from /etc/replicated.conf 'LocalAddress')\n" $PRIVATE_ADDRESS
        return
    fi

    ask_for_private_ip
}

discover_public_ip() {
    # gce
    set +e
    if command_exists "curl"; then
        _out=$(curl --max-time 5 --connect-timeout 2 -qSfs -H 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null)
    else
        _out=$(wget -t 1 --timeout=5 --connect-timeout=2 -qO- --header='Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null)
    fi
    _status=$?
    set -e
    if [ "$_status" -eq "0" ] && [ -n "$_out" ]; then
        PUBLIC_ADDRESS=$_out
        return
    fi
    # ec2
    set +e
    if command_exists "curl"; then
        _out=$(curl --max-time 5 --connect-timeout 2 -qSfs http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
    else
        _out=$(wget -t 1 --timeout=5 --connect-timeout=2 -qO- http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
    fi
    _status=$?
    set -e
    if [ "$_status" -eq "0" ] && [ -n "$_out" ]; then
        PUBLIC_ADDRESS=$_out
        return
    fi
}

DAEMON_TOKEN=
get_daemon_token() {
    if [ -n "$DAEMON_TOKEN" ]; then
        return
    fi

    read_replicated_opts "DAEMON_TOKEN"
    if [ -n "$REPLICATED_OPTS_VALUE" ]; then
        DAEMON_TOKEN="$REPLICATED_OPTS_VALUE"
        return
    fi

    read_replicated_conf "DaemonToken"
    if [ -n "$REPLICATED_CONF_VALUE" ]; then
        DAEMON_TOKEN="$REPLICATED_CONF_VALUE"
        return
    fi

    DAEMON_TOKEN="$(head -c 128 /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
}

remove_docker_containers() {
    # try twice because of aufs error "Unable to remove filesystem"
    if docker inspect replicated &>/dev/null; then
        set +e
        docker rm -f replicated
        set -e
        if [ "$?" -ne "0" ]; then
            if docker inspect replicated &>/dev/null; then
                printf "Failed to remove replicated container, retrying\n"
                sleep 1
                docker rm -f replicated
            fi
        fi
    fi
    if docker inspect replicated-ui &>/dev/null; then
        set +e
        docker rm -f replicated-ui
        set -e
        if [ "$?" -ne "0" ]; then
            if docker inspect replicated-ui &>/dev/null; then
                printf "Failed to remove replicated-ui container, retrying\n"
                sleep 1
                docker rm -f replicated-ui
            fi
        fi
    fi
}

pull_docker_images() {
    docker pull $REPLICATED_DOCKER_HOST/replicated/replicated:$REPLICATED_TAG
    docker pull $REPLICATED_DOCKER_HOST/replicated/replicated-ui:$REPLICATED_UI_TAG
}

load_docker_images() {
    docker load < replicated.tar
    docker load < replicated-ui.tar
}

REPLICATED_OPTS=
build_replicated_opts() {
    if [ -n "$REPLICATED_OPTS" ]; then
        return
    fi


    REPLICATED_OPTS="-e LOG_LEVEL=info"

    if [ -n "$PROXY_ADDRESS" ]; then
        REPLICATED_OPTS="$REPLICATED_OPTS -e HTTP_PROXY=$PROXY_ADDRESS"
    fi
    if [ "$SKIP_OPERATOR_INSTALL" -ne "1" ]; then
        REPLICATED_OPTS="$REPLICATED_OPTS -e DAEMON_TOKEN=$DAEMON_TOKEN"
    fi
}

write_replicated_configuration() {
    cat > $CONFDIR/replicated <<-EOF
RELEASE_CHANNEL=$RELEASE_CHANNEL
DOCKER_HOST_IP=$DOCKER_HOST_IP
PRIVATE_ADDRESS=$PRIVATE_ADDRESS
SKIP_OPERATOR_INSTALL=$SKIP_OPERATOR_INSTALL
REPLICATED_OPTS="$REPLICATED_OPTS"
EOF
}

write_systemd_services() {
    cat > /etc/systemd/system/replicated.service <<-EOF
[Unit]
Description=Replicated Service
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
KillMode=none
EnvironmentFile=$CONFDIR/replicated
ExecStartPre=-/usr/bin/docker create --name=replicated \\
    -p 9874-9880:9874-9880/tcp \\
    -v /:/replicated/host:ro \\
    -v /etc/replicated.alias:/etc/replicated.alias \\
    -v /etc/docker/certs.d:/etc/docker/certs.d \\
    -v /var/run/docker.sock:/var/run/docker.sock \\
    -v /var/lib/replicated:/var/lib/replicated \\
    -v /etc/replicated.conf:/etc/replicated.conf \\
    -e DOCKER_HOST_IP=\${DOCKER_HOST_IP} \\
    -e LOCAL_ADDRESS=\${PRIVATE_ADDRESS} \\
    -e RELEASE_CHANNEL=\${RELEASE_CHANNEL} \\
    \$REPLICATED_OPTS \\
    $REPLICATED_DOCKER_HOST/replicated/replicated:$REPLICATED_TAG
ExecStart=/usr/bin/docker start -a replicated
ExecStop=/usr/bin/docker stop replicated
Restart=on-failure
RestartSec=7

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/replicated-ui.service <<-EOF
[Unit]
Description=Replicated Service
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
KillMode=none
EnvironmentFile=$CONFDIR/replicated
ExecStartPre=-/usr/bin/docker create --name=replicated-ui \\
    -p 8800:8800/tcp \\
    --volumes-from replicated \\
    $REPLICATED_DOCKER_HOST/replicated/replicated-ui:$REPLICATED_UI_TAG
ExecStart=/usr/bin/docker start -a replicated-ui
ExecStop=/usr/bin/docker stop replicated-ui
Restart=on-failure
RestartSec=7

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

stop_systemd_services() {
    if systemctl status replicated &>/dev/null; then
        systemctl stop replicated
    fi
    if systemctl status replicated-ui &>/dev/null; then
        systemctl stop replicated-ui
    fi
}

start_systemd_services() {
    systemctl enable replicated
    systemctl enable replicated-ui
    systemctl start replicated
    systemctl start replicated-ui
}

install_alias_file() {
    # Old script might have mounted this file when it didn't exist, and now it's a folder.
    if [ -d "/etc/replicated.alias" ]; then
      rm -rf /etc/replicated.alias
    fi

    if ! grep -q -s "sudo docker exec -it replicated replicated" /etc/replicated.alias; then
      # Always append because daemon might add more aliases to this file
      cat >> /etc/replicated.alias <<-EOF
alias replicated="sudo docker exec -it replicated replicated"
EOF
    fi

    bashrc_file=
    if [ -f /etc/bashrc ]; then
        bashrc_file="/etc/bashrc"
    elif [ -f /etc/bash.bashrc ]; then
        bashrc_file="/etc/bash.bashrc"
    else
        echo >&2 'No global bashrc file found. Replicated command aliasing will be disabled.'
    fi

    if [ -n "$bashrc_file" ]; then
        if ! grep -q "/etc/replicated.alias" "$bashrc_file"; then
            cat >> "$bashrc_file" <<-EOF

if [ -f /etc/replicated.alias ]; then
    . /etc/replicated.alias
fi
EOF
        fi
    fi
}

install_operator() {
    prefix="/$RELEASE_CHANNEL"
    if [ "$prefix" = "/stable" ]; then
        prefix=
    fi
    if [ "$AIRGAP" -ne "1" ]; then
        cmd=
        if command_exists "curl"; then
            cmd="curl -sSL"
            if [ -n "$PROXY_ADDRESS" ]; then
                cmd=$cmd" -x $PROXY_ADDRESS"
            fi
        else
            cmd="wget -qO-"
        fi
        $cmd https://$REPLICATED_INSTALL_HOST$prefix/operator?replicated_operator_tag=$REPLICATED_OPERATOR_TAG > /tmp/operator_install.sh
    fi
    opts="no-docker daemon-endpoint=$PRIVATE_ADDRESS:9879 daemon-token=$DAEMON_TOKEN private-address=$PRIVATE_ADDRESS tags=$OPERATOR_TAGS"
    if [ -z "$PROXY_ADDRESS" ]; then
        opts=$opts" no-proxy"
    fi
    if [ -z "$READ_TIMEOUT" ]; then
        opts=$opts" no-auto"
    fi
    if [ "$AIRGAP" -eq "1" ]; then
        opts=$opts" airgap"
    fi
    # When this script is piped into bash as stdin, apt-get will eat the remaining parts of this script,
    # preventing it from being executed.  So using /dev/null here to change stdin for the docker script.
    if [ "$AIRGAP" -eq "1" ]; then
        bash ./operator_install.sh $opts < /dev/null
    else
        bash /tmp/operator_install.sh $opts < /dev/null
    fi
}

outro() {
    if [ -z "$PUBLIC_ADDRESS" ]; then
        PUBLIC_ADDRESS="<this_server_address>"
    fi
    printf "To continue the installation, visit the following URL in your browser:\n\n  https://%s:8800\n" "$PUBLIC_ADDRESS"
    if ! command_exists "replicated"; then
        printf "\nTo create an alias for the replicated cli command run the following in your current shell or log out and log back in:\n\n  source /etc/replicated.alias\n"
    fi
    printf "\n"
}

################################################################################
# Execution starts here
################################################################################

case "$(uname -m)" in
    *64)
        ;;
    *)
        echo >&2 'Error: you are not using a 64bit platform.'
        echo >&2 'This installer currently only supports 64bit platforms.'
        exit 1
        ;;
esac

user="$(id -un 2>/dev/null || true)"

if [ "$user" != "root" ]; then
    echo >&2 "Error: This script requires admin privileges. Please re-run it as root."
    exit 1
fi

detect_init_system

CONFDIR="/etc/default"
if [ "$INIT_SYSTEM" = "systemd" ] && [ -d "/etc/sysconfig" ]; then
    CONFDIR="/etc/sysconfig"
fi

# read existing replicated opts values
if [ -f $CONFDIR/replicated ]; then
    # shellcheck source=replicated-default
    . $CONFDIR/replicated
fi
if [ -f $CONFDIR/replicated-operator ]; then
    # support for the old installation script that used REPLICATED_OPTS for
    # operator
    tmp_replicated_opts="$REPLICATED_OPTS"
    # shellcheck source=replicated-operator-default
    . $CONFDIR/replicated-operator
    REPLICATED_OPTS="$tmp_replicated_opts"
fi

# override these values with command line flags
while [ "$1" != "" ]; do
    _param=`echo "$1" | awk -F= '{print $1}'`
    _value=`echo "$1" | awk -F= '{print $2}'`
    case $_param in
        http-proxy|http_proxy)
            PROXY_ADDRESS="$_value"
            ;;
        local-address|local_address)
            PRIVATE_ADDRESS="$_value"
            ;;
        no-operator|no_operator)
            SKIP_OPERATOR_INSTALL=1
            ;;
        no-docker|no_docker)
            SKIP_DOCKER_INSTALL=1
            ;;
        no-proxy|no_proxy)
            NO_PROXY=1
            ;;
        airgap)
            AIRGAP=1
            ;;
        no-auto|no_auto)
            READ_TIMEOUT=
            ;;
        daemon-token|daemon_token)
            DAEMON_TOKEN="$_value"
            ;;
        tags)
            OPERATOR_TAGS="$_value"
            ;;
        *)
            echo >&2 "Error: unknown parameter \"$_param\""
            exit 1
            ;;
    esac
    shift
done

discover_private_ip

if [ "$AIRGAP" -ne "1" ]; then
    printf "Determining public ip address\n"
    discover_public_ip
fi

get_daemon_token

if [ -z "$DOCKER_HOST_IP" ]; then
    DOCKER_HOST_IP=$(ip -4 addr show docker0 | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)
fi

if [ "$AIRGAP" -ne "1" ]; then
    printf "Pulling latest replicated and replicated-ui containers\n"
    pull_docker_images
else
    printf "Loading replicated and replicated-ui images from package\n"
    load_docker_images
fi

printf "Stopping replicated and replicated-ui service\n"
remove_docker_containers
case "$INIT_SYSTEM" in
    systemd)
        stop_systemd_services
        ;;
esac

printf "Installing replicated and replicated-ui service\n"
build_replicated_opts
write_replicated_configuration
case "$INIT_SYSTEM" in
    systemd)
        write_systemd_services
        ;;
esac

printf "Starting replicated and replicated-ui service\n"
case "$INIT_SYSTEM" in
    systemd)
        start_systemd_services
        ;;
esac

printf "Installing replicated command alias\n"
install_alias_file

if [ "$SKIP_OPERATOR_INSTALL" -ne "1" ]; then
    # we write this value to the opts file so if you didn't install it the first
    # time it will not install when updating
    printf "Installing local operator\n"
    install_operator
fi

outro
exit 0

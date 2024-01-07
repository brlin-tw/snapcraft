#!/bin/bash -e

SNAPCRAFT_DIR=${SNAPCRAFT_DIR:=$( cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd )}

# Check if SNAPCRAFT_DIR is pointing to snapcraft sources.
if ! grep -q '^name: snapcraft$' "${SNAPCRAFT_DIR}/snap/snapcraft.yaml"; then
    echo "This is not the snapcraft.yaml for the snapcraft project"
    exit 1
fi

# Check whether the user may be in an HTTP(S) proxy only network.
http_proxy_detected=
if test -v HTTP_PROXY || test -v http_proxy; then
    printf \
        'HTTP proxy environment detected, configuring LXD HTTP proxy settings...\n'
    for env_name in HTTP_PROXY http_proxy; do
        if test -v "${env_name}"; then
            http_proxy_detected="${!env_name}"
            break
        fi
    done

    if ! lxc_config_proxy_http="$(lxc config get core.proxy_http)"; then
        printf \
            'Unable to query the value of the core.proxy_http LXD server configuration.\n' \
            1>&2
        exit 1
    fi

    if test "${lxc_config_proxy_http}" != "${http_proxy_detected}"; then
        if ! lxc config set core.proxy_http="${http_proxy_detected}"; then
            printf \
                'Error: Unable to set the value of the core.proxy_http LXD server configuration.\n' \
                1>&2
            exit 1
        fi
    fi
fi

https_proxy_detected=
if test -v HTTPS_PROXY || test -v https_proxy; then
    printf 'HTTPS proxy environment detected, configuring LXD HTTPS proxy settings...\n'
    for env_name in HTTPS_PROXY https_proxy; do
        if test -v "${env_name}"; then
            https_proxy_detected="${!env_name}"
            break
        fi
    done

    if ! lxc_config_proxy_https="$(lxc config get core.proxy_https)"; then
        printf \
            'Error: Unable to query the value of the core.proxy_https LXD server configuration.\n' \
            1>&2
        exit 1
    fi

    if test "${lxc_config_proxy_https}" != "${https_proxy_detected}"; then
        if ! lxc config set core.proxy_https="${https_proxy_detected}"; then
            printf \
                'Error: Unable to set the value of the core.proxy_https LXD server configuration.\n' \
                1>&2
            exit 1
        fi
    fi
fi

# Create the container.
if ! lxc info snapcraft-dev >/dev/null 2>&1; then
    lxc init ubuntu:22.04 snapcraft-dev
fi
if ! lxc config get snapcraft-dev raw.idmap | grep -q "both $UID 1000"; then
    lxc config set snapcraft-dev raw.idmap "both $UID 1000"
fi

if ! lxc info snapcraft-dev | grep -q "Status: Running"; then
    lxc start snapcraft-dev
fi

# Wait for cloud-init before moving on.
lxc exec snapcraft-dev -- cloud-init status --wait

# First login for ubuntu user.
lxc exec snapcraft-dev -- sudo -iu ubuntu bash -c true

# Now that /home/ubuntu has been used, add the project.
if ! lxc config device show snapcraft-dev | grep -q snapcraft-project; then
    lxc config device add snapcraft-dev snapcraft-project disk \
        source="$SNAPCRAFT_DIR" path=/home/ubuntu/snapcraft
fi

# Set proxy on login.
if test -n "${http_proxy_detected}"; then
    lxc exec snapcraft-dev -- sudo -iu ubuntu bash -c \
        "echo 'export HTTP_PROXY=${http_proxy_detected}' >> .profile"
    lxc exec snapcraft-dev -- sudo -iu ubuntu bash -c \
        "echo 'export http_proxy=${http_proxy_detected}' >> .profile"
fi
if test -n "${https_proxy_detected}"; then
    lxc exec snapcraft-dev -- sudo -iu ubuntu bash -c \
        "echo 'export HTTPS_PROXY=${https_proxy_detected}' >> .profile"
    lxc exec snapcraft-dev -- sudo -iu ubuntu bash -c \
        "echo 'export https_proxy=${https_proxy_detected}' >> .profile"
fi

# Tell sudo to passthrough the proxy related environment variables
if ! temp_dir="$(mktemp -dt snapcraft.XXXXXX)"; then
    printf 'Error: Unable to create the temporary directory.\n' 1>&2
    exit 1
fi
trap 'rm -rf "${temp_dir}"' EXIT

# Configure snapd to use the HTTP(S) proxy
if test -n "${http_proxy_detected}"; then
    lxc exec snapcraft-dev -- \
        sudo snap set system proxy.http="${http_proxy_detected}"
fi

if test -n "${https_proxy_detected}"; then
    lxc exec snapcraft-dev -- \
        sudo snap set system proxy.https="${https_proxy_detected}"
fi

printf \
    'Defaults env_keep += "HTTP_PROXY http_proxy HTTPS_PROXY https_proxy"\n' \
    >"${temp_dir}/allow-http-proxy"
if ! \
    lxc file push \
        --uid 0 \
        --gid 0 \
        --mode 0640 \
        "${temp_dir}/allow-http-proxy" \
        snapcraft-dev/etc/sudoers.d/allow-http-proxy; then
    printf \
        'Error: Unable to install the sudo security policy drop-in file for allowing HTTP(S) proxy environment variables to pass-through.\n' \
        1>&2
fi

# Install snapcraft and dependencies.
lxc exec snapcraft-dev -- sudo -iu ubuntu /home/ubuntu/snapcraft/tools/environment-setup-local.sh

# Set virtual environment on login.
lxc exec snapcraft-dev -- sudo -iu ubuntu bash -c \
    "echo 'source /home/ubuntu/.venv/snapcraft/bin/activate' >> .profile"
lxc exec snapcraft-dev -- sudo -iu ubuntu bash -c \
    "echo 'source /home/ubuntu/.venv/snapcraft/bin/activate' >> .bashrc"

echo "Container ready, enter it by running: "
echo "lxc exec snapcraft-dev -- sudo -iu ubuntu bash"

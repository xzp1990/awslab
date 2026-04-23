#!/bin/bash

set -ex

LOG_FILE="/var/log/provision/provisioning.log"
mkdir -p "/var/log/provision"
touch "$LOG_FILE"

logger() {
  echo "$@" | tee -a "$LOG_FILE"
}

logger "[start] on_create.sh"

# Wait for /opt/sagemaker to be mounted (max 60s)
for i in {1..12}; do
  if mount | grep -q "/opt/sagemaker"; then
    logger "/opt/sagemaker is mounted"
    break
  else
    logger "Waiting for /opt/sagemaker to be mounted..."
    sleep 5
  fi
done

if mount | grep -q "/opt/sagemaker"; then
  logger "Found secondary EBS volume. Setting containerd data root to /opt/sagemaker/containerd/data-root"

  source /etc/os-release
  os_version="$VERSION_ID"
  logger "Detected OS version: $os_version"

  if [[ "$os_version" == "2" ]]; then
    CONFIG_FILE="/etc/eks/containerd/containerd-config.toml"
    if [[ -f "$CONFIG_FILE" ]]; then
      logger "Amazon Linux 2 detected. Modifying $CONFIG_FILE using sed"
      sed -i -e "/^[# ]*root\s*=/c\root = \"/opt/sagemaker/containerd/data-root\"" "$CONFIG_FILE"
    else
      logger "Amazon Linux 2 detected, but $CONFIG_FILE not found!"
    fi

  elif [[ "$os_version" == "2023" ]]; then
    logger "Amazon Linux 2023 detected. Creating custom containerd config and systemd override"

    if [[ -d "/opt/sagemaker/containerd/data-root" ]]; then
      logger "Removing existing containerd data-root to prevent AL2/AL23 incompatibility"
      rm -rf /opt/sagemaker/containerd/data-root
    fi

    mkdir -p /opt/sagemaker/containerd

    cat <<EOF | tee /opt/sagemaker/containerd/config.toml
version = 2
root = "/opt/sagemaker/containerd/data-root"
state = "/run/containerd"

[grpc]
address = "/run/containerd/containerd.sock"

[plugins."io.containerd.grpc.v1.cri".containerd]
default_runtime_name = "nvidia"
discard_unpacked_layers = true

[plugins."io.containerd.grpc.v1.cri"]
sandbox_image = "localhost/kubernetes/pause"
enable_cdi = true

[plugins."io.containerd.grpc.v1.cri".registry]
config_path = "/etc/containerd/certs.d:/etc/docker/certs.d"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
runtime_type = "io.containerd.runc.v2"
base_runtime_spec = "/etc/containerd/base-runtime-spec.json"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
BinaryName = "/usr/bin/nvidia-container-runtime"
SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".cni]
bin_dir = "/opt/cni/bin"
conf_dir = "/etc/cni/net.d"
EOF

    mkdir -p /etc/systemd/system/containerd.service.d

    cat <<EOF | tee /etc/systemd/system/containerd.service.d/override.conf
[Service]
Environment="CONTAINERD_CONFIG=/opt/sagemaker/containerd/config.toml"
ExecStart=
ExecStart=/usr/bin/containerd --config \$CONTAINERD_CONFIG
EOF

    systemctl daemon-reload

    cp -a /var/lib/containerd /opt/sagemaker/containerd/data-root

  else
    logger "Unsupported OS version: $os_version. Skipping containerd configuration."
  fi
else
  logger "/opt/sagemaker not mounted. Skipping containerd configuration"
fi

######################################################################
# Patch maxPods after nodeadm completes.
#
# IMPORTANT: HyperPod waits for ALL child processes of on_create.sh
# to exit before proceeding. We CANNOT use nohup/background processes.
# Instead, create a systemd path unit that triggers when the kubelet
# config file appears.
######################################################################
cat << 'PATCHSCRIPT' > /opt/sagemaker/patch-maxpods.sh
#!/bin/bash
LOG="/var/log/provision/patch-maxpods.log"
KUBELET_OVERRIDE="/etc/kubernetes/kubelet/config.json.d/40-nodeadm.conf"

if [[ ! -f "$KUBELET_OVERRIDE" ]]; then
  echo "[$(date)] ERROR: $KUBELET_OVERRIDE not found" >> "$LOG"
  exit 1
fi

CURRENT=$(python3 -c "import json; print(json.load(open('$KUBELET_OVERRIDE'))['maxPods'])")
echo "[$(date)] Current maxPods: $CURRENT" >> "$LOG"

if [[ "$CURRENT" -ne 58 ]]; then
  python3 -c "
import json
f = '$KUBELET_OVERRIDE'
c = json.load(open(f))
c['maxPods'] = 58
json.dump(c, open(f, 'w'), indent=4)
"
  echo "[$(date)] Updated maxPods to 58, restarting kubelet..." >> "$LOG"
  systemctl restart kubelet
  echo "[$(date)] kubelet restarted" >> "$LOG"
else
  echo "[$(date)] maxPods already 58, no change needed" >> "$LOG"
fi

# Disable the path watcher so it doesn't keep triggering
systemctl disable patch-maxpods.path 2>/dev/null
systemctl stop patch-maxpods.path 2>/dev/null
echo "[$(date)] patch-maxpods.path disabled" >> "$LOG"
PATCHSCRIPT
chmod +x /opt/sagemaker/patch-maxpods.sh

# systemd path unit: watches for the kubelet config file to appear
cat <<EOF > /etc/systemd/system/patch-maxpods.path
[Unit]
Description=Watch for kubelet config to patch maxPods

[Path]
PathExists=/etc/kubernetes/kubelet/config.json.d/40-nodeadm.conf
Unit=patch-maxpods.service

[Install]
WantedBy=multi-user.target
EOF

# systemd service unit: runs the patch script when triggered
cat <<EOF > /etc/systemd/system/patch-maxpods.service
[Unit]
Description=Patch kubelet maxPods after nodeadm
After=kubelet.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/opt/sagemaker/patch-maxpods.sh
EOF

systemctl daemon-reload
systemctl enable --now patch-maxpods.path
logger "Enabled systemd path watcher for maxPods patch"

logger "no more steps to run"
logger "[stop] on_create.sh"

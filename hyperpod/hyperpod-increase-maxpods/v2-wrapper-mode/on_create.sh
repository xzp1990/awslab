#!/bin/bash

set -ex

LOG_FILE="/var/log/provision/provisioning.log"
mkdir -p "/var/log/provision"
touch "$LOG_FILE"

logger() {
  echo "$@" | tee -a "$LOG_FILE"
}

logger "[start] on_create.sh"

if [ -f "./on_create_main.sh" ]; then
  if ! bash ./on_create_main.sh >> "$LOG_FILE" 2>&1; then
    logger "[error] on_create_main.sh failed, waiting 60 seconds before exit, to make sure logs are uploaded"
    sync
    sleep 60
    logger "[stop] on_create.sh with error"
    exit 1
  fi
else
  logger "[warning] on_create_main.sh not found, skipping execution"
fi

######################################################################
# Patch maxPods after nodeadm completes (for Prefix Delegation).
#
# IMPORTANT: HyperPod waits for ALL child processes of on_create.sh
# to exit before proceeding. We CANNOT use nohup/background processes.
# Instead, create a systemd path unit that triggers when the kubelet
# config file appears.
######################################################################
TARGET_MAX_PODS=58

logger "[maxpods] Setting up systemd path unit to patch maxPods to $TARGET_MAX_PODS"

cat << 'PATCHSCRIPT' > /opt/sagemaker/patch-maxpods.sh
#!/bin/bash
LOG="/var/log/provision/patch-maxpods.log"
KUBELET_OVERRIDE="/etc/kubernetes/kubelet/config.json.d/40-nodeadm.conf"
TARGET_MAX_PODS=58

if [[ ! -f "$KUBELET_OVERRIDE" ]]; then
  echo "[$(date)] ERROR: $KUBELET_OVERRIDE not found" >> "$LOG"
  exit 1
fi

CURRENT=$(python3 -c "import json; print(json.load(open('$KUBELET_OVERRIDE'))['maxPods'])")
echo "[$(date)] Current maxPods: $CURRENT" >> "$LOG"

if [[ "$CURRENT" -ne "$TARGET_MAX_PODS" ]]; then
  python3 -c "
import json
f = '$KUBELET_OVERRIDE'
c = json.load(open(f))
c['maxPods'] = $TARGET_MAX_PODS
json.dump(c, open(f, 'w'), indent=4)
"
  echo "[$(date)] Updated maxPods to $TARGET_MAX_PODS, restarting kubelet..." >> "$LOG"
  systemctl restart kubelet
  echo "[$(date)] kubelet restarted" >> "$LOG"
else
  echo "[$(date)] maxPods already $TARGET_MAX_PODS, no change needed" >> "$LOG"
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
logger "[maxpods] Enabled systemd path watcher for maxPods patch (target: $TARGET_MAX_PODS)"

logger "[stop] on_create.sh"

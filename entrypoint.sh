#!/usr/bin/env bash
set -euo pipefail

: "${SHARE_NAME:=nas-share}"
: "${SMB_USER:=xccvme}"
: "${SMB_PASSWORD:=password}"
: "${PUID:=1000}"
: "${PGID:=1000}"
: "${NFS_ALLOWED:=192.168.1.0/24}"
: "${NFS_OPTIONS:=rw,sync,no_subtree_check,no_root_squash}"

echo "[INFO] Starting NAS container..."
echo "[INFO] Share name: ${SHARE_NAME}"
echo "[INFO] NFS allowed: ${NFS_ALLOWED}"

mkdir -p /shared /run/samba /var/log/samba /var/lib/samba/private /run/rpc_pipefs

groupadd -g "${PGID}" nasgroup 2>/dev/null || true

if ! id -u "${SMB_USER}" >/dev/null 2>&1; then
  useradd -u "${PUID}" -g "${PGID}" -M -s /usr/sbin/nologin "${SMB_USER}"
fi

chown -R "${PUID}:${PGID}" /shared
chmod -R 2775 /shared

cat > /etc/samba/smb.conf <<EOC
[global]
   server role = standalone server
   workgroup = WORKGROUP
   security = user
   map to guest = never
   passdb backend = tdbsam
   server min protocol = SMB2
   server string = Docker NAS SMB Server
   log file = /var/log/samba/log.%m
   max log size = 1000

[${SHARE_NAME}]
   path = /shared
   browseable = yes
   read only = no
   writable = yes
   valid users = ${SMB_USER}
   force user = ${SMB_USER}
   force group = nasgroup
   create mask = 0664
   directory mask = 2775
EOC

echo -e "${SMB_PASSWORD}\n${SMB_PASSWORD}" | smbpasswd -a -s "${SMB_USER}" || true
smbpasswd -e "${SMB_USER}"

testparm -s

: > /etc/exports

for CLIENT in ${NFS_ALLOWED}; do
  echo "/shared ${CLIENT}(${NFS_OPTIONS},fsid=0)" >> /etc/exports
done

echo "[INFO] /etc/exports:"
cat /etc/exports

mkdir -p /run/sendsigs.omit.d /run/rpcbind
touch /run/rpcbind/rpcbind.xdr /run/rpcbind/portmap.xdr || true

rpcbind -w || true

mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd

exportfs -ra
exportfs -v

rpc.nfsd 8

rpc.mountd --foreground --no-nfs-version 2 --no-nfs-version 3 &
MOUNTD_PID=$!

nmbd --foreground --no-process-group &
NMBD_PID=$!

smbd --foreground --no-process-group &
SMBD_PID=$!

echo "[INFO] SMB and NFS are running."

trap 'echo "[INFO] Stopping..."; kill ${MOUNTD_PID} ${NMBD_PID} ${SMBD_PID} 2>/dev/null || true; exportfs -ua || true; rpc.nfsd 0 || true; exit 0' SIGTERM SIGINT

wait -n ${MOUNTD_PID} ${NMBD_PID} ${SMBD_PID}

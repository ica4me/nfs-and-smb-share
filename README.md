# NAS Docker Final: NFS + SMB di Ubuntu 22.04

Panduan final dan ringkas untuk menjalankan NFS + SMB dalam satu Docker Compose.

Status contoh dari server:
- Disk data: `/dev/sdb1`
- Mount host: `/srv/nas-share`
- Share name: `nas-share`
- SMB user: `usernameforlogin`
- SMB password: dari `.env`
- NFS allowed subnet: dari `.env`

---

## 1. Download & Masuk ke folder kerja
```
git clone https://github.com/ica4me/nfs-and-smb-share.git nfs-and-smb-share
```

```bash
cd ~/nas-docker
```

Pastikan file berikut ada:

```bash
ls -lah
```

Harus ada:

```text
.env
docker-compose.yml
entrypoint.sh
```

---

## 2. File `.env` final

Buat/edit:

```bash
nano .env
```

Isi:

```env
NAS_DISK=/dev/sdb
NAS_PARTITION=/dev/sdb1

HOST_SHARE=/srv/nas-share
SHARE_NAME=nas-share

SMB_USER=usernameforlogin
SMB_PASSWORD=PASSWORDSMB

PUID=1000
PGID=1000

NFS_ALLOWED="172.16.3.0/24 172.16.101.0/24 172.16.1.0/24 172.16.2.0/24 172.16.4.0/24 172.16.5.0/24"

NFS_OPTIONS=rw,sync,no_subtree_check,no_root_squash
```

Tes:

```bash
set -a
source .env
set +a

echo "$NFS_ALLOWED"
lsblk "$NAS_DISK"
```

---

## 3. Mount disk ke host

Jika `/dev/sdb1` sudah tampil mounted ke `/srv/nas-share`, lewati bagian format.

Cek:

```bash
lsblk
df -h /srv/nas-share
```

Jika belum pernah diformat, jalankan ini.

PERINGATAN: perintah ini menghapus isi `/dev/sdb`.

```bash
set -a
source .env
set +a

wipefs -a "$NAS_DISK"

parted -s "$NAS_DISK" mklabel gpt
parted -s "$NAS_DISK" mkpart primary ext4 0% 100%

partprobe "$NAS_DISK"
sleep 2

mkfs.ext4 -F "$NAS_PARTITION"

mkdir -p "$HOST_SHARE"

UUID=$(blkid -s UUID -o value "$NAS_PARTITION")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $HOST_SHARE ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

chown -R "${PUID}:${PGID}" "$HOST_SHARE"
chmod -R 2775 "$HOST_SHARE"

df -h "$HOST_SHARE"
lsblk
```

---

## 4. File `entrypoint.sh` final

Buat/edit:

```bash
nano entrypoint.sh
```

Isi:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${SHARE_NAME:=nas-share}"
: "${SMB_USER:=usernameforlogin}"
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
```

Set executable:

```bash
chmod +x entrypoint.sh
```

---

## 5. File `docker-compose.yml` final

Buat/edit:

```bash
nano docker-compose.yml
```

Isi:

```yaml
services:
  nas-share:
    container_name: nas-share
    hostname: nas-share

    build:
      context: .
      dockerfile_inline: |
        FROM ubuntu:22.04

        ENV DEBIAN_FRONTEND=noninteractive

        RUN apt-get update && \
            apt-get install -y --no-install-recommends \
              samba \
              nfs-kernel-server \
              nfs-common \
              rpcbind \
              procps \
              iproute2 \
              ca-certificates && \
            rm -rf /var/lib/apt/lists/*

        RUN mkdir -p /shared /run/samba /var/log/samba /var/lib/samba/private /run/rpc_pipefs

    env_file:
      - .env

    environment:
      TZ: Asia/Jakarta

    volumes:
      - ${HOST_SHARE}:/shared
      - ./entrypoint.sh:/entrypoint.sh:ro
      - /lib/modules:/lib/modules:ro

    network_mode: host
    privileged: true
    restart: unless-stopped

    entrypoint:
      - /entrypoint.sh
```

Validasi:

```bash
docker compose config
```

---

## 6. Jalankan container

```bash
docker compose down
docker compose up -d --build
docker ps -a
docker logs -f nas-share
```

Log berhasil:

```text
[INFO] /etc/exports:
[INFO] SMB and NFS are running.
```

---

## 7. Cek NFS export

```bash
docker exec -it nas-share exportfs -v
```

---

## 8. Buka firewall jika UFW aktif

```bash
ufw allow 445/tcp
ufw allow 139/tcp
ufw allow 2049/tcp
ufw allow 111/tcp
ufw allow 111/udp
ufw reload
```

---

## 9. Akses SMB

Dari Windows:

```text
\\IP_SERVER\nas-share
```

Login:

```text
Username: usernameforlogin
Password: PASSWORDSMB
```

Dari Linux:

```bash
sudo apt install -y cifs-utils
sudo mkdir -p /mnt/nas-smb
sudo mount -t cifs //IP_SERVER/nas-share /mnt/nas-smb -o username=usernameforlogin,password='PASSWORDSMB',vers=3.0,rw
```

---

## 10. Akses NFS dari Linux dan Windows SMB

```bash
sudo apt install -y nfs-common
sudo mkdir -p /mnt/nas-nfs
sudo mount -t nfs4 IP_SERVER:/ /mnt/nas-nfs
```

Contoh:

```bash
sudo mount -t nfs4 172.16.3.253:/ /mnt/nas-nfs
```

Di Windows + R (Network)
```bash
\\172.16.3.253\nas-share
```

---

## 11. Tes read/write

Di SMB atau NFS client:

```bash
touch /mnt/nas-nfs/test-write.txt
echo "ok" > /mnt/nas-nfs/test-write.txt
cat /mnt/nas-nfs/test-write.txt
```

Di server:

```bash
ls -lah /srv/nas-share
```

---

## 12. Troubleshooting cepat

Container restart terus:

```bash
docker logs nas-share
```

Validasi compose:

```bash
docker compose config
```

Pastikan mount ada:

```bash
df -h /srv/nas-share
lsblk
```

Reset container:

```bash
docker compose down
docker compose up -d --build --force-recreate
```

Cek isi file export di container:

```bash
docker exec -it nas-share cat /etc/exports
```

Cek Samba config:

```bash
docker exec -it nas-share testparm -s
```

---

## 13. Stop dan start

Stop:

```bash
docker compose down
```

Start:

```bash
docker compose up -d
```

---

## Catatan keamanan

- SMB memakai user/password dari `.env`.
- NFS hanya dibatasi IP/CIDR pada `NFS_ALLOWED`, tidak memakai password.
- `no_root_squash` memudahkan akses root dari client, tetapi kurang aman.
- Untuk lebih aman, ubah:

```env
NFS_OPTIONS=rw,sync,no_subtree_check,root_squash
```

lalu restart:

```bash
docker compose up -d --force-recreate
```

---

## Referensi

- Docker Compose interpolation: https://docs.docker.com/reference/compose-file/interpolation/
- Docker restart policy: https://docs.docker.com/engine/containers/start-containers-automatically/
- Ubuntu NFS: https://ubuntu.com/server/docs/how-to/networking/install-nfs/
- Samba smb.conf: https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html

## Advanve
Mount permanent di VM client NFS(Linux)
```
cat <<'EOF' > /root/setup-nas-nfs-automount.sh
#!/usr/bin/env bash
set -euo pipefail

NFS_SERVER="172.16.3.253"
NFS_REMOTE="/"
MOUNT_POINT="/mnt/nas-nfs"

apt update
apt install -y nfs-common

mkdir -p "${MOUNT_POINT}"

# Backup fstab
cp /etc/fstab "/etc/fstab.bak.$(date +%F-%H%M%S)"

# Hapus entry lama untuk mount point ini jika ada
sed -i "\|[[:space:]]${MOUNT_POINT}[[:space:]]|d" /etc/fstab

# Tambahkan entry NFS automount
cat <<EOL >> /etc/fstab
${NFS_SERVER}:${NFS_REMOTE} ${MOUNT_POINT} nfs4 rw,hard,timeo=600,retrans=2,nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=30s 0 0
EOL

systemctl daemon-reload

# Bersihkan mount manual lama jika masih aktif
umount "${MOUNT_POINT}" 2>/dev/null || true

# Nama unit automount dari path /mnt/nas-nfs
AUTO_UNIT="$(systemd-escape --path --suffix=automount "${MOUNT_POINT}")"

systemctl enable "${AUTO_UNIT}"
systemctl restart "${AUTO_UNIT}"

echo
echo "[OK] NFS automount aktif."
echo "Mount point : ${MOUNT_POINT}"
echo "NFS server  : ${NFS_SERVER}:${NFS_REMOTE}"
echo "Unit        : ${AUTO_UNIT}"
echo
echo "Tes:"
echo "  ls ${MOUNT_POINT}"
echo "  df -h ${MOUNT_POINT}"
echo "  systemctl status ${AUTO_UNIT}"
EOF

chmod +x /root/setup-nas-nfs-automount.sh
bash /root/setup-nas-nfs-automount.sh
```
Setelah itu tes:
```
ls /mnt/nas-nfs
df -h /mnt/nas-nfs
systemctl status "$(systemd-escape --path --suffix=automount /mnt/nas-nfs)"
```



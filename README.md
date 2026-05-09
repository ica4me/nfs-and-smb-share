# NAS Docker: NFS + SMB di Ubuntu 22.04

Tutorial ringkas menjalankan NFS dan SMB dalam satu Docker Compose.

## 1. Siapkan folder

```bash
sudo mkdir -p /opt/nas-docker
cd /opt/nas-docker
```

## 2. Buat file `.env`

```bash
sudo nano .env
```

Isi:

```env
NAS_DISK=/dev/sdb
NAS_PARTITION=/dev/sdb1
HOST_SHARE=/srv/nas-share

SHARE_NAME=nas-share

SMB_USER=xccvme
SMB_PASSWORD=password

PUID=1000
PGID=1000

NFS_ALLOWED=192.168.1.0/24
NFS_OPTIONS=rw,sync,no_subtree_check,no_root_squash
```

## 3. Buat file `docker-compose.yml`

```bash
sudo nano docker-compose.yml
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
              samba nfs-kernel-server nfs-common rpcbind \
              procps iproute2 ca-certificates && \
            rm -rf /var/lib/apt/lists/*
        RUN mkdir -p /shared /run/samba /var/log/samba /var/lib/samba/private /run/rpc_pipefs
        CMD ["/bin/bash", "-lc", "/entrypoint.sh"]

    env_file:
      - .env

    environment:
      TZ: Asia/Jakarta

    volumes:
      - ${HOST_SHARE}:/shared
      - /lib/modules:/lib/modules:ro

    network_mode: host
    privileged: true
    restart: unless-stopped

    command: |
      bash -euo pipefail -c '
        cat > /entrypoint.sh << "SCRIPT"
        #!/usr/bin/env bash
        set -euo pipefail

        : "${SHARE_NAME:=nas-share}"
        : "${SMB_USER:=xccvme}"
        : "${SMB_PASSWORD:=password}"
        : "${PUID:=1000}"
        : "${PGID:=1000}"
        : "${NFS_ALLOWED:=192.168.1.0/24}"
        : "${NFS_OPTIONS:=rw,sync,no_subtree_check,no_root_squash}"

        mkdir -p /shared
        groupadd -g "${PGID}" nasgroup 2>/dev/null || true

        if ! id -u "${SMB_USER}" >/dev/null 2>&1; then
          useradd -u "${PUID}" -g "${PGID}" -M -s /usr/sbin/nologin "${SMB_USER}"
        fi

        chown -R "${PUID}:${PGID}" /shared
        chmod -R 2775 /shared

        cat > /etc/samba/smb.conf << EOF_SMB
        [global]
           server role = standalone server
           workgroup = WORKGROUP
           security = user
           map to guest = never
           passdb backend = tdbsam
           server min protocol = SMB2

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
        EOF_SMB

        echo -e "${SMB_PASSWORD}\n${SMB_PASSWORD}" | smbpasswd -a -s "${SMB_USER}"
        smbpasswd -e "${SMB_USER}"

        : > /etc/exports
        for CLIENT in ${NFS_ALLOWED}; do
          echo "/shared ${CLIENT}(${NFS_OPTIONS},fsid=0)" >> /etc/exports
        done

        mkdir -p /run/rpcbind
        rpcbind -w || true
        mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd

        exportfs -ra
        rpc.nfsd 8
        rpc.mountd --foreground --no-nfs-version 2 --no-nfs-version 3 &
        MOUNTD_PID=$!

        nmbd --foreground --no-process-group &
        NMBD_PID=$!

        smbd --foreground --no-process-group &
        SMBD_PID=$!

        trap "kill ${MOUNTD_PID} ${NMBD_PID} ${SMBD_PID} 2>/dev/null || true; exportfs -ua || true; rpc.nfsd 0 || true; exit 0" SIGTERM SIGINT
        wait -n ${MOUNTD_PID} ${NMBD_PID} ${SMBD_PID}
        SCRIPT

        chmod +x /entrypoint.sh
        exec /entrypoint.sh
      '
```

## 4. Format dan mount disk

> HATI-HATI: langkah ini menghapus isi `/dev/sdb`.

```bash
cd /opt/nas-docker
set -a
source .env
set +a

lsblk "$NAS_DISK"
```

Jika target disk sudah benar:

```bash
sudo wipefs -a "$NAS_DISK"
sudo parted -s "$NAS_DISK" mklabel gpt
sudo parted -s "$NAS_DISK" mkpart primary ext4 0% 100%
sudo partprobe "$NAS_DISK"
sleep 2
sudo mkfs.ext4 -F "$NAS_PARTITION"

sudo mkdir -p "$HOST_SHARE"
UUID=$(sudo blkid -s UUID -o value "$NAS_PARTITION")
echo "UUID=$UUID $HOST_SHARE ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
sudo chown -R "${PUID}:${PGID}" "$HOST_SHARE"
sudo chmod -R 2775 "$HOST_SHARE"

df -h "$HOST_SHARE"
```

## 5. Jalankan Docker Compose

```bash
cd /opt/nas-docker
sudo docker compose up -d --build
sudo docker logs -f nas-share
```

## 6. Cek service

```bash
sudo docker ps
sudo docker exec -it nas-share exportfs -v
```

## 7. Buka firewall jika UFW aktif

```bash
sudo ufw allow 445/tcp
sudo ufw allow 139/tcp
sudo ufw allow 2049/tcp
sudo ufw allow 111/tcp
sudo ufw allow 111/udp
sudo ufw reload
```

## 8. Akses SMB

Dari Windows:

```text
\\IP_SERVER\nas-share
```

Login:

```text
Username: xccvme
Password: password
```

Dari Linux:

```bash
sudo apt install -y cifs-utils
sudo mkdir -p /mnt/nas-smb
sudo mount -t cifs //IP_SERVER/nas-share /mnt/nas-smb -o username=xccvme,password=password,vers=3.0,rw
```

## 9. Akses NFS dari Linux

```bash
sudo apt install -y nfs-common
sudo mkdir -p /mnt/nas-nfs
sudo mount -t nfs4 IP_SERVER:/ /mnt/nas-nfs
```

## 10. Ubah akses NFS

Edit `.env`:

```bash
sudo nano /opt/nas-docker/.env
```

Contoh:

```env
NFS_ALLOWED=192.168.1.0/24 10.10.10.0/24
```

Restart container:

```bash
cd /opt/nas-docker
sudo docker compose up -d --force-recreate
```

## 11. Stop dan start ulang

Stop:

```bash
cd /opt/nas-docker
sudo docker compose down
```

Start:

```bash
cd /opt/nas-docker
sudo docker compose up -d
```

## 12. Catatan cepat

- `restart: unless-stopped` membuat container otomatis hidup kembali kecuali dihentikan manual.
- SMB memakai user/password dari `.env`.
- NFS hanya boleh diakses dari IP/CIDR pada `NFS_ALLOWED`.
- Untuk keamanan lebih baik, ganti `no_root_squash` menjadi `root_squash`.

## Referensi

- Docker restart policy: https://docs.docker.com/engine/containers/start-containers-automatically/
- Samba smb.conf: https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html
- Ubuntu NFS: https://ubuntu.com/server/docs/how-to/networking/install-nfs

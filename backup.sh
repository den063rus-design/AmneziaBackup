#!/usr/bin/env bash
# Back up Amnezia protocol data through Docker's supported CLI interfaces.
set -Eeuo pipefail
umask 077

BASE_DIR=/opt/AmneziaBackup
BACKUPS_DIR=$BASE_DIR/backups
LOGS_DIR=$BASE_DIR/logs
PREFIX=amnezia-backup
STAMP=$(date +%F_%H-%M-%S)
LOG_FILE=$LOGS_DIR/backup-$STAMP.log
WORK_DIR=

usage() { echo "Usage: $0" >&2; }
log() { [[ -d $LOGS_DIR ]] && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" || true; }
die() { echo "ERROR: $*" >&2; log "ERROR: $*"; exit 1; }
cleanup() { if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi; }
trap cleanup EXIT
trap 'die "Backup stopped at line $LINENO"' ERR

for arg in "$@"; do
  case $arg in
    --prefix=*) PREFIX=${arg#--prefix=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ $PREFIX =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid archive prefix"
(( EUID == 0 )) || die "run as root"
command -v docker >/dev/null || die "docker is not installed or not in PATH"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

install -d -m 700 "$BASE_DIR" "$BACKUPS_DIR" "$LOGS_DIR"
chmod 700 "$BASE_DIR" "$BACKUPS_DIR" "$LOGS_DIR"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
WORK_DIR=$(mktemp -d /tmp/amnezia-backup.XXXXXX)
DATA_DIR=$WORK_DIR/data
mkdir -p "$DATA_DIR/metadata"

container_id() { docker ps -aq --filter "name=^/$1$" | head -n1; }
OPENVPN=$(container_id amnezia-openvpn || true)
AWG2=$(container_id amnezia-awg2 || true)
AWG1=$(container_id amnezia-awg || true)
AWG=${AWG2:-$AWG1}
[[ -n $OPENVPN || -n $AWG ]] || die "no Amnezia OpenVPN/AWG containers found"

save_command() { local file=$1; shift; "$@" >"$DATA_DIR/metadata/$file" 2>>"$LOG_FILE" || log "WARNING: command failed: $*"; }
save_command docker-ps-a.txt docker ps -a --no-trunc
save_command docker-images.txt docker images --no-trunc
save_command docker-version.txt docker version
save_command docker-info.txt docker info
save_command docker-network-ls.txt docker network ls
save_command docker-volume-ls.txt docker volume ls
iptables-save >"$DATA_DIR/metadata/iptables-save.txt" 2>>"$LOG_FILE" || log "WARNING: iptables-save unavailable"
nft list ruleset >"$DATA_DIR/metadata/nft-ruleset.txt" 2>>"$LOG_FILE" || log "WARNING: nft unavailable"
ip addr >"$DATA_DIR/metadata/ip-addr.txt" 2>>"$LOG_FILE" || log "WARNING: ip unavailable"
ip route >"$DATA_DIR/metadata/ip-route.txt" 2>>"$LOG_FILE" || log "WARNING: ip route unavailable"
cp -- /etc/os-release "$DATA_DIR/metadata/os-release"
uname -a >"$DATA_DIR/metadata/uname-a.txt"
if docker network inspect amnezia-dns-net >"$DATA_DIR/metadata/network-amnezia-dns-net.json" 2>>"$LOG_FILE"; then :; else rm -f -- "$DATA_DIR/metadata/network-amnezia-dns-net.json"; fi

save_container_metadata() {
  local name=$1 id=$2
  docker inspect "$id" >"$DATA_DIR/metadata/$name.inspect.json"
  docker port "$id" >"$DATA_DIR/metadata/$name.ports.txt" 2>>"$LOG_FILE" || true
  docker image inspect "$(docker inspect -f '{{.Config.Image}}' "$id")" >"$DATA_DIR/metadata/$name.image.json" 2>>"$LOG_FILE" || true
}
[[ -n $OPENVPN ]] && save_container_metadata openvpn "$OPENVPN"
[[ -n $AWG ]] && save_container_metadata awg "$AWG"

copy_protocol() {
  local id=$1 source=$2 target=$3
  mkdir -p "$DATA_DIR/$target"
  # docker cp keeps the complete directory content, including future Amnezia files.
  docker cp "$id:$source/." "$DATA_DIR/$target/"
}
[[ -n $OPENVPN ]] && copy_protocol "$OPENVPN" /opt/amnezia/openvpn openvpn
[[ -n $AWG ]] && copy_protocol "$AWG" /opt/amnezia/awg awg
if [[ -d /opt/amnezia ]]; then cp -a -- /opt/amnezia "$DATA_DIR/host-opt-amnezia"; fi

check_warning=0
if [[ -n $OPENVPN ]]; then
  for item in clientsTable server.conf pki; do [[ -e $DATA_DIR/openvpn/$item ]] || { echo "WARNING: OpenVPN critical item missing: $item" >&2; log "WARNING: OpenVPN critical item missing: $item"; check_warning=1; }; done
fi
if [[ -n $AWG ]]; then
  [[ -e $DATA_DIR/awg/clientsTable ]] || { echo "WARNING: AWG critical item missing: clientsTable" >&2; log "WARNING: AWG critical item missing: clientsTable"; check_warning=1; }
  [[ -e $DATA_DIR/awg/awg0.conf || -e $DATA_DIR/awg/wg0.conf ]] || { echo "WARNING: AWG critical item missing: awg0.conf/wg0.conf" >&2; log "WARNING: AWG configuration missing"; check_warning=1; }
fi

OPEN_IMAGE= AWG_IMAGE= OPEN_PORTS= AWG_PORTS=
[[ -n $OPENVPN ]] && { OPEN_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$OPENVPN"); OPEN_PORTS=$(docker port "$OPENVPN" 2>/dev/null | tr '\n' ';'); }
[[ -n $AWG ]] && { AWG_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$AWG"); AWG_PORTS=$(docker port "$AWG" 2>/dev/null | tr '\n' ';'); }
{
  echo "Created: $(date --iso-8601=seconds)"
  echo "Hostname: $(hostname)"
  echo "Debian: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
  echo "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  echo "OpenVPN container: ${OPENVPN:-not found}"
  echo "OpenVPN image: ${OPEN_IMAGE:-n/a}"
  echo "OpenVPN ports: ${OPEN_PORTS:-n/a}"
  echo "AWG container: ${AWG:-not found}"
  echo "AWG name: $([[ -n $AWG2 ]] && echo amnezia-awg2 || echo amnezia-awg)"
  echo "AWG image: ${AWG_IMAGE:-n/a}"
  echo "AWG ports: ${AWG_PORTS:-n/a}"
  echo "Mode: protocol-data-and-metadata"
} >"$DATA_DIR/MANIFEST.txt"
(cd "$DATA_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$DATA_DIR/SHA256SUMS"

ARCHIVE=$BACKUPS_DIR/$PREFIX-$STAMP.tar.gz
# Archiving `.` also handles intentionally absent optional protocol directories.
tar -C "$DATA_DIR" -czf "$ARCHIVE" . 2>>"$LOG_FILE"
chmod 600 "$ARCHIVE"
(cd "$BACKUPS_DIR" && sha256sum "$(basename -- "$ARCHIVE")" >"$(basename -- "$ARCHIVE").sha256")
chmod 600 "$ARCHIVE.sha256"
log "Archive created: $ARCHIVE (warnings=$check_warning)"
printf '\nBACKUP SUCCESSFUL\n\nArchive:\n%s\n\nSHA256:\n%s\n' "$ARCHIVE" "$ARCHIVE.sha256"

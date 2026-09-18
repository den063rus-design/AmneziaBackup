#!/usr/bin/env bash
# Restore Amnezia protocol data into a fresh, compatible Amnezia installation.
set -Eeuo pipefail
umask 077

BASE_DIR=/opt/AmneziaBackup; BACKUPS_DIR=$BASE_DIR/backups; LOGS_DIR=$BASE_DIR/logs
STAMP=$(date +%F_%H-%M-%S); LOG_FILE=$LOGS_DIR/restore-$STAMP.log; WORK_DIR=
STOPPED=(); ROLLBACK_DIRS=(); COMMITTED=0
log() { [[ -d $LOGS_DIR ]] && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" || true; }
die() { echo "ERROR: $*" >&2; log "ERROR: $*"; exit 1; }
cleanup() {
  local i
  if (( ! COMMITTED )); then
    for i in "${!ROLLBACK_DIRS[@]}"; do
      IFS='|' read -r c path old <<<"${ROLLBACK_DIRS[$i]}"
      docker exec "$c" sh -c "rm -rf '$path'; [ ! -e '$old' ] || mv '$old' '$path'" >>"$LOG_FILE" 2>&1 || true
    done
  fi
  for i in "${STOPPED[@]}"; do docker start "$i" >>"$LOG_FILE" 2>&1 || true; done
  if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
}
trap cleanup EXIT
trap 'die "Restore stopped at line $LINENO; any stopped containers will be restarted"' ERR
(( EUID == 0 )) || die "run as root"
command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
install -d -m 700 "$BASE_DIR" "$BACKUPS_DIR" "$LOGS_DIR"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"

ARCHIVE=
if [[ $# == 0 ]]; then ARCHIVE=$(find "$BACKUPS_DIR" -maxdepth 1 -type f -name 'amnezia-backup-*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
elif [[ $# == 1 ]]; then ARCHIVE=$1
else die "Usage: $0 [ARCHIVE]"; fi
[[ -n $ARCHIVE && -f $ARCHIVE ]] || die "backup archive not found"
if [[ -f $ARCHIVE.sha256 ]]; then (cd -- "$(dirname -- "$ARCHIVE")" && sha256sum -c -- "$(basename -- "$ARCHIVE").sha256") >/dev/null || die "archive SHA256 verification failed"; fi
tar -tzf "$ARCHIVE" >/dev/null || die "archive cannot be read"
tar -tzf "$ARCHIVE" | grep -Eq '^\./?MANIFEST\.txt$' || die "archive has no MANIFEST.txt"
WORK_DIR=$(mktemp -d /tmp/amnezia-restore.XXXXXX); tar -xzf "$ARCHIVE" -C "$WORK_DIR"
[[ -f $WORK_DIR/SHA256SUMS ]] && (cd "$WORK_DIR" && sha256sum -c SHA256SUMS >/dev/null) || die "internal SHA256SUMS check failed"
[[ -d $WORK_DIR/metadata ]] || die "archive structure is incomplete (metadata missing)"

container_id() { docker ps -aq --filter "name=^/$1$" | head -n1; }
OLD_AWG_NAME=$(sed -n 's/^AWG name: //p' "$WORK_DIR/MANIFEST.txt" | head -n1)
OLD_OPEN_PORTS=$(sed -n 's/^OpenVPN ports: //p' "$WORK_DIR/MANIFEST.txt" | head -n1)
OLD_AWG_PORTS=$(sed -n 's/^AWG ports: //p' "$WORK_DIR/MANIFEST.txt" | head -n1)
OPENVPN=$(container_id amnezia-openvpn || true); AWG2=$(container_id amnezia-awg2 || true); AWG1=$(container_id amnezia-awg || true); AWG=${AWG2:-$AWG1}
[[ -d $WORK_DIR/openvpn && -n $OPENVPN || ! -d $WORK_DIR/openvpn ]] || die "backup contains OpenVPN but current amnezia-openvpn is absent"
[[ -d $WORK_DIR/awg && -n $AWG || ! -d $WORK_DIR/awg ]] || die "backup contains AWG but no current AWG container exists"
if [[ -d $WORK_DIR/awg && -n $OLD_AWG_NAME && $OLD_AWG_NAME != "$( [[ -n $AWG2 ]] && echo amnezia-awg2 || echo amnezia-awg )" ]]; then
  die "AWG container generation mismatch ($OLD_AWG_NAME backup vs current); use a compatible legacy container or --container-images"
fi
port_check() { local old=$1 id=$2 label=$3 new; [[ -z $old || $old == n/a ]] && return; new=$(docker port "$id" 2>/dev/null | tr '\n' ';'); [[ $old == "$new" ]] || { echo "ERROR: PORT MISMATCH" >&2; echo "Old $label: $old" >&2; echo "Current $label: $new" >&2; die "port mapping differs; no changes made"; }; }
[[ -n $OPENVPN ]] && port_check "$OLD_OPEN_PORTS" "$OPENVPN" OpenVPN
[[ -n $AWG ]] && port_check "$OLD_AWG_PORTS" "$AWG" AWG

# A complete current-state rollback archive is mandatory before changes.
"$BASE_DIR/backup.sh" --prefix=pre-restore >>"$LOG_FILE" 2>&1 || die "pre-restore backup failed; no changes made"
restore_protocol() {
  local c=$1 source=$2 target=$3 old="${target}.pre-restore-${STAMP}"
  if [[ $(docker inspect -f '{{.State.Running}}' "$c") == true ]]; then docker stop "$c" >>"$LOG_FILE" 2>&1; STOPPED+=("$c"); fi
  docker exec "$c" sh -c "[ -e '$target' ] && mv '$target' '$old'; mkdir -p '$target'"
  ROLLBACK_DIRS+=("$c|$target|$old")
  docker cp "$source/." "$c:$target/"
  docker start "$c" >>"$LOG_FILE" 2>&1
  STOPPED=()
}
[[ -d $WORK_DIR/openvpn ]] && restore_protocol "$OPENVPN" "$WORK_DIR/openvpn" /opt/amnezia/openvpn
[[ -d $WORK_DIR/awg ]] && restore_protocol "$AWG" "$WORK_DIR/awg" /opt/amnezia/awg
sleep 2
check_running() { docker inspect -f '{{.State.Running}}' "$1" | grep -qx true || die "$2 container did not start"; }
if [[ -d $WORK_DIR/openvpn ]]; then
  check_running "$OPENVPN" OpenVPN
  [[ -d $WORK_DIR/openvpn/pki && -e $WORK_DIR/openvpn/clientsTable ]] || die "OpenVPN restored data is incomplete"
  docker logs --tail 20 "$OPENVPN" >/dev/null 2>&1 || die "cannot read OpenVPN container logs"
  docker top "$OPENVPN" -eo comm,args | grep -qi '[o]penvpn' || die "OpenVPN process was not found"
fi
if [[ -d $WORK_DIR/awg ]]; then
  check_running "$AWG" AWG
  [[ -e $WORK_DIR/awg/clientsTable ]] || die "AWG restored data is incomplete"
  docker logs --tail 20 "$AWG" >/dev/null 2>&1 || die "cannot read AWG container logs"
  # Do not display peer information: this is only an interface-readability test.
  docker exec "$AWG" sh -c 'awg show >/dev/null 2>&1 || wg show >/dev/null 2>&1' || die "AWG/WireGuard interface is unavailable"
  if [[ -f $WORK_DIR/awg/wireguard_server_public_key.key ]]; then
    old_hash=$(sha256sum "$WORK_DIR/awg/wireguard_server_public_key.key" | awk '{print $1}')
    new_hash=$(docker exec "$AWG" sha256sum /opt/amnezia/awg/wireguard_server_public_key.key 2>/dev/null | awk '{print $1}')
    [[ -n $new_hash && $old_hash == "$new_hash" ]] || die "restored AWG server public key does not match backup"
  fi
fi
# The original data are now covered by the mandatory pre-restore archive; remove
# the in-container temporary copies only after all checks above have passed.
for entry in "${ROLLBACK_DIRS[@]}"; do
  IFS='|' read -r c _ old <<<"$entry"
  docker exec "$c" sh -c "rm -rf '$old'" >>"$LOG_FILE" 2>&1
done
COMMITTED=1
count_clients() { [[ -f $1/clientsTable ]] && grep -c '"' "$1/clientsTable" 2>/dev/null || echo 0; }
echo "RESTORE SUCCESSFUL"
[[ -d $WORK_DIR/openvpn ]] && printf '\nOpenVPN:\ncontainer: OK\nPKI: OK\nclients: %s\nport: %s\n' "$(count_clients "$WORK_DIR/openvpn")" "$OLD_OPEN_PORTS"
[[ -d $WORK_DIR/awg ]] && printf '\nAmneziaWG:\ncontainer: OK\nclients: %s\nport: %s\n' "$(count_clients "$WORK_DIR/awg")" "$OLD_AWG_PORTS"

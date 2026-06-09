#!/usr/bin/env bash
set -euo pipefail

# Interactive installer for Oracle/VPS monthly traffic guard.
# No secrets are embedded in this file. Telegram token/chat id are prompted
# interactively and stored only on the target host in a 0600 env file.

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  echo "Please run as root, or install sudo." >&2
  exit 1
fi

CONF_FILE="/root/oracle-traffic-guard.env"
GUARD_SCRIPT="/root/oracle-traffic-guard.sh"
RESTORE_SCRIPT="/root/oracle-traffic-restore.sh"
CRON_FILE="/etc/cron.d/oracle-traffic-guard"
STATE_DIR_DEFAULT="/var/lib/oracle-traffic-guard"
LOG_FILE_DEFAULT="/var/log/oracle-traffic-guard.log"

prompt() {
  local var="$1" text="$2" default="${3:-}"
  local ans
  if [ -n "$default" ]; then
    read -r -p "$text [$default]: " ans || true
    ans=${ans:-$default}
  else
    read -r -p "$text: " ans || true
  fi
  printf -v "$var" '%s' "$ans"
}

prompt_secret() {
  local var="$1" text="$2" ans
  read -r -s -p "$text: " ans || true
  echo
  printf -v "$var" '%s' "$ans"
}

yesno() {
  local text="$1" default="${2:-y}" ans
  local prompt_suffix="[Y/n]"
  [ "$default" = "n" ] && prompt_suffix="[y/N]"
  read -r -p "$text $prompt_suffix: " ans || true
  ans=${ans:-$default}
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

sq() {
  # shell single-quote escape
  printf "%s" "$1" | sed "s/'/'\\''/g; 1s/^/'/; \$s/\$/'/"
}

calc_tib_bytes() {
  python3 - "$1" <<'PY'
import sys, decimal
x = decimal.Decimal(sys.argv[1])
print(int(x * (decimal.Decimal(1024) ** 4)))
PY
}

auto_iface() {
  ip route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

echo "== Oracle/VPS Traffic Guard interactive installer =="
echo "This installs vnStat monthly TX monitoring + high-priority nftables SSH-only fuse."
echo "Fuse rule priority: nft inet hook priority -500, intended to run above Podman/rfw/iptables-nft rules."
echo

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for config calculation and vnStat JSON parsing." >&2
  exit 1
fi

DEFAULT_IFACE=$(auto_iface || true)
DEFAULT_IFACE=${DEFAULT_IFACE:-eth0}
DEFAULT_LABEL=$(hostname 2>/dev/null || echo oracle-vps)

prompt HOST_LABEL "Host label shown in alerts" "$DEFAULT_LABEL"
prompt IFACE "Network interface to monitor" "$DEFAULT_IFACE"
prompt SSH_PORT "SSH port to keep open in fuse mode" "22"
prompt CAP_TIB "Nominal monthly traffic cap in TiB (informational)" "10"
prompt WARN1_TIB "Warning threshold #1, TX TiB" "8"
prompt WARN2_TIB "Warning threshold #2, TX TiB" "9"
prompt WARN3_TIB "Warning threshold #3, TX TiB" "9.5"
prompt FUSE_TIB "SSH-only fuse threshold, TX TiB" "9.7"
prompt INTERVAL_MIN "Cron check interval in minutes" "5"

STATE_DIR="$STATE_DIR_DEFAULT"
LOG_FILE="$LOG_FILE_DEFAULT"

TG_BOT_TOKEN=""
TG_CHAT_ID=""
if yesno "Configure Telegram alert now?" "y"; then
  prompt_secret TG_BOT_TOKEN "Telegram bot token (hidden)"
  prompt TG_CHAT_ID "Telegram chat id" ""
else
  echo "Telegram skipped. You can edit $CONF_FILE later."
fi

INSTALL_DEPS=0
if yesno "Install/enable dependencies with apt-get (vnstat curl nftables jq)?" "y"; then
  INSTALL_DEPS=1
fi

MONTHLY_RESTORE=0
if yesno "Add automatic monthly restore on day 1 00:10?" "y"; then
  MONTHLY_RESTORE=1
fi

SEND_TEST=0
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && yesno "Send Telegram test message after install?" "y"; then
  SEND_TEST=1
fi

WARN1_BYTES=$(calc_tib_bytes "$WARN1_TIB")
WARN2_BYTES=$(calc_tib_bytes "$WARN2_TIB")
WARN3_BYTES=$(calc_tib_bytes "$WARN3_TIB")
FUSE_BYTES=$(calc_tib_bytes "$FUSE_TIB")
CAP_BYTES=$(calc_tib_bytes "$CAP_TIB")

if [ "$INSTALL_DEPS" = "1" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    echo "Installing dependencies..."
    apt-get update -qq
    apt-get install -y vnstat curl nftables jq python3
  else
    echo "apt-get not found; skipping dependency install." >&2
  fi
fi

install -d -m 700 "$STATE_DIR"

cat > "$CONF_FILE" <<EOF
# Oracle/VPS Traffic Guard config. Keep chmod 600.
HOST_LABEL=$(sq "$HOST_LABEL")
IFACE=$(sq "$IFACE")
SSH_PORT=$(sq "$SSH_PORT")
CAP_BYTES=$CAP_BYTES
WARN1_BYTES=$WARN1_BYTES
WARN2_BYTES=$WARN2_BYTES
WARN3_BYTES=$WARN3_BYTES
FUSE_BYTES=$FUSE_BYTES
STATE_DIR=$(sq "$STATE_DIR")
LOG_FILE=$(sq "$LOG_FILE")
TG_BOT_TOKEN=$(sq "$TG_BOT_TOKEN")
TG_CHAT_ID=$(sq "$TG_CHAT_ID")
EOF
chmod 600 "$CONF_FILE"

cat > "$GUARD_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF_FILE=${CONF_FILE:-/root/oracle-traffic-guard.env}
[ -f "$CONF_FILE" ] || { echo "missing config: $CONF_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONF_FILE"

HOST_LABEL=${HOST_LABEL:-$(hostname)}
IFACE=${IFACE:-eth0}
SSH_PORT=${SSH_PORT:-22}
STATE_DIR=${STATE_DIR:-/var/lib/oracle-traffic-guard}
LOG_FILE=${LOG_FILE:-/var/log/oracle-traffic-guard.log}
WARN1_BYTES=${WARN1_BYTES:-8796093022208}
WARN2_BYTES=${WARN2_BYTES:-9895604649984}
WARN3_BYTES=${WARN3_BYTES:-10445360463872}
FUSE_BYTES=${FUSE_BYTES:-10665262789427}
LOCK_FILE="$STATE_DIR/ssh-only.lock"
STATE_FILE="$STATE_DIR/monthly.state"
mkdir -p "$STATE_DIR"

ts() { date -Is; }
log() { echo "$(ts) $*" >> "$LOG_FILE"; }

human_bytes() {
  python3 - "$1" <<'PY'
import sys
n=float(int(sys.argv[1]))
for unit in ['B','KiB','MiB','GiB','TiB','PiB']:
    if n < 1024 or unit == 'PiB':
        print(f'{n:.2f} {unit}')
        break
    n /= 1024
PY
}

notify() {
  local text="$1"
  log "$text"
  if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] && command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 15 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${text}" >/dev/null || true
  fi
}

apply_ssh_only_fuse() {
  command -v nft >/dev/null 2>&1 || { notify "ERROR: ${HOST_LABEL} cannot apply SSH-only fuse: nft command not found"; exit 1; }
  nft delete table inet hermes_guard 2>/dev/null || true
  nft -f - <<NFT
add table inet hermes_guard
add chain inet hermes_guard input { type filter hook input priority -500; policy drop; }
add chain inet hermes_guard forward { type filter hook forward priority -500; policy drop; }
add chain inet hermes_guard output { type filter hook output priority -500; policy drop; }
add rule inet hermes_guard input iif lo accept
add rule inet hermes_guard output oif lo accept
add rule inet hermes_guard input tcp dport ${SSH_PORT} accept
add rule inet hermes_guard output tcp sport ${SSH_PORT} accept
NFT
  echo "$(ts)" > "$LOCK_FILE"
  log "SSH-only fuse active via nft table inet hermes_guard priority -500"
}

if ! command -v vnstat >/dev/null 2>&1; then
  log "vnstat command not found; cannot measure traffic"
  exit 0
fi

JSON=$(vnstat --json m 1 -i "$IFACE" 2>/dev/null || true)
if [ -z "$JSON" ]; then
  log "vnstat_json_empty iface=$IFACE"
  exit 0
fi

read -r MONTH RX TX TOTAL <<<"$(printf '%s' "$JSON" | python3 -c '
import sys,json,datetime
try:
    j=json.load(sys.stdin)
    iface=(j.get("interfaces") or [{}])[0]
    months=((iface.get("traffic") or {}).get("month") or [])
    if not months:
        raise ValueError("no monthly samples")
    m=months[-1]
    date=m.get("date") or {}
    year=int(date.get("year") or datetime.datetime.utcnow().year)
    month=int(date.get("month") or datetime.datetime.utcnow().month)
    ym=f"{year:04d}-{month:02d}"
    rx=int(m.get("rx") or 0)
    tx=int(m.get("tx") or 0)
    print(ym, rx, tx, rx+tx)
except Exception:
    now=datetime.datetime.utcnow().strftime("%Y-%m")
    print(now, 0, 0, 0)
')"
RX=${RX:-0}; TX=${TX:-0}; TOTAL=${TOTAL:-0}; MONTH=${MONTH:-$(date -u +%Y-%m)}

LEVEL=0
LEVEL_NAME=""
if [ "$TX" -ge "$FUSE_BYTES" ]; then LEVEL=100; LEVEL_NAME="FUSE"
elif [ "$TX" -ge "$WARN3_BYTES" ]; then LEVEL=95; LEVEL_NAME="WARN95"
elif [ "$TX" -ge "$WARN2_BYTES" ]; then LEVEL=90; LEVEL_NAME="WARN90"
elif [ "$TX" -ge "$WARN1_BYTES" ]; then LEVEL=80; LEVEL_NAME="WARN80"
fi

log "host=$HOST_LABEL iface=$IFACE month=$MONTH rx=$RX tx=$TX total=$TOTAL level=$LEVEL"
[ "$LEVEL" -eq 0 ] && exit 0

STATE_KEY="$MONTH:$LEVEL_NAME"
LAST=""
[ -f "$STATE_FILE" ] && LAST=$(cat "$STATE_FILE" || true)
[ "$LAST" = "$STATE_KEY" ] && [ "$LEVEL_NAME" != "FUSE" ] && exit 0

TX_HUMAN=$(human_bytes "$TX")
if [ "$LEVEL_NAME" = "FUSE" ]; then
  if [ -f "$LOCK_FILE" ]; then
    exit 0
  fi
  notify "🚨 ${HOST_LABEL} 流量总闸触发：${MONTH} 出站 TX=${TX_HUMAN}，达到 SSH-only 阈值。即将启用 nft 顶层熔断，只保留 SSH:${SSH_PORT}。"
  echo "$STATE_KEY" > "$STATE_FILE"
  apply_ssh_only_fuse
else
  notify "⚠️ ${HOST_LABEL} 月流量预警：${MONTH} 出站 TX=${TX_HUMAN}，达到 ${LEVEL}% 阈值；达到熔断阈值后将自动进入 SSH-only。"
  echo "$STATE_KEY" > "$STATE_FILE"
fi
EOF
chmod 700 "$GUARD_SCRIPT"

cat > "$RESTORE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF_FILE=${CONF_FILE:-/root/oracle-traffic-guard.env}
[ -f "$CONF_FILE" ] && source "$CONF_FILE" || true
STATE_DIR=${STATE_DIR:-/var/lib/oracle-traffic-guard}
LOG_FILE=${LOG_FILE:-/var/log/oracle-traffic-guard.log}
nft delete table inet hermes_guard 2>/dev/null || true
rm -f "$STATE_DIR/ssh-only.lock" "$STATE_DIR/monthly.state"
echo "$(date -Is) SSH-only fuse restored; monthly state cleared" >> "$LOG_FILE"
EOF
chmod 700 "$RESTORE_SCRIPT"

if command -v vnstat >/dev/null 2>&1; then
  vnstat -i "$IFACE" --add >/dev/null 2>&1 || true
  systemctl enable --now vnstat >/dev/null 2>&1 || true
fi

cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/${INTERVAL_MIN} * * * * root $GUARD_SCRIPT >/dev/null 2>&1
EOF
if [ "$MONTHLY_RESTORE" = "1" ]; then
  cat >> "$CRON_FILE" <<EOF
10 0 1 * * root $RESTORE_SCRIPT >/dev/null 2>&1
EOF
fi
chmod 644 "$CRON_FILE"

bash -n "$GUARD_SCRIPT"
bash -n "$RESTORE_SCRIPT"

"$GUARD_SCRIPT" || true

if [ "$SEND_TEST" = "1" ]; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 15 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=✅ ${HOST_LABEL} traffic guard installed. Interface=${IFACE}, SSH-only fuse=${FUSE_TIB}TiB, SSH port=${SSH_PORT}." >/dev/null \
      && echo "Telegram test sent." || echo "Telegram test failed." >&2
  fi
fi

echo
echo "Installed:"
echo "  config:  $CONF_FILE (chmod 600)"
echo "  guard:   $GUARD_SCRIPT"
echo "  restore: $RESTORE_SCRIPT"
echo "  cron:    $CRON_FILE"
echo
echo "Current guard table status:"
nft list table inet hermes_guard 2>/dev/null || echo "  hermes_guard not active below threshold"
echo
echo "To manually restore network if fuse is active:"
echo "  $RESTORE_SCRIPT"

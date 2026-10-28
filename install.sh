#!/usr/bin/env bash
# Install with: sudo bash install.sh reboot
# Or: sudo bash install.sh agent [nezha-agent.service]
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf '%s\n' 'Usage: sudo bash install.sh {reboot|agent} [agent-unit]'
    exit 0
fi

action=${1:-agent}
agent_unit=${2:-nezha-agent.service}
[[ $action == agent || $action == reboot ]] || { echo 'Mode must be agent or reboot.' >&2; exit 1; }
[[ $agent_unit =~ ^[a-zA-Z0-9_.@:-]+\.service$ ]] || { echo 'Invalid systemd agent unit.' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'Run this installer with sudo.' >&2; exit 1; }
for dependency in curl flock awk systemctl install mktemp date mv chmod; do
    command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 1; }
done
if [[ $action == agent ]]; then
    load_state=$(systemctl show "$agent_unit" -p LoadState --value)
    [[ $load_state == loaded ]] || { echo "Agent unit not found: $agent_unit" >&2; exit 1; }
fi

install -d -m 0755 /usr/local/sbin /etc/default
install -d -m 0700 /var/lib/nezha-ip-watch
watch_tmp=$(mktemp /usr/local/sbin/.nezha-ip-watch.XXXXXX)
config_tmp=$(mktemp /etc/default/.nezha-ip-watch.XXXXXX)
trap 'rm -f -- "$watch_tmp" "$config_tmp"' EXIT

cat > "$watch_tmp" <<'WATCHER'
#!/usr/bin/env bash
set -euo pipefail
umask 077

CONFIG_FILE=/etc/default/nezha-ip-watch
STATE_DIR=/var/lib/nezha-ip-watch
ACTION=agent
AGENT_UNIT=nezha-agent.service
COOLDOWN_SECONDS=0
CONFIRMATIONS=1
[[ ! -f $CONFIG_FILE ]] || source "$CONFIG_FILE"

mode=${1:-run}
[[ $mode == run || $mode == status ]] || { echo 'Usage: nezha-ip-watch [run|status]' >&2; exit 1; }
[[ $ACTION == agent || $ACTION == reboot ]] || { echo 'Invalid ACTION.' >&2; exit 1; }
[[ $AGENT_UNIT =~ ^[a-zA-Z0-9_.@:-]+\.service$ ]] || { echo 'Invalid AGENT_UNIT.' >&2; exit 1; }
[[ $COOLDOWN_SECONDS =~ ^[0-9]+$ && ${#COOLDOWN_SECONDS} -le 6 ]] || { echo 'Invalid cooldown.' >&2; exit 1; }
[[ $CONFIRMATIONS =~ ^[1-9][0-9]?$ ]] || { echo 'Invalid confirmation count.' >&2; exit 1; }

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

valid_ipv4() {
    [[ ${#1} -le 15 && $1 != *$'\n'* ]] || return 1
    awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i > 255 ||
                    (length($i) > 1 && substr($i,1,1) == "0")) exit 1
            }
            if ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224 ||
                ($1 == 100 && $2 >= 64 && $2 <= 127) ||
                ($1 == 169 && $2 == 254) ||
                ($1 == 172 && $2 >= 16 && $2 <= 31) ||
                ($1 == 192 && $2 == 168) ||
                ($1 == 192 && $2 == 0 && ($3 == 0 || $3 == 2)) ||
                ($1 == 198 && ($2 == 18 || $2 == 19)) ||
                ($1 == 198 && $2 == 51 && $3 == 100) ||
                ($1 == 203 && $2 == 0 && $3 == 113)) exit 1
        }
    ' <<< "$1"
}

# Require two independent services to agree. Ignore failed or invalid replies.
query_ip() {
    local endpoint reply
    local -A votes=()
    for endpoint in \
        https://checkip.amazonaws.com \
        https://api.ipify.org \
        https://ipv4.icanhazip.com; do
        if ! reply=$(curl -4 -fsS --noproxy '*' --connect-timeout 3 --max-time 8 "$endpoint" 2>/dev/null); then
            continue
        fi
        reply=${reply//$'\r'/}
        valid_ipv4 "$reply" || continue
        votes[$reply]=$(( ${votes[$reply]:-0} + 1 ))
        if (( votes[$reply] >= 2 )); then
            printf '%s\n' "$reply"
            return 0
        fi
    done
    return 1
}

install -d -m 0700 "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0
state_file=$STATE_DIR/state
baseline=-
pending=-
count=0
last_action=0
if [[ -f $state_file ]]; then
    extra=
    if ! read -r baseline pending count last_action extra < "$state_file" ||
        [[ -n $extra ]] || ! valid_ipv4 "$baseline" ||
        { [[ $pending != - ]] && ! valid_ipv4 "$pending"; } ||
        [[ ! $count =~ ^[0-9]+$ || ${#count} -gt 3 ||
           ! $last_action =~ ^[0-9]+$ || ${#last_action} -gt 12 ]]; then
        log 'Invalid state; refusing to take action. Check /var/lib/nezha-ip-watch/state.'
        exit 1
    fi
fi

save_state() {
    local state_tmp
    state_tmp=$(mktemp "$STATE_DIR/.state.XXXXXX")
    printf '%s %s %s %s\n' "$baseline" "$pending" "$count" "$last_action" > "$state_tmp"
    mv -f -- "$state_tmp" "$state_file"
}

if [[ $mode == status ]]; then
    printf 'Action: %s\nAgent unit: %s\nBaseline IPv4: %s\nPending IPv4: %s (%s/%s)\nLast action epoch: %s\n' \
        "$ACTION" "$AGENT_UNIT" "$baseline" "$pending" "$count" "$CONFIRMATIONS" "$last_action"
    if current=$(query_ip); then
        printf 'Current confirmed IPv4: %s\n' "$current"
    else
        echo 'Current IPv4: no agreement from two services.'
        exit 1
    fi
    exit 0
fi

if ! current=$(query_ip); then
    # A failed check breaks the consecutive-confirmation sequence.
    if [[ $baseline != - && $pending != - ]]; then
        pending=-
        count=0
        save_state
    fi
    log 'IP query failed or services disagreed; no restart.'
    exit 0
fi

if [[ $baseline == - ]]; then
    baseline=$current
    save_state
    log "Initial baseline saved: $current; no restart."
    exit 0
fi

if [[ $current == "$baseline" ]]; then
    if [[ $pending != - ]]; then
        pending=-
        count=0
        save_state
    fi
    exit 0
fi

if [[ $current == "$pending" ]]; then
    (( count >= CONFIRMATIONS )) || count=$((count + 1))
else
    pending=$current
    count=1
fi
save_state
if (( count < CONFIRMATIONS )); then
    log "IP change candidate: $baseline -> $current ($count/$CONFIRMATIONS); awaiting next check."
    exit 0
fi

now=$(date +%s)
if (( now - last_action < COOLDOWN_SECONDS )); then
    log "IP change confirmed, but action is deferred by the ${COOLDOWN_SECONDS}s cooldown."
    exit 0
fi

# Save the NEW baseline BEFORE requesting a reboot to prevent a reboot loop.
previous_baseline=$baseline
baseline=$current
pending=-
count=0
last_action=$now
save_state
log "IPv4 changed: $previous_baseline -> $current; action=$ACTION."

if [[ $ACTION == reboot ]]; then
    if systemctl reboot; then
        exit 0
    fi
else
    if systemctl restart "$AGENT_UNIT"; then
        log "Restarted $AGENT_UNIT."
        exit 0
    fi
fi

# Keep the new baseline and cooldown even on command failure. The action may
# have reached systemd before a transport error; automatic retries could loop.
log "Action failed. Baseline kept at $current; inspect systemd logs and run the action manually."
exit 1
WATCHER

chmod 0755 "$watch_tmp"
mv -f -- "$watch_tmp" /usr/local/sbin/nezha-ip-watch
printf 'ACTION=%s\nAGENT_UNIT=%s\nCOOLDOWN_SECONDS=0\nCONFIRMATIONS=1\n' "$action" "$agent_unit" > "$config_tmp"
chmod 0600 "$config_tmp"
mv -f -- "$config_tmp" /etc/default/nezha-ip-watch

cat > /etc/systemd/system/nezha-ip-watch.service <<'SERVICE'
[Unit]
Description=Detect public IPv4 changes and restart Nezha Agent or EC2
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nezha-ip-watch run
TimeoutStartSec=150
UMask=0077
SERVICE

cat > /etc/systemd/system/nezha-ip-watch.timer <<'TIMER'
[Unit]
Description=Check public IPv4 approximately every minute

[Timer]
OnBootSec=90s
OnUnitInactiveSec=60s
AccuracySec=5s
Unit=nezha-ip-watch.service

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now nezha-ip-watch.timer
printf '\nInstalled. Action: %s\n' "$action"
echo 'First successful check only saves the baseline; it never restarts anything.'
echo 'Two matching checks confirm a changed IPv4; actions have a 15-minute cooldown.'
echo 'Status: sudo /usr/local/sbin/nezha-ip-watch status'
echo 'Logs:   sudo journalctl -u nezha-ip-watch.service -n 30 --no-pager'
echo 'Stop:   sudo systemctl disable --now nezha-ip-watch.timer'

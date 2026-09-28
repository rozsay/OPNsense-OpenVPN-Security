#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./gateway-switch.sh test [--apply] [--insecure]
  ./gateway-switch.sh live [--apply] [--insecure]
  ./gateway-switch.sh [--apply] [--insecure] test|live

Environment:
  OPN_HOST            OPNsense host/IP for API reload calls
  OPN_KEY             OPNsense API key
  OPN_SECRET          OPNsense API secret
  OPN_INSECURE        Set to 1 to allow insecure TLS for API calls (default: 0)
  UBUNTU_WAN_IF       Upstream internet interface on 192.168.226.3 (default: pppoe0)
  OPN_UPSTREAM_IP     OPNsense upstream IP (default: 192.168.226.31)
  UBUNTU_TEST_GW      Ubuntu gateway IP (default: 192.168.226.3)
  EXEC_SSH            Optional SSH target for the Ubuntu gateway (for remote execution)

Notes:
  - Default mode is DRY-RUN. Use --apply to execute.
  - This script changes only the reversible Ubuntu-side TEST/LIVE orchestration points it can do safely.
  - On OPNsense it only triggers firewall filter apply when API credentials are provided.
  - Persistent OPNsense gateway, interface, and OpenVPN config edits should still be reviewed and applied via GUI/API as documented.
USAGE
}

MODE=""
APPLY=0
OPN_INSECURE="${OPN_INSECURE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    test|live)
      MODE="$1"
      ;;
    --apply)
      APPLY=1
      ;;
    --insecure)
      OPN_INSECURE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

[[ -n "$MODE" ]] || { usage; exit 1; }

UBUNTU_WAN_IF="${UBUNTU_WAN_IF:-pppoe0}"
OPN_UPSTREAM_IP="${OPN_UPSTREAM_IP:-192.168.226.31}"
UBUNTU_TEST_GW="${UBUNTU_TEST_GW:-192.168.226.3}"
EXEC_SSH="${EXEC_SSH:-}"

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  if [[ "$APPLY" -eq 1 ]]; then
    "$@"
  fi
}

quote_join() {
  local out
  printf -v out '%q ' "$@"
  printf '%s' "${out% }"
}

ubuntu_run() {
  if [[ -n "$EXEC_SSH" ]]; then
    local remote_cmd
    remote_cmd="$(quote_join "$@")"
    run ssh "$EXEC_SSH" "$remote_cmd"
  else
    run "$@"
  fi
}

ubuntu_ensure_iptables_rule() {
  local table="$1" chain="$2"
  shift 2
  if [[ "$APPLY" -eq 1 ]]; then
    if [[ -n "$EXEC_SSH" ]]; then
      local remote_cmd
      remote_cmd="$(quote_join iptables -t "$table" -C "$chain" "$@")"
      if ! ssh "$EXEC_SSH" "$remote_cmd" >/dev/null 2>&1; then
        ubuntu_run iptables -t "$table" -A "$chain" "$@"
      fi
    else
      if ! iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
        ubuntu_run iptables -t "$table" -A "$chain" "$@"
      fi
    fi
  else
    ubuntu_run iptables -t "$table" -C "$chain" "$@"
    ubuntu_run iptables -t "$table" -A "$chain" "$@"
  fi
}

ubuntu_delete_iptables_rule() {
  local table="$1" chain="$2"
  shift 2
  if [[ "$APPLY" -eq 1 ]]; then
    if [[ -n "$EXEC_SSH" ]]; then
      local remote_cmd
      remote_cmd="$(quote_join iptables -t "$table" -D "$chain" "$@")"
      ssh "$EXEC_SSH" "$remote_cmd" >/dev/null 2>&1 || true
    else
      iptables -t "$table" -D "$chain" "$@" >/dev/null 2>&1 || true
    fi
  else
    ubuntu_run iptables -t "$table" -D "$chain" "$@"
  fi
}

opn_firewall_apply() {
  if [[ -z "${OPN_HOST:-}" || -z "${OPN_KEY:-}" || -z "${OPN_SECRET:-}" ]]; then
    echo "! OPNsense API credentials not set; skipping optional firewall apply call"
    return 0
  fi
  local -a curl_cmd=(curl -sS -u "$OPN_KEY:$OPN_SECRET" -H 'Content-Type: application/json' -X POST "https://${OPN_HOST}/api/firewall/filter/apply")
  if [[ "$OPN_INSECURE" == "1" ]]; then
    curl_cmd=(curl -k -sS -u "$OPN_KEY:$OPN_SECRET" -H 'Content-Type: application/json' -X POST "https://${OPN_HOST}/api/firewall/filter/apply")
  fi
  run "${curl_cmd[@]}"
}

add_test_routes() {
  local nets=(192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 192.168.40.0/24 192.168.50.0/24 192.168.60.0/24 10.8.0.0/24 10.10.0.0/24)
  local net
  for net in "${nets[@]}"; do
    ubuntu_run ip route replace "$net" via "$OPN_UPSTREAM_IP"
  done
}

remove_test_routes() {
  local nets=(192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 192.168.40.0/24 192.168.50.0/24 192.168.60.0/24 10.8.0.0/24 10.10.0.0/24)
  local net
  for net in "${nets[@]}"; do
    if [[ "$APPLY" -eq 1 ]]; then
      if [[ -n "$EXEC_SSH" ]]; then
        ssh "$EXEC_SSH" "$(quote_join ip route del "$net" via "$OPN_UPSTREAM_IP")" >/dev/null 2>&1 || true
      else
        ip route del "$net" via "$OPN_UPSTREAM_IP" >/dev/null 2>&1 || true
      fi
    else
      ubuntu_run ip route del "$net" via "$OPN_UPSTREAM_IP"
    fi
  done
}

add_test_openvpn_dnat() {
  ubuntu_ensure_iptables_rule nat PREROUTING -i "$UBUNTU_WAN_IF" -p udp --dport 11194 -j DNAT --to-destination "$OPN_UPSTREAM_IP:11194"
}

remove_test_openvpn_dnat() {
  ubuntu_delete_iptables_rule nat PREROUTING -i "$UBUNTU_WAN_IF" -p udp --dport 11194 -j DNAT --to-destination "$OPN_UPSTREAM_IP:11194"
}

show_manual_opnsense_steps() {
  if [[ "$MODE" == "test" ]]; then
    cat <<EOF2

Manual OPNsense checkpoints for TEST mode:
- Default gateway should prefer LAN_GW (${UBUNTU_TEST_GW})
- OpenVPN server should stay on UDP/11194
- OpenVPN local bind should be blank or ${OPN_UPSTREAM_IP}
- OpenVPN push routes should include 192.168.10.0/24 if MGMT access is required
- Re-apply firewall/filter after changes
- Reconfigure gateway/interface/OpenVPN services manually after persistent OPNsense-side changes
EOF2
  else
    cat <<EOF2

Manual OPNsense checkpoints for LIVE mode:
- Promote PPPoE gateway as primary default gateway
- Publish OpenVPN directly on OPNsense WAN/PPPoE side
- Remove dependency on Ubuntu DNAT for UDP/11194
- Review outbound NAT for WAN/PPPoE
- Re-apply firewall/filter after changes
- Reconfigure gateway/interface/OpenVPN services manually after persistent OPNsense-side changes
EOF2
  fi
}

if [[ "$MODE" == "test" ]]; then
  echo "Switching toward TEST mode"
  add_test_routes
  add_test_openvpn_dnat
  opn_firewall_apply
  show_manual_opnsense_steps
else
  echo "Switching toward LIVE mode"
  remove_test_openvpn_dnat
  remove_test_routes
  opn_firewall_apply
  show_manual_opnsense_steps
fi

if [[ "$APPLY" -eq 0 ]]; then
  echo
  echo "Dry-run only. Re-run with --apply to execute commands."
fi

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./gateway-switch.sh test [--apply] [--insecure]
  ./gateway-switch.sh live [--apply] [--insecure]
  ./gateway-switch.sh [--apply] [--insecure] test|live

Environment:
  OPN_HOST                    OPNsense host/IP for API reload calls
  OPN_KEY                     OPNsense API key
  OPN_SECRET                  OPNsense API secret
  OPN_INSECURE                Set to 1 to allow insecure TLS for API calls (default: 0)
  OPN_GATEWAY_RECONFIG_PATH   Optional API path for gateway reconfigure/apply
  OPN_INTERFACE_RECONFIG_PATH Optional API path for interface reconfigure/apply
  OPN_OPENVPN_RECONFIG_PATH   Optional API path for OpenVPN reconfigure/apply
  UBUNTU_WAN_IF               Upstream internet interface on 192.168.226.3 (default: pppoe0)
  OPN_UPSTREAM_IP             OPNsense upstream IP (default: 192.168.226.31)
  UBUNTU_TEST_GW              Ubuntu gateway IP (default: 192.168.226.3)
  EXEC_SSH                    Optional SSH target for the Ubuntu gateway (for remote execution)
  OPENVPN_ALLOWED_SRC         Required source CIDR allowed to hit UDP/11194 in TEST mode
  CONFIRM_RETURN_PATH_VIA_UBUNTU Set to 1 to confirm OPNsense replies return via 192.168.226.3 in TEST mode

Notes:
  - Default mode is DRY-RUN. Use --apply to execute.
  - This script changes only the reversible Ubuntu-side TEST/LIVE orchestration points it can do safely.
  - On OPNsense it can apply firewall changes and optional reconfigure endpoints when API credentials are provided.
  - Persistent OPNsense gateway, interface, and OpenVPN config edits should still be reviewed and applied via GUI/API as documented.
USAGE
}

MODE=""
APPLY=0
OPN_INSECURE="${OPN_INSECURE:-0}"
OPN_GATEWAY_RECONFIG_PATH="${OPN_GATEWAY_RECONFIG_PATH:-}"
OPN_INTERFACE_RECONFIG_PATH="${OPN_INTERFACE_RECONFIG_PATH:-}"
OPN_OPENVPN_RECONFIG_PATH="${OPN_OPENVPN_RECONFIG_PATH:-}"

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
OPENVPN_ALLOWED_SRC="${OPENVPN_ALLOWED_SRC:-}"
CONFIRM_RETURN_PATH_VIA_UBUNTU="${CONFIRM_RETURN_PATH_VIA_UBUNTU:-0}"
ROUTED_NETS=(192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 192.168.40.0/24 192.168.50.0/24 192.168.60.0/24 10.8.0.0/24 10.10.0.0/24)

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  if [[ "$APPLY" -eq 1 ]]; then
    "$@"
  fi
}

preview_conditional_add() {
  printf '+ if missing: '
  printf '%q ' "$@"
  printf '\n'
}

quote_join() {
  local out
  printf -v out '%q ' "$@"
  printf '%s' "${out% }"
}

require_test_mode_prereqs() {
  if [[ -z "$OPENVPN_ALLOWED_SRC" ]]; then
    echo "OPENVPN_ALLOWED_SRC must be set (example: 203.0.113.4/32) before publishing UDP/11194 in TEST mode" >&2
    exit 1
  fi
  if [[ "$CONFIRM_RETURN_PATH_VIA_UBUNTU" != "1" ]]; then
    echo "CONFIRM_RETURN_PATH_VIA_UBUNTU=1 is required to acknowledge that OPNsense replies return via 192.168.226.3 in TEST mode" >&2
    exit 1
  fi
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
    preview_conditional_add iptables -t "$table" -A "$chain" "$@"
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

opn_api_post() {
  local path="$1"
  [[ -n "$path" ]] || return 0

  if [[ -z "${OPN_HOST:-}" || -z "${OPN_KEY:-}" || -z "${OPN_SECRET:-}" ]]; then
    echo "! OPNsense API credentials not set; skipping API call to ${path}"
    return 0
  fi

  local curl_url="https://${OPN_HOST}${path}"
  local curl_cfg
  curl_cfg=$(cat <<CFG
user = "${OPN_KEY}:${OPN_SECRET}"
header = "Content-Type: application/json"
request = "POST"
url = "${curl_url}"
CFG
)

  if [[ "$APPLY" -eq 1 ]]; then
    if [[ "$OPN_INSECURE" == "1" ]]; then
      printf '%s\n' "$curl_cfg" | curl -k -sS --config -
    else
      printf '%s\n' "$curl_cfg" | curl -sS --config -
    fi
  else
    echo "+ curl --config - ${curl_url}"
  fi
}

opn_apply_steps() {
  opn_api_post /api/firewall/filter/apply
  opn_api_post "$OPN_GATEWAY_RECONFIG_PATH"
  opn_api_post "$OPN_INTERFACE_RECONFIG_PATH"
  opn_api_post "$OPN_OPENVPN_RECONFIG_PATH"

  if [[ -z "$OPN_GATEWAY_RECONFIG_PATH" || -z "$OPN_INTERFACE_RECONFIG_PATH" || -z "$OPN_OPENVPN_RECONFIG_PATH" ]]; then
    echo "! Optional OPNsense reconfigure paths are not fully set; persistent gateway/interface/OpenVPN changes still need manual apply if you modified them"
  fi
}

apply_routes() {
  local action="$1"
  local net
  for net in "${ROUTED_NETS[@]}"; do
    if [[ "$action" == "add" ]]; then
      ubuntu_run ip route replace "$net" via "$OPN_UPSTREAM_IP"
    else
      if [[ "$APPLY" -eq 1 ]]; then
        if [[ -n "$EXEC_SSH" ]]; then
          ssh "$EXEC_SSH" "$(quote_join ip route del "$net" via "$OPN_UPSTREAM_IP")" >/dev/null 2>&1 || true
        else
          ip route del "$net" via "$OPN_UPSTREAM_IP" >/dev/null 2>&1 || true
        fi
      else
        ubuntu_run ip route del "$net" via "$OPN_UPSTREAM_IP"
      fi
    fi
  done
}

add_test_openvpn_dnat() {
  require_test_mode_prereqs
  ubuntu_ensure_iptables_rule nat PREROUTING -i "$UBUNTU_WAN_IF" -s "$OPENVPN_ALLOWED_SRC" -p udp --dport 11194 -j DNAT --to-destination "$OPN_UPSTREAM_IP:11194"
  ubuntu_ensure_iptables_rule filter FORWARD -i "$UBUNTU_WAN_IF" -s "$OPENVPN_ALLOWED_SRC" -p udp -d "$OPN_UPSTREAM_IP" --dport 11194 -j ACCEPT
}

remove_test_openvpn_dnat() {
  if [[ -n "$OPENVPN_ALLOWED_SRC" ]]; then
    ubuntu_delete_iptables_rule nat PREROUTING -i "$UBUNTU_WAN_IF" -s "$OPENVPN_ALLOWED_SRC" -p udp --dport 11194 -j DNAT --to-destination "$OPN_UPSTREAM_IP:11194"
    ubuntu_delete_iptables_rule filter FORWARD -i "$UBUNTU_WAN_IF" -s "$OPENVPN_ALLOWED_SRC" -p udp -d "$OPN_UPSTREAM_IP" --dport 11194 -j ACCEPT
  else
    echo "! OPENVPN_ALLOWED_SRC not set; deleting broad UDP/11194 DNAT/FORWARD helpers for ${OPN_UPSTREAM_IP}"
    ubuntu_delete_iptables_rule nat PREROUTING -i "$UBUNTU_WAN_IF" -p udp --dport 11194 -j DNAT --to-destination "$OPN_UPSTREAM_IP:11194"
    ubuntu_delete_iptables_rule filter FORWARD -i "$UBUNTU_WAN_IF" -p udp -d "$OPN_UPSTREAM_IP" --dport 11194 -j ACCEPT
  fi
}

show_manual_opnsense_steps() {
  if [[ "$MODE" == "test" ]]; then
    cat <<EOF2

Manual OPNsense checkpoints for TEST mode:
- Default gateway should prefer LAN_GW (${UBUNTU_TEST_GW})
- OpenVPN server should stay on UDP/11194
- OpenVPN local bind should be blank or ${OPN_UPSTREAM_IP}
- OPENVPN_ALLOWED_SRC should be set to the remote client CIDR(s) permitted in TEST mode
- CONFIRM_RETURN_PATH_VIA_UBUNTU=1 should only be set when OPNsense replies are known to return via 192.168.226.3 in TEST mode
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
  apply_routes add
  add_test_openvpn_dnat
  opn_apply_steps
  show_manual_opnsense_steps
else
  echo "Switching toward LIVE mode"
  remove_test_openvpn_dnat
  apply_routes del
  opn_apply_steps
  show_manual_opnsense_steps
fi

if [[ "$APPLY" -eq 0 ]]; then
  echo
  echo "Dry-run only. Re-run with --apply to execute commands."
fi

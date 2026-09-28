#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./gateway-switch.sh test [--apply]
  ./gateway-switch.sh live [--apply]

Environment:
  OPN_HOST            OPNsense host/IP for API reload calls
  OPN_KEY             OPNsense API key
  OPN_SECRET          OPNsense API secret
  UBUNTU_WAN_IF       Upstream internet interface on 192.168.226.3 (default: pppoe0)
  OPN_UPSTREAM_IP     OPNsense upstream IP (default: 192.168.226.31)
  UBUNTU_TEST_GW      Ubuntu gateway IP (default: 192.168.226.3)
  EXEC_SSH            Optional SSH target for the Ubuntu gateway (for remote execution)

Notes:
  - Default mode is DRY-RUN. Use --apply to execute.
  - This script changes only the reversible TEST/LIVE orchestration points it can do safely.
  - Persistent OPNsense config edits should still be reviewed and applied via GUI/API as documented.
USAGE
}

MODE="${1:-}"
APPLY=0
[[ "${2:-}" == "--apply" ]] && APPLY=1

[[ -n "$MODE" ]] || { usage; exit 1; }
[[ "$MODE" == "test" || "$MODE" == "live" ]] || { usage; exit 1; }

UBUNTU_WAN_IF="${UBUNTU_WAN_IF:-pppoe0}"
OPN_UPSTREAM_IP="${OPN_UPSTREAM_IP:-192.168.226.31}"
UBUNTU_TEST_GW="${UBUNTU_TEST_GW:-192.168.226.3}"
EXEC_SSH="${EXEC_SSH:-}"

run() {
  echo "+ $*"
  if [[ "$APPLY" -eq 1 ]]; then
    eval "$*"
  fi
}

ubuntu_run() {
  local cmd="$1"
  if [[ -n "$EXEC_SSH" ]]; then
    run "ssh ${EXEC_SSH@Q} ${cmd@Q}"
  else
    run "$cmd"
  fi
}

opn_apply() {
  if [[ -z "${OPN_HOST:-}" || -z "${OPN_KEY:-}" || -z "${OPN_SECRET:-}" ]]; then
    echo "! OPNsense API credentials not set; skipping API apply calls"
    return 0
  fi
  run "curl -sk -u ${OPN_KEY@Q}:${OPN_SECRET@Q} -H 'Content-Type: application/json' -X POST https://${OPN_HOST}/api/firewall/filter/apply"
}

add_test_routes() {
  local nets=(192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 192.168.40.0/24 192.168.50.0/24 192.168.60.0/24 10.8.0.0/24 10.10.0.0/24)
  for net in "${nets[@]}"; do
    ubuntu_run "ip route replace ${net} via ${OPN_UPSTREAM_IP}"
  done
}

remove_test_routes() {
  local nets=(192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 192.168.40.0/24 192.168.50.0/24 192.168.60.0/24 10.8.0.0/24 10.10.0.0/24)
  for net in "${nets[@]}"; do
    ubuntu_run "ip route del ${net} via ${OPN_UPSTREAM_IP} || true"
  done
}

add_test_openvpn_dnat() {
  ubuntu_run "iptables -t nat -C PREROUTING -i ${UBUNTU_WAN_IF} -p udp --dport 11194 -j DNAT --to-destination ${OPN_UPSTREAM_IP}:11194 || iptables -t nat -A PREROUTING -i ${UBUNTU_WAN_IF} -p udp --dport 11194 -j DNAT --to-destination ${OPN_UPSTREAM_IP}:11194"
}

remove_test_openvpn_dnat() {
  ubuntu_run "iptables -t nat -D PREROUTING -i ${UBUNTU_WAN_IF} -p udp --dport 11194 -j DNAT --to-destination ${OPN_UPSTREAM_IP}:11194 || true"
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
EOF2
  else
    cat <<EOF2

Manual OPNsense checkpoints for LIVE mode:
- Promote PPPoE gateway as primary default gateway
- Publish OpenVPN directly on OPNsense WAN/PPPoE side
- Remove dependency on Ubuntu DNAT for UDP/11194
- Review outbound NAT for WAN/PPPoE
- Re-apply firewall/filter after changes
EOF2
  fi
}

if [[ "$MODE" == "test" ]]; then
  echo "Switching toward TEST mode"
  add_test_routes
  add_test_openvpn_dnat
  opn_apply
  show_manual_opnsense_steps
else
  echo "Switching toward LIVE mode"
  remove_test_openvpn_dnat
  remove_test_routes
  opn_apply
  show_manual_opnsense_steps
fi

if [[ "$APPLY" -eq 0 ]]; then
  echo
  echo "Dry-run only. Re-run with --apply to execute commands."
fi

#!/usr/bin/env bash
# =============================================================================
# topsoft-switch.sh  v1.0  (2026-09-28)
# TESZT <-> ÉLES váltás EGY paranccsal, a helyes sorrendben, automatikus
# visszaállással. Az admin gépről fut (pl. ROZSAY 192.168.30.71, Linux/WSL).
#
#   topsoft-switch.sh status
#   topsoft-switch.sh eles  [--dry-run] [--yes]
#   topsoft-switch.sh test  [--dry-run] [--yes]
#
# Sorrend (egy fix IP-s PPPoE session egyszerre csak egy gépen élhet!):
#   ÉLES: 226.3 PPPoE le -> várakozás -> OPNsense PPPoE fel -> ellenőrzés
#   TESZT: OPNsense PPPoE le -> várakozás -> 226.3 PPPoE fel -> ellenőrzés
# Ha a második lépés elbukik, a script visszaállítja az előző módot.
#
# Előfeltétel: SSH kulcsos belépés mindkét gépre (root), a két mód-script telepítve.
# Felülírható környezeti változók: GW_SSH, OPN_SSH, OPN_PORT, PPP_RELEASE_WAIT
# =============================================================================
set -uo pipefail

GW_SSH="${GW_SSH:-root@192.168.226.3}"
OPN_SSH="${OPN_SSH:-root@192.168.30.1}"      # OPNsense SSH csak az opt3-on figyel!
OPN_PORT="${OPN_PORT:-19992}"
PPP_RELEASE_WAIT="${PPP_RELEASE_WAIT:-15}"   # mp a PPPoE session felszabadulására a szolgáltatónál
GW_CMD="/usr/local/sbin/topsoft-mode.sh"
OPN_CMD="/usr/local/bin/php /root/topsoft/topsoft-mode.php"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=6)
DRY=""; YES=0
LOG="topsoft-switch_$(date +%Y%m%d_%H%M%S).log"

c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_c=$'\e[36m'; c_0=$'\e[0m'
say()  { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG" >&2; }
info() { say "${c_c}[*]${c_0} $*"; }
ok()   { say "${c_g}[OK]${c_0} $*"; }
warn() { say "${c_y}[!]${c_0} $*"; }
die()  { say "${c_r}[X]${c_0} $*"; exit 1; }

gw()  { ssh "${SSH_OPTS[@]}" "$GW_SSH" "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
opn() { ssh "${SSH_OPTS[@]}" -p "$OPN_PORT" "$OPN_SSH" "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

confirm() { [[ $YES -eq 1 || -n $DRY ]] && return 0; read -r -p "$1 [i/N] " a; [[ $a =~ ^[iIyY]$ ]]; }

preflight() {
    info "Előellenőrzés"
    ssh "${SSH_OPTS[@]}" "$GW_SSH" "test -x $GW_CMD" >/dev/null 2>&1 || die "226.3: nem érhető el SSH-n vagy nincs telepítve: $GW_CMD"
    ssh "${SSH_OPTS[@]}" -p "$OPN_PORT" "$OPN_SSH" "test -f /root/topsoft/topsoft-mode.php" >/dev/null 2>&1 \
        || die "OPNsense: nem érhető el SSH-n ($OPN_SSH:$OPN_PORT) vagy nincs telepítve a topsoft-mode.php"
    ok "Mindkét gép elérhető"
}

verify() { # mode
    info "Ellenőrzés ($1)"
    local rc=0
    if [[ $1 == eles ]]; then
        opn "ifconfig pppoe0 | grep 'inet '" || rc=1
        opn "ping -c3 -t5 1.1.1.1 >/dev/null && echo 'OPNsense -> internet OK'" || rc=1
        gw  "ip route get 1.1.1.1 | head -1; ping -c3 -W2 1.1.1.1 >/dev/null && echo '226.3 -> internet (OPNsense-en át) OK'" || rc=1
    else
        gw  "ip -4 -o addr show dev ppp0 | awk '{print \$4}'; ping -c3 -W2 1.1.1.1 >/dev/null && echo '226.3 -> internet OK'" || rc=1
        opn "ping -c3 -t5 1.1.1.1 >/dev/null && echo 'OPNsense -> internet (226.3-on át) OK'" || rc=1
    fi
    return $rc
}

to_eles() {
    confirm "ÉLES módra váltás (néhány perc internet-kiesés)?" || die "Megszakítva"
    info "1/3 226.3: PPPoE le, default route -> 192.168.226.31"
    gw "$GW_CMD eles ${DRY:+-n}" || die "226.3 ÉLES váltás sikertelen - semmi nem változott az OPNsense-en"
    [[ -n $DRY ]] || { info "2/3 várakozás ${PPP_RELEASE_WAIT} mp (PPPoE session felszabadulás)"; sleep "$PPP_RELEASE_WAIT"; }
    info "3/3 OPNsense: PPPoE fel"
    if ! opn "$OPN_CMD eles ${DRY:+--dry-run}"; then
        warn "OPNsense ÉLES sikertelen -> VISSZAÁLLÁS TESZT módra"
        opn "$OPN_CMD test" || warn "OPNsense visszaállítás hiba"
        sleep "$PPP_RELEASE_WAIT"
        gw "$GW_CMD test" || warn "226.3 visszaállítás hiba - kézzel: $GW_CMD test"
        die "Visszaállítva TESZT módra. Nézd meg a naplót: $LOG"
    fi
    [[ -n $DRY ]] && { ok "DRY-RUN kész"; return; }
    verify eles && ok "ÉLES mód aktív" || warn "ÉLES mód aktív, de az ellenőrzés hibát jelzett - nézd meg: $LOG"
    info "VoIP telefonok: a DHCP lease-megújításig a régi gatewayt (226.3) használják, a 226.3 továbbítja őket. Újraregisztráláshoz indítsd újra őket."
}

to_test() {
    confirm "TESZT módra váltás (néhány perc internet-kiesés)?" || die "Megszakítva"
    info "1/3 OPNsense: PPPoE le"
    opn "$OPN_CMD test ${DRY:+--dry-run}" || die "OPNsense TESZT váltás sikertelen"
    [[ -n $DRY ]] || { info "2/3 várakozás ${PPP_RELEASE_WAIT} mp"; sleep "$PPP_RELEASE_WAIT"; }
    info "3/3 226.3: PPPoE fel"
    if ! gw "$GW_CMD test ${DRY:+-n}"; then
        warn "226.3 TESZT sikertelen -> VISSZAÁLLÁS ÉLES módra"
        gw "$GW_CMD eles" || warn "226.3 visszaállítás hiba"
        sleep "$PPP_RELEASE_WAIT"
        opn "$OPN_CMD eles" || warn "OPNsense visszaállítás hiba"
        die "Visszaállítva ÉLES módra. Napló: $LOG"
    fi
    [[ -n $DRY ]] && { ok "DRY-RUN kész"; return; }
    verify test && ok "TESZT mód aktív" || warn "TESZT mód aktív, de az ellenőrzés hibát jelzett - napló: $LOG"
}

cmd=${1:-status}; shift || true
for a in "$@"; do
    case $a in
        --dry-run|-n) DRY=1 ;;
        --yes|-y) YES=1 ;;
        *) die "Ismeretlen opció: $a" ;;
    esac
done
command -v ssh >/dev/null || die "ssh kell"
case $cmd in
    status) preflight; info "== 226.3"; gw "$GW_CMD status"; info "== OPNsense"; opn "$OPN_CMD status" ;;
    eles)   preflight; to_eles ;;
    test)   preflight; to_test ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

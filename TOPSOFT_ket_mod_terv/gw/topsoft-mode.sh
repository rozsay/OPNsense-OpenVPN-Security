#!/usr/bin/env bash
# =============================================================================
# topsoft-mode.sh  v1.0  (2026-09-28)
# gw.topsoft.hu (192.168.226.3, Ubuntu) - TESZT / ÉLES üzemmód váltó
#
#   TESZT : a 226.3 tárcsázza a fix IP-s PPPoE-t (dsl-provider), ő a default GW
#           a 226/24-nek; UDP 11194 DNAT -> OPNsense 192.168.226.31
#   ÉLES  : PPPoE lekapcsolva, default route -> 192.168.226.31 (OPNsense),
#           DHCP "option routers" -> 192.168.226.31, a publikus szolgáltatások
#           (Postfix/Dovecot/OpenVPN 1987) az OPNsense port forwardján jönnek be br0-n
#
# Használat (root):
#   topsoft-mode.sh install        egyszeri telepítés (conf, systemd unit, dhcpd include)
#   topsoft-mode.sh status         állapot + kapcsolat tesztek
#   topsoft-mode.sh check          ÉLES-mód előtti ellenőrzés (publikus IP-re kötött szolgáltatások stb.)
#   topsoft-mode.sh test  [-n]     TESZT mód   (-n = dry-run)
#   topsoft-mode.sh eles  [-n]     ÉLES mód
#   topsoft-mode.sh apply          a mentett mód újra-alkalmazása (boot, systemd)
#   topsoft-mode.sh export-dnat    a mostani ppp0 DNAT-ok CSV-ben az OPNsense setuphoz
#
# Konfig: /etc/topsoft/mode.conf     Mód: /etc/topsoft/mode     Napló: /var/log/topsoft-mode.log
# =============================================================================
set -Eeuo pipefail

VERSION="1.0"
CONF=/etc/topsoft/mode.conf
MODE_FILE=/etc/topsoft/mode
LOGF=/var/log/topsoft-mode.log
DRY=0

# ---- alapértékek (a mode.conf felülírja) ------------------------------------
LAN_IF=br0
SELF_IP=192.168.226.3
OPN_IP=192.168.226.31
PPP_PROVIDER=dsl-provider
PPP_IF=ppp0
PUBLIC_IP=""                                  # fix IP (ha üres: ppp0-ról olvassa)
OVPN_OPN_PORT=11194
OLD_OVPN_TARGET=192.168.10.1                  # régi, HIBÁS DNAT cél
ROUTED_NETS="192.168.10.0/24 192.168.20.0/24 192.168.30.0/24 192.168.40.0/24 192.168.50.0/24 192.168.60.0/24 192.168.70.0/24 10.18.0.0/24"
PUBLIC_TCP_PORTS="25 465 587 993 995"          # ÉLES módban br0-n fogadott publikus szolgáltatások
PUBLIC_UDP_PORTS="1987"
POSTFIX_PORTS="25 465 587 993 995"             # ezeket az OPNsense NAT 1100 már lefedi (export-dnat kihagyja)
DHCPD_CONF=/etc/dhcp/dhcpd.conf
DHCP_SUBNET=192.168.226.0
DHCP_ROUTER_INC=/etc/dhcp/topsoft-router-226.conf
DHCP_SERVICE=isc-dhcp-server
IFACES_FILE=/etc/network/interfaces
# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"

# ---- segédek ----------------------------------------------------------------
c_r=$'\e[31m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_c=$'\e[36m'; c_0=$'\e[0m'
_log() { local m; m="$(date '+%F %T') $*"; echo "$m" >&2; [[ $DRY -eq 1 ]] || echo "$m" | sed 's/\x1b\[[0-9;]*m//g' >>"$LOGF"; }
info() { _log "${c_c}[*]${c_0} $*"; }
ok()   { _log "${c_g}[OK]${c_0} $*"; }
warn() { _log "${c_y}[!]${c_0} $*"; }
die()  { _log "${c_r}[X]${c_0} $*"; exit 1; }
trap 'die "Hiba a(z) $LINENO. sorban: $BASH_COMMAND"' ERR

run() { if [[ $DRY -eq 1 ]]; then echo "  DRY: $*" >&2; else echo "  \$ $*" >>"$LOGF"; "$@"; fi; }
ipt() { run iptables -w "$@"; }
have_rule() { iptables -w "$@" 2>/dev/null; }      # -C ellenőrzés, nem módosít

need_root() { [[ $EUID -eq 0 ]] || die "root kell"; }
lock() { exec 9>/run/topsoft-mode.lock; flock -n 9 || die "Már fut egy példány"; }

ppp_ip() { ip -4 -o addr show dev "$PPP_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }
cur_mode() { [[ -r $MODE_FILE ]] && cat "$MODE_FILE" || echo "ismeretlen"; }

# ---- iptables láncok ----------------------------------------------------------
ensure_chains() {
    iptables -w -t nat -S TOPSOFT_PRE >/dev/null 2>&1 || ipt -t nat -N TOPSOFT_PRE
    iptables -w -S TOPSOFT_FWD >/dev/null 2>&1 || ipt -N TOPSOFT_FWD
    iptables -w -S TOPSOFT_IN >/dev/null 2>&1 || ipt -N TOPSOFT_IN
    have_rule -t nat -C PREROUTING -j TOPSOFT_PRE || ipt -t nat -I PREROUTING 1 -j TOPSOFT_PRE
    have_rule -C FORWARD -j TOPSOFT_FWD || ipt -I FORWARD 1 -j TOPSOFT_FWD
    have_rule -C INPUT -j TOPSOFT_IN || ipt -I INPUT 1 -j TOPSOFT_IN
}

remove_old_ovpn_dnat() {
    # a régi, 192.168.10.1-re mutató DNAT eltávolítása (a hiba oka, lásd terv 2. fejezet)
    local line n=0
    while IFS= read -r line; do
        [[ $line == -A* ]] || continue
        [[ $line == *"TOPSOFT_PRE"* ]] && continue
        local -a a; read -ra a <<<"${line/#-A/-D}"
        warn "Régi hibás DNAT törlése: $line"
        ipt -t nat "${a[@]}"; n=$((n+1))
    done < <(iptables-save -t nat | grep -E -- "--to-destination ${OLD_OVPN_TARGET//./\\.}(:${OVPN_OPN_PORT})?( |$)" | grep -- "--dport ${OVPN_OPN_PORT}" || true)
    if [[ $n -gt 0 ]]; then
        local f
        for f in /etc/iptables/rules.v4 /etc/rc.local /etc/network/interfaces /etc/network/if-up.d/* /usr/local/sbin/*.sh; do
            if [[ -f $f ]] && grep -q -- "$OLD_OVPN_TARGET" "$f" 2>/dev/null && grep -q -- "$OVPN_OPN_PORT" "$f" 2>/dev/null; then
                warn "  A régi DNAT perzisztens helyen is szerepel, töröld innen is: $f"
            fi
        done
    fi
}

ensure_static_routes() {
    local n
    for n in $ROUTED_NETS; do
        ip route show "$n" | grep -q "via $OPN_IP" || run ip route replace "$n" via "$OPN_IP" dev "$LAN_IF"
    done
}

# ---- ifupdown auto sor --------------------------------------------------------
set_ppp_auto() { # on|off
    [[ -f $IFACES_FILE ]] || { warn "$IFACES_FILE nincs - PPPoE boot-autostart nem kezelt"; return; }
    if grep -qE "^[#[:space:]]*auto[[:space:]]+${PPP_PROVIDER}\b" "$IFACES_FILE"; then
        if [[ $1 == on ]]; then run sed -i -E "s/^[#[:space:]]*auto([[:space:]]+${PPP_PROVIDER})\b.*$/auto\1/" "$IFACES_FILE"
        else                   run sed -i -E "s/^[[:space:]]*auto([[:space:]]+${PPP_PROVIDER})\b.*$/#auto\1   # topsoft-mode: ELES/" "$IFACES_FILE"; fi
    else
        warn "Nincs 'auto $PPP_PROVIDER' sor a $IFACES_FILE-ban (a PPPoE boot-indítását ellenőrizd kézzel)"
    fi
}

# ---- DHCP router --------------------------------------------------------------
set_dhcp_router() {
    local r=$1
    [[ -f $DHCP_ROUTER_INC ]] || { warn "$DHCP_ROUTER_INC nincs - futtasd: $0 install"; return; }
    if grep -q "option routers $r;" "$DHCP_ROUTER_INC"; then ok "DHCP router már $r"; return; fi
    if [[ $DRY -eq 1 ]]; then echo "  DRY: $DHCP_ROUTER_INC <- option routers $r;" >&2; return; fi
    cp -a "$DHCP_ROUTER_INC" "$DHCP_ROUTER_INC.prev"
    printf '# topsoft-mode.sh kezeli - kézzel ne szerkeszd\noption routers %s;\n' "$r" >"$DHCP_ROUTER_INC"
    if ! dhcpd -t -cf "$DHCPD_CONF" >/dev/null 2>&1; then
        mv "$DHCP_ROUTER_INC.prev" "$DHCP_ROUTER_INC"; die "dhcpd -t hiba, visszaállítva"
    fi
    run systemctl restart "$DHCP_SERVICE"
    ok "DHCP option routers = $r (a kliensek a következő lease-megújításkor kapják meg)"
}

# ---- módok --------------------------------------------------------------------
mode_test() {
    info "===== TESZT mód: PPPoE a 226.3-on ====="
    ensure_chains
    remove_old_ovpn_dnat
    ipt -t nat -F TOPSOFT_PRE
    ipt -t nat -A TOPSOFT_PRE -i "$PPP_IF" -p udp --dport "$OVPN_OPN_PORT" -m comment --comment "topsoft TEST: OpenVPN -> OPNsense 226.31" \
        -j DNAT --to-destination "$OPN_IP:$OVPN_OPN_PORT"
    ipt -F TOPSOFT_FWD
    ipt -A TOPSOFT_FWD -i "$PPP_IF" -o "$LAN_IF" -d "$OPN_IP" -p udp --dport "$OVPN_OPN_PORT" -j ACCEPT
    ipt -F TOPSOFT_IN
    ensure_static_routes
    set_ppp_auto on
    # az ÉLES módban beállított default route ki, hogy a pppd felvehesse a sajátját
    if ip route show default | grep -q "via $OPN_IP"; then run ip route del default via "$OPN_IP"; fi
    if [[ -z $(ppp_ip) ]]; then
        if pgrep -f "pppd call $PPP_PROVIDER" >/dev/null 2>&1; then
            info "A pppd már fut (tárcsáz) - várok"
        else
            info "PPPoE indítása (pon $PPP_PROVIDER)"
            run pon "$PPP_PROVIDER"
        fi
        if [[ $DRY -eq 0 ]]; then
            local _i; for _i in $(seq 1 45); do [[ -n $(ppp_ip) ]] && break; sleep 2; done
            [[ -n $(ppp_ip) ]] || die "A PPPoE 90 mp alatt nem épült fel (az OPNsense PPPoE-ja biztosan KI van kapcsolva?)"
        fi
    fi
    if [[ $DRY -eq 0 ]] && ! ip route show default | grep -q "dev $PPP_IF"; then
        run ip route replace default dev "$PPP_IF"
    fi
    set_dhcp_router "$SELF_IP"
    [[ $DRY -eq 1 ]] || { mkdir -p "$(dirname "$MODE_FILE")"; echo test >"$MODE_FILE"; }
    ok "TESZT mód aktív. PPPoE: $(ppp_ip || true)"
}

mode_eles() {
    info "===== ÉLES mód: internet az OPNsense-en (192.168.226.31) ====="
    if ! ping -c2 -W2 "$OPN_IP" >/dev/null 2>&1; then
        [[ ${1:-} == boot ]] && warn "Az OPNsense ($OPN_IP) még nem válaszol (boot) - folytatom" \
                             || die "Az OPNsense ($OPN_IP) nem pingelhető - megszakítva"
    fi
    ensure_chains
    remove_old_ovpn_dnat
    set_dhcp_router "$OPN_IP"
    info "PPPoE bontása (poff $PPP_PROVIDER), hogy az OPNsense felvehesse a fix IP-s sessiont"
    set_ppp_auto off
    if [[ -n $(ppp_ip) ]]; then
        run poff "$PPP_PROVIDER" || true
        if [[ $DRY -eq 0 ]]; then
            local _i; for _i in $(seq 1 15); do [[ -z $(ppp_ip) ]] && break; sleep 2; done
            [[ -z $(ppp_ip) ]] || { run poff -a || true; sleep 3; }
            [[ -z $(ppp_ip) ]] || die "A $PPP_IF nem bomlott le"
        fi
    fi
    run ip route replace default via "$OPN_IP" dev "$LAN_IF"
    ensure_static_routes
    ipt -t nat -F TOPSOFT_PRE
    ipt -F TOPSOFT_FWD
    # a régi (226.3) gatewayt még használó kliensek forgalma br0-n be és ki (hairpin) + ICMP redirect
    ipt -A TOPSOFT_FWD -i "$LAN_IF" -o "$LAN_IF" -j ACCEPT
    run sysctl -qw "net.ipv4.conf.all.send_redirects=1" "net.ipv4.conf.${LAN_IF}.send_redirects=1"
    ipt -F TOPSOFT_IN
    local p
    for p in $PUBLIC_TCP_PORTS; do ipt -A TOPSOFT_IN -i "$LAN_IF" ! -s 192.168.0.0/16 -p tcp --dport "$p" -j ACCEPT; done
    for p in $PUBLIC_UDP_PORTS; do ipt -A TOPSOFT_IN -i "$LAN_IF" ! -s 192.168.0.0/16 -p udp --dport "$p" -j ACCEPT; done
    [[ $DRY -eq 1 ]] || echo eles >"$MODE_FILE"
    ok "ÉLES mód aktív a 226.3-on. Következő: OPNsense 'topsoft-mode.php eles'"
}

# ---- status / check / export --------------------------------------------------
status() {
    echo "topsoft-mode.sh v$VERSION   mentett mód: $(cur_mode)"
    echo "PPPoE ($PPP_IF)   : $(ppp_ip || true)"
    echo "default route  : $(ip route show default | head -1)"
    echo "DHCP router    : $(grep -h 'option routers' "$DHCP_ROUTER_INC" 2>/dev/null || echo '- (install?)')"
    echo "TOPSOFT_PRE    :"; iptables -w -t nat -S TOPSOFT_PRE 2>/dev/null | sed 's/^/   /' || echo "   (nincs)"
    echo "TOPSOFT_FWD/IN :"; { iptables -w -S TOPSOFT_FWD; iptables -w -S TOPSOFT_IN; } 2>/dev/null | sed 's/^/   /' || true
    echo "régi DNAT 10.1 : $(iptables-save -t nat | grep -c -- "--to-destination ${OLD_OVPN_TARGET}" || true) db"
    local t
    for t in "$OPN_IP" 1.1.1.1; do
        if ping -c1 -W2 "$t" >/dev/null 2>&1; then echo "ping $t    : OK"; else echo "ping $t    : NEM"; fi
    done
    echo "útvonal 1.1.1.1: $(ip route get 1.1.1.1 | head -1)"
}

check() {
    local pip=${PUBLIC_IP:-$(ppp_ip || true)} f
    echo "== ÉLES-mód előtti ellenőrzés (publikus IP: ${pip:-ismeretlen})"
    if [[ -n $pip ]]; then
        echo "-- Publikus IP-re kötött konfig (ÉLES módban ez az IP már nem lesz a 226.3-on!):"
        grep -rIl -- "$pip" /etc/postfix /etc/dovecot /etc/bind /etc/openvpn /etc/nginx /etc/apache2 2>/dev/null | sed 's/^/   /' || echo "   nincs"
        echo "-- Publikus IP-n figyelő socketek:"; ss -Hlntup 2>/dev/null | grep -F -- "$pip" | sed 's/^/   /' || echo "   nincs"
    fi
    echo "-- ppp0-hoz kötött INPUT szabályok (ÉLES módban a forgalom br0-n jön, a TOPSOFT_IN engedi: tcp '$PUBLIC_TCP_PORTS' udp '$PUBLIC_UDP_PORTS'):"
    iptables -w -S INPUT | grep -- "-i $PPP_IF" | sed 's/^/   /' || echo "   nincs"
    echo "-- OpenVPN 'local' direktívák:"; grep -rhE '^\s*local\s' /etc/openvpn 2>/dev/null | sed 's/^/   /' || echo "   nincs"
    echo "-- nftables natív szabályok (ha van, a TOPSOFT láncok mellett kézzel kell kezelni):"
    nft list tables 2>/dev/null | grep -vE 'ip (filter|nat|mangle|raw)$|ip6 ' | sed 's/^/   /' || true
    echo "-- DHCP include: $(grep -c "include \"$DHCP_ROUTER_INC\"" "$DHCPD_CONF" 2>/dev/null || echo 0) db a $DHCPD_CONF-ban"
    echo "-- Lease idő (javaslat: váltás előtt 1 nappal default-lease-time 600):"; grep -hE 'lease-time' "$DHCPD_CONF" | sed 's/^/   /' || true
}

export_dnat() {
    echo "# topsoft-mode.sh export-dnat  $(date '+%F %T')  gw=$SELF_IP"
    echo "# ELLENŐRIZD, mielőtt az OPNsense-re viszed! (topsoft-mode.php setup --csv ...)"
    echo "proto,dport,target,lport,src,descr"
    iptables-save -t nat | grep -- '-j DNAT' | grep -v -- 'TOPSOFT' | while IFS= read -r l; do
        [[ $l == *"-i $PPP_IF"* || $l != *" -i "* ]] || continue
        local proto dport dest src tip tport
        proto=$(grep -oP -- '-p \K\S+' <<<"$l" || echo tcp)
        dport=$(grep -oP -- '--dport \K\S+' <<<"$l" || true)
        dest=$(grep -oP -- '--to-destination \K\S+' <<<"$l" || true)
        src=$(grep -oP -- '(^| )-s \K\S+' <<<"$l" || echo any)
        [[ -n $dport && -n $dest ]] || { echo "# kihagyva (nem értelmezhető): $l"; continue; }
        tip=${dest%%:*}; tport=${dest#*:}; [[ $tport == "$dest" ]] && tport=$dport
        [[ $tip == "$OLD_OVPN_TARGET" || $dport == "$OVPN_OPN_PORT" ]] && { echo "# kihagyva (OpenVPN 11194, OPNsense saját): $l"; continue; }
        echo "$proto,${dport//:/-},$tip,${tport//:/-},${src%/32},DNAT ${proto}/${dport} -> ${tip}"
    done
    local p
    for p in $PUBLIC_TCP_PORTS; do [[ " $POSTFIX_PORTS " == *" $p "* ]] || echo "tcp,$p,$SELF_IP,$p,any,gw szolgáltatás tcp/$p"; done
    for p in $PUBLIC_UDP_PORTS; do echo "udp,$p,$SELF_IP,$p,any,gw szolgáltatás udp/$p"; done
}

do_install() {
    info "Telepítés"
    mkdir -p /etc/topsoft
    if [[ ! -f $CONF ]]; then
        sed -n '/^# ---- alapértékek/,/^IFACES_FILE=/p' "$0" | grep -v '^# ----' >"$CONF"
        ok "Konfig: $CONF (ellenőrizd: LAN_IF, PPP_PROVIDER, DHCP_SERVICE)"
    fi
    [[ $(readlink -f "$0") == /usr/local/sbin/topsoft-mode.sh ]] || command install -m 750 "$0" /usr/local/sbin/topsoft-mode.sh
    ip link show "$LAN_IF" >/dev/null 2>&1 || die "Nincs $LAN_IF interfész - javítsd a $CONF-ban"

    # DHCP include a 226-os subnet option routers helyére
    if [[ -f $DHCPD_CONF ]] && ! grep -q "include \"$DHCP_ROUTER_INC\"" "$DHCPD_CONF"; then
        local bak; bak="$DHCPD_CONF.topsoft.$(date +%Y%m%d%H%M%S)"
        cp -a "$DHCPD_CONF" "$bak"
        awk -v net="$DHCP_SUBNET" -v inc="$DHCP_ROUTER_INC" '
            $0 ~ "subnet[[:space:]]+"net"[[:space:]]" {insub=1; depth=0}
            { line=$0
              if (insub && !done && line ~ /^[[:space:]]*option[[:space:]]+routers[[:space:]]/) {
                  match(line, /^[[:space:]]*/); ind=substr(line, 1, RLENGTH)
                  print ind "# " substr(line, RLENGTH+1) "   # topsoft-mode: include-ra cserélve"
                  print ind "include \"" inc "\";"
                  done=1; next }
              print line
              if (insub) { o=gsub(/\{/,"{",line); c=gsub(/\}/,"}",line); depth+=o-c; if (depth<=0 && c>0) insub=0 } }
            END { if (!done) exit 3 }' "$bak" >"$DHCPD_CONF" || { cp -a "$bak" "$DHCPD_CONF"; die "Nem találtam 'option routers' sort a subnet $DHCP_SUBNET blokkban - add hozzá kézzel: include \"$DHCP_ROUTER_INC\";"; }
        [[ -f $DHCP_ROUTER_INC ]] || printf '# topsoft-mode.sh kezeli - kézzel ne szerkeszd\noption routers %s;\n' "$SELF_IP" >"$DHCP_ROUTER_INC"
        dhcpd -t -cf "$DHCPD_CONF" >/dev/null 2>&1 || { cp -a "$bak" "$DHCPD_CONF"; die "dhcpd -t hiba, visszaállítva ($bak)"; }
        ok "dhcpd.conf: include beillesztve (mentés: $bak)"
    elif [[ ! -f $DHCPD_CONF ]]; then
        warn "$DHCPD_CONF nincs - a DHCP router váltást kézzel kell megoldani"
    fi

    cat >/etc/systemd/system/topsoft-mode.service <<EOF
[Unit]
Description=topsoft TESZT/ELES mód alkalmazása bootkor
After=network-online.target $DHCP_SERVICE.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/topsoft-mode.sh apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable topsoft-mode.service >/dev/null 2>&1
    [[ -f $MODE_FILE ]] || echo test >"$MODE_FILE"
    ensure_chains
    ok "Telepítve. Mentett mód: $(cur_mode). Következő: topsoft-mode.sh check; topsoft-mode.sh $(cur_mode)"
}

# ---- main ---------------------------------------------------------------------
cmd=${1:-status}; shift || true
[[ ${1:-} == "-n" || ${1:-} == "--dry-run" ]] && DRY=1
case "$cmd" in
    status)      status ;;
    check)       check ;;
    export-dnat) need_root; export_dnat ;;
    install)     need_root; lock; do_install ;;
    test)        need_root; lock; mode_test ;;
    eles)        need_root; lock; mode_eles ;;
    apply)       need_root; lock; case "$(cur_mode)" in eles) mode_eles boot ;; *) mode_test ;; esac ;;
    -h|--help|help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "Ismeretlen parancs: $cmd (help)" ;;
esac

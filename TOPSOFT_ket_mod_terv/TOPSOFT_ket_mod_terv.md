# topsoft.hu – TESZT / ÉLES üzemmód, OpenVPN 11194 hibaelemzés (2026-09-28)

Elemzett konfiguráció: a legfrissebb élő export (2026-09-25 10:08, OPNsense 26.1).
A projektben lévő `empty.xml` ennél régebbi (07:21), azt csak összevetésre használtam.

| Fájl | Hol fut | Mire való |
|---|---|---|
| `opnsense/topsoft-mode.php` | OPNsense, `/root/topsoft/` | `setup` (egyszer), `test`, `eles`, `status` |
| `opnsense/eles_portforwards.csv` | OPNsense | az ÉLES mód port forwardjai (a 226.3 exportjából) |
| `gw/topsoft-mode.sh` | 192.168.226.3, `/usr/local/sbin/` | `install`, `check`, `test`, `eles`, `status`, `export-dnat` |
| `admin/topsoft-switch.sh` | admin gép (ROZSAY) | **egy paranccsal vált**, helyes sorrendben, hiba esetén visszaáll |

---

## 1. Miért nem megy az OpenVPN a 11194-es porton?

### 1.1 A fő ok: a válaszcsomag rossz forráscímmel indul (UDP multihoming)

```
Kliens (internet) ──UDP 11194──► 226.3 ppp0 [DNAT → 192.168.10.1:11194]
        ──► route 192.168.10.0/24 via 192.168.226.31 ──► OPNsense igb1 (opt7)
OpenVPN válasz: forrás = ??? 
```

- Az OPNsense OpenVPN `local` mezője üres, ezért a szerver a `0.0.0.0:11194` címen figyel.
- A FreeBSD egy ilyen, címhez nem kötött UDP socketnél a **kimenő interfész címét** teszi forrásnak.
- A válasz a default route-on (LAN_GW = 226.3) az igb1-en megy ki. A forrása így **192.168.226.31** lesz, nem az a 192.168.10.1, amelyre a kliens csomagja érkezett.
- A 226.3 conntrack a `192.168.10.1:11194` címről várja a választ. A `192.168.226.31`-ről érkezőt nem ismeri fel a DNAT párjaként, ezért nem fordítja vissza.
- A csomag így privát forrással menne ki a ppp0-n, amit a szolgáltató eldob. A kliens soha nem kap választ, a hiba „TLS handshake failed / timeout”.

**Az 1987-es port azért működik**, mert ott a szerver maga a 226.3: nincs DNAT, nincs második hop.

**Javítás:** a DNAT célja az OPNsense **azonos alhálón lévő** címe legyen, a `192.168.226.31:11194`. A kérés és a válasz így ugyanazon a címen megy, a conntrack párosítja őket. A `gw/topsoft-mode.sh test` ezt megcsinálja, a régi, 10.1-re mutató DNAT-ot pedig törli.

Ha kézzel csinálnád:
```bash
# 226.3
iptables -t nat -S PREROUTING | grep 192.168.10.1        # a régi szabály
iptables -t nat -D PREROUTING <a fenti sor -A nélkül>
iptables -t nat -I PREROUTING -i ppp0 -p udp --dport 11194 -j DNAT --to-destination 192.168.226.31:11194
iptables -I FORWARD -i ppp0 -o br0 -d 192.168.226.31 -p udp --dport 11194 -j ACCEPT
# + a perzisztens helyen is (iptables-persistent / rc.local / if-up script)
```

**Bizonyítás javítás előtt** (külső hálóról indított kapcsolattal, pl. mobilnetről):
```
OPNsense:  tcpdump -ni igb1 udp port 11194
   IN : <kliensIP>.<port> > 192.168.10.1.11194
   OUT: 192.168.226.31.11194 > <kliensIP>.<port>      <-- rossz forrás
226.3:     conntrack -L -p udp --dport 11194           -> [UNREPLIED]
```

### 1.2 További hibák, amelyek a javítás után is megakasztanák
| # | Hiba | Hatás | Javítja |
|---|---|---|---|
| a | **Az OPNsense PPPoE (opt8) engedélyezve van TESZT módban** | ugyanazzal a fix IP-s azonosítóval tárcsáz, mint a 226.3 → a szolgáltató eldobja vagy a 226.3 sessionjét bontja | `topsoft-mode.php test` |
| b | Az OPNsense VPN tunnel hálója `10.8.0.0/24` = **a 226.3 1987-es VPN-jének hálója** (a kliens 10.8.0.101-et kap) | amint az OPNsense VPN fut, a 10.8.0.0/24-re a saját tunnelje felé routol. A 226.3-VPN kliensek (RDP 30.71-re) válaszai eltűnnek. *Valószínűleg ezért működik most az 1987: az OPNsense VPN nem fut.* | `setup --renumber-vpn` → `10.18.0.0/24` |
| c | A DNS push `192.168.10.1`, de az Unbound nem figyel az opt1/openvpn interfészen | a VPN kliensnek nincs DNS-e | `setup` (az Unbound minden interfészen figyel) |
| d | Az exportban az instance `cert/ca/crl` üres, a CRL egy nem létező CA-ra mutat (`6a6095cc6a4a3`) | ha nem csak az anonimizálás miatt üres, a szerver **el sem indul** | **GUI**, lásd 5.1 |
| e | A `gw.topsoft.hu` belülről az Unbound override miatt 226.3-ra oldódik fel | belső hálóról tesztelve nincs ppp0 DNAT, a teszt félrevezető | **csak külső hálóról** tesztelj |

---

## 2. A két mód

> **Alapszabály:** a 226/24 hálón a gateway címe csak **192.168.226.31** lehet (az OPNsense 226-os lába). A `192.168.10.1` ugyanez a gép, de másik alhálón van, a 226-os kliensek nem tudják gatewayként használni.

### 2.1 Forgalmi kép
```
TESZT                                           ÉLES
Internet                                        Internet
   │ PPPoE fix IP                                  │ PPPoE fix IP
226.3 (gw) ── default GW a 226/24-nek         OPNsense opt8 ── default GW mindenkinek
   │  DHCP router = 226.3                          │  226/24: DHCP router = 226.31 (226.3 DHCP-je)
   │  DNAT 11194 → 226.31                          │  port fwd: mail/1987/… → 226.3
   ▼                                               ▼
OPNsense (226.31) ── VLAN10..60               226.3 ── default route → 226.31
   default route → 226.3                        (a régi GW-t használók hairpinje + ICMP redirect)
```

### 2.2 Mi változik váltáskor

| Elem | TESZT | ÉLES |
|---|---|---|
| **OPNsense** opt8 PPPoE | **KI** | BE |
| LAN_GW (226.3) gateway | default, prio 5, monitor 9.9.9.9 | nem default, prio 255, monitor ki (hurok ellen) |
| OPT8_PPPOE gateway | prio 10 | default, prio 5, monitor 1.1.1.1 |
| Reply-to (`disablereplyto`) | kikapcsolva | bekapcsolva |
| `[TEST]` szabályok | BE (opt7 UDP → 226.31:11194) | ki |
| `[ELES]` szabályok / port forwardok | ki | BE (opt8 11194, LAN2 → internet, SQL, WG, mail NAT, 1987 → 226.3, CSV) |
| `[ALL]` | mindig BE (10.8.0.0/24 route via LAN_GW, 226.3-VPN → DEV/INFRA) | ← |
| **226.3** PPPoE (dsl-provider) | fent, `auto` sor aktív | lebontva, `#auto` |
| default route | ppp0 | via 192.168.226.31 |
| DHCP `option routers` (226/24) | 192.168.226.3 | 192.168.226.31 |
| iptables `TOPSOFT_PRE` | DNAT 11194 → 226.31 | üres |
| `TOPSOFT_FWD` | ppp0 → 226.31:11194 accept | br0 → br0 accept (hairpin) |
| `TOPSOFT_IN` | üres | publikus portok (25/465/587/993/995, udp 1987) accept br0-n |
| VLAN route-ok (10–70, 10.18) via 226.31 | ✔ | ✔ |

### 2.3 ÉLES mód – VoIP a 226/24-en
- A telefonok maradnak a 226/24-en, a DHCP-t a 226.3 adja, és a `option routers` 192.168.226.31 lesz. Kimenetük az `[ELES] LAN2 → internet` szabályon és a `VOIP_PHONES` outbound NAT-on megy (**static port**, SIP-hez kell).
- A lease lejártáig a régi GW-t (226.3) használják. A 226.3 ezt a forgalmat a br0 hairpinnel az OPNsense-re továbbítja, és ICMP redirecttel átküldi őket a .31-re, így nincs kiesés.
- Váltás után **indítsd újra a telefonokat**, így azonnal új lease-t és új SIP regisztrációt kapnak (a NAT-kötés megváltozott).
- A `Firewall › Settings › Advanced › Firewall Optimization` beállítás marad `conservative` (hosszabb UDP timeout, VoIP-hoz jó).

---

## 3. Fizikai előfeltétel (a szoftveres váltáshoz)
A 226.3 **enp9s0** és az OPNsense **re0** portja legyen egyszerre a modem/ONT (bridge) szegmensén. Ehhez egy kis switch kell a modem LAN portja után, vagy egy dedikált VLAN a switchen. A PPPoE L2-n fut, a két gép csak felváltva tárcsáz, a scriptek garantálják, hogy egyszerre csak az egyik legyen fent. Ha ez nincs meg, váltáskor a kábelt is át kell dugni. Ilyenkor a `PPP_RELEASE_WAIT` legyen 60, és a kábelt a várakozás alatt dugd át.

---

## 4. Telepítés (egyszer)

### 4.1 226.3 (root)
```bash
install -m 750 topsoft-mode.sh /usr/local/sbin/
topsoft-mode.sh install          # /etc/topsoft/mode.conf, systemd unit, dhcpd.conf include (mentés készül)
vi /etc/topsoft/mode.conf        # LAN_IF=br0, PPP_PROVIDER=dsl-provider, DHCP_SERVICE ellenőrzése
topsoft-mode.sh check            # publikus IP-re kötött szolgáltatás? ppp0-hoz kötött INPUT szabály?
topsoft-mode.sh export-dnat > eles_portforwards.csv   # átnézni, majd az OPNsense-re másolni
topsoft-mode.sh test             # TESZT: javított DNAT (→ 226.31), a régi 10.1-es törlése
```
A `check` által jelzett tételeket ÉLES előtt kézzel rendezd:
- Postfix `inet_interfaces`, BIND `listen-on`, OpenVPN `local`, ha a publikus IP-re vannak kötve. ÉLES módban ez az IP már az OPNsense-en van.
- Egyéb, a ppp0-hoz kötött INPUT szabályok, ha a `TOPSOFT_IN` portlistája nem fedi le őket. A lista a `mode.conf` `PUBLIC_*_PORTS` változóiban állítható.

### 4.2 OPNsense (root SSH: `ssh -p 19992 root@192.168.30.1`)
```bash
mkdir -p /root/topsoft && chmod 700 /root/topsoft
# topsoft-mode.php és eles_portforwards.csv másolása ide (scp -P 19992 ...)
php /root/topsoft/topsoft-mode.php status
php /root/topsoft/topsoft-mode.php setup --mode test --renumber-vpn --dry-run   # átnézni
php /root/topsoft/topsoft-mode.php setup --mode test --renumber-vpn
php /root/topsoft/topsoft-mode.php test          # PPPoE KI, LAN_GW default -> TESZT mód tisztán
```
A `setup` a következőket csinálja. Idempotens, a második futás már nem változtat semmit.
- **Aliasok:** létrehozza az `RFC1918`, `IP_LOVAS` és `NET_VPN_226_3` aliast.
- **Új szabályok:**
  - `[TEST]` opt7 UDP → 226.31:11194;
  - `[ELES]` opt8 UDP → opt8ip:11194;
  - `[ELES]` LAN2 → !RFC1918;
  - `[ALL]` 226.3-VPN → DEV/INFRA.
- **Tagelés és javítás:**
  - WG in: forrás `any`;
  - SQL in: forrás `IP_LOVAS`;
  - VoIP szabály: `[ELES]` tag;
  - NAT 900: cél `opt8ip`, forrás `IP_LOVAS`;
  - NAT 1100: forrás any, cél `opt8ip`;
  - a GW és VOIP outbound NAT: `[ELES]` tag.
- **Törlés:** NAT 1000 (önmagára mutató, no-op).
- **Statikus route:** 10.8.0.0/24 via LAN_GW.
- **VPN és DNS:** az OpenVPN tunnel háló 10.18.0.0/24 lesz, az Unbound minden interfészen figyel, az Unbound ACL is átíródik.
- **opt8 és dnsmasq:** opt8-on MSS 1452 és bogon/private block, a dnsmasq lekerül az opt8-ról.
- **Port forwardok:** a CSV-ből tiltva jönnek létre, a duplikátumokat kihagyja.

Minden mentés új revízió lesz a *System › Configuration › History* alatt.

> A VPN kliensprofilokat nem kell újra exportálni a tunnel háló átszámozása miatt, mert a címet a szerver pusholja.

### 4.3 Admin gép
```bash
chmod +x topsoft-switch.sh
ssh-copy-id root@192.168.226.3 ; ssh-copy-id -p 19992 root@192.168.30.1
./topsoft-switch.sh status
```

---

## 5. Kézi (GUI) teendők, amelyeket a scriptek nem végeznek el

### 5.1 OpenVPN (az 1.2 d pont miatt)
1. **VPN › OpenVPN › Instances › Topsoft…:** Certificate = `Topsoft Ubuntus server`, CA = `Topsoft ca.crt`, TLS static key = `tls-crypt.key`. Ez utóbbi csak akkor, ha a kliensprofil is tls-cryptet használ. Ha nem, maradjon üres. A két oldalnak egyeznie kell.
2. **System › Trust › Revocation:** új CRL a `Topsoft ca.crt`-hez, és rendeld az instance-hoz (a mostani CRL egy nem létező CA-ra mutat).
3. Ellenőrzés: `sockstat -4l | grep 11194`, és a *VPN › OpenVPN › Log File* ne mutasson indulási hibát.

### 5.2 226.3 DHCP lease
Az első ÉLES váltás előtt 1 nappal: `default-lease-time 600; max-lease-time 1200;` a 226-os subnetben, majd a váltás után vissza.

### 5.3 Biztonsági tételek (audit v2-ből, továbbra is nyitott)
- `admins` csoport: csak root és a név szerinti adminok legyenek benne.
- LDAP bind: dedikált read-only userrel, ne `cn=admin`-nal.
- WebGUI: csak MGMT/DEV interfészen figyeljen, legyen TOTP, és a DNS rebind check legyen bekapcsolva.
- SSH: a root login legyen tiltva, ha a `rozsay` user kulcsos belépése kész. Ekkor az orchestrátorban `OPN_SSH=rozsay@…`, és sudo kell.
- Redis: csak `lo0`-n figyeljen.
- A WG kulcsokat cserélni kell.
- A 261-es szabály (a teljes 226/24 → tűzfal) túl tág.
- Unbound ACL: default deny.

---

## 6. Váltás

```bash
./topsoft-switch.sh eles --dry-run     # mindkét gépen csak kiírja, mit tenne
./topsoft-switch.sh eles               # TESZT -> ÉLES
./topsoft-switch.sh test               # ÉLES -> TESZT
```
- **ÉLES irányban:** először a 226.3 PPPoE-ja bomlik le, a DHCP router átáll, a default route a .31 lesz. `PPP_RELEASE_WAIT` (15 mp) várakozás után az OPNsense-en feljön a PPPoE, és a gép `rc.reload_all`-t futtat. Ha 90 mp alatt nincs IP, **automatikusan visszaáll TESZT módra**.
- **TESZT irányban:** fordított a sorrend, hiba esetén vissza ÉLES módra.
- Kiesés: kb. 1–3 perc. Mindkét gépen reboot-álló: a 226.3 systemd unitja és az `auto` sor, az OPNsense-en a config.
- Egy gépen külön is futtatható: `topsoft-mode.sh eles|test` a 226.3-on, `php topsoft-mode.php eles|test` az OPNsense-en. **A sorrendet ilyenkor tartsd be**, hogy egyszerre ne legyen két PPPoE session.

---

## 7. Ellenőrző lista

| Teszt | TESZT | ÉLES |
|---|---|---|
| OpenVPN 11194, **külső hálóról** | ✔ (a 226.3 DNAT-ján át) | ✔ (közvetlenül) |
| OpenVPN 1987 (226.3), RDP 226.25 és 30.71 felé | ✔ | ✔ (port fwd) |
| `tcpdump -ni igb1 udp port 11194`: válasz forrása 192.168.226.31 | ✔ | – |
| DEV (30.71) → internet, `tracert 1.1.1.1` 2. hop | 226.3 | PPPoE |
| VoIP telefon hívás ki és be, a telefon újraindítása után | ✔ | ✔ |
| Bejövő levél (a 25-ös port kívülről) | ✔ | ✔ (NAT 1100) |
| `topsoft-switch.sh status`: mindkét gép ugyanazt a módot mutatja | ✔ | ✔ |

**Visszaállítás, ha valami elromlik:**
- OPNsense: *System › Configuration › History*, a `topsoft-mode setup/test/eles` előtti revízió.
- 226.3: a `dhcpd.conf.topsoft.*` mentés és a `topsoft-mode.sh test`.
- Napló: `/var/log/topsoft-mode.log` a 226.3-on, `topsoft-switch_*.log` az admin gépen.

---

## 8. Élesítés előtt, egyszer ellenőrizendő (verziófüggő viselkedés)
- Az OPNsense-en `rc.reload_all` után a letiltott opt8 PPPoE valóban lebomlik-e. A script előtte kifejezetten bontja is (`interface_bring_down` + mpd pid). Ha a `status` mégis PPPoE IP-t mutat TESZT módban: *Interfaces › OPT8_PPPOE › Enable* ki.
- A 226.3-on a PPPoE ifupdown `auto dsl-provider` sorral indul-e. Ha systemd/netplan indítja, a `check` jelzi, és a boot-autostartot kézzel kell kezelni.
- Ha a 226.3-on natív nftables szabálykészlet fut (nem iptables-nft), a `TOPSOFT_*` láncok mellett a saját szabályokat is igazítani kell (a `check` listázza).

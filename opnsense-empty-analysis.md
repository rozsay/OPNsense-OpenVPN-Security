# `empty.xml` elemzés – OPNsense multi-VLAN / dual-mode

## Kiindulási topológia

Az `/home/runner/work/OPNsense-OpenVPN-Security/OPNsense-OpenVPN-Security/empty.xml` alapján az aktív L3 szegmensek:

- VLAN10 / MGMT: `192.168.10.1/24`
- VLAN20 / Server: `192.168.20.1/24`
- VLAN30 / Dev: `192.168.30.1/24`
- VLAN40 / Office: `192.168.40.1/24`
- VLAN50 / Voice: `192.168.50.1/24`
- VLAN60 / IoT: `192.168.60.1/24`
- Upstream / LAN2: `192.168.226.31/24`
- PPPoE interface: `opt8/pppoe0`

A jelenlegi teszt mód gateway-je a `LAN_GW = 192.168.226.3`, miközben a PPPoE gateway is elő van készítve (`OPT8_PPPOE_PPPOE`).

## Kritikus biztonsági hiányosságok

### 1. Admin felületek és lokális hitelesítés

- A WebGUI nincs interfészre szűkítve (`<interfaces />`), ezért minden engedélyezett lokális felületről elérhető.
- SSH engedélyezett, root login és jelszavas auth is aktív.
- A konfigurációban több lokális felhasználó maradt aktív; ez növeli a jelszó- és jogosultsági felületet.
- A `LAN2` oldalon egy nagyon tág ideiglenes self-access szabály látható.

**Hatás:** admin támadási felület túl széles, laterális mozgás könnyebb.

### 2. Titkos kulcsok / shared secret-ek a konfigurációban

- LDAP bind account szerepel a konfigurációban.
- WireGuard private key jelen van a configban.
- Több certificate private key és API/OTP adat is a mentés részét képezi.
- SNMP community `public`.

**Hatás:** config backup kiszivárgása egyben credential kompromittáció.

### 3. Túl megengedő vagy ideiglenes szabályok

- `opt7` (192.168.226.0/24) felől van általános, self felé nyitott szabály.
- Több szabály leírása hiányzik vagy átmeneti jellegű.
- A meglévő aliasok és szabályleírások nem egységesek.

### 4. VPN és menedzsment szeparáció hiányosságai

- OpenVPN-ből nincs explicit hozzáférés a MGMT VLAN-hoz.
- OpenVPN push route listából hiányzik `192.168.10.0/24`.
- WireGuard interface csoport és szerver szét van választva, de a hozzáférési modell nincs lezárva VLAN-szinten.

## OpenVPN 11194 probléma – valós gyökérok

## Elsődleges ok

Az OpenVPN instance az `empty.xml` alapján:

- `proto = udp4`
- `port = 11194`
- `server = 10.8.0.0/24`

Vagyis az OPNsense **UDP/11194**-en figyel, miközben a hibaleírás szerinti Ubuntu oldali forward **TCP/11194**. Ez protokoll-mismatch.

## Másodlagos okok

### 1. Rossz upstream cél IP

A forward jelenleg `11194 -> 192.168.10.1:11194` irányba van megadva. Teszt módban egyszerűbb és robusztusabb:

```text
11194/UDP -> 192.168.226.31:11194/UDP
```

Mivel ez az OPNsense upstream / directly reachable címe, nem kell a management VLAN címére DNAT-olni.

### 2. A kliens kap IP-t, de a szerver/MGMT nem érhető el

Ez az `empty.xml` szerint logikus, mert:

- push route van: `192.168.30.0/24, 192.168.40.0/24, 192.168.20.0/24, 192.168.226.0/24`
- **nincs** push route: `192.168.10.0/24`
- az OpenVPN interface szabály engedi a `self,opt2,opt3,opt7,openvpn` célokat
- **nem** engedi explicit az `opt1` / MGMT hozzáférést

Következmény:

- a tunnel felépülhet,
- a kliens megkaphatja a `10.8.0.101` címet,
- de a `192.168.10.1` / MGMT hálózat továbbra sem lesz elérhető.

### 3. Return path / state kezelés

Teszt módban a default gateway a `192.168.226.3`, ezért ellenőrizni kell:

- Ubuntu DNAT/SNAT szabály valóban **UDP**-re készült-e,
- az Ubuntu gépen a VLAN-ok felé van-e útvonal `via 192.168.226.31`,
- az OPNsense OpenVPN, filter és gateway policy nem kényszeríti-e rossz irányba a választ.

## Mi szükséges a működő OPNsense OpenVPN-hez teszt módban

1. Ubuntu oldali port-forward legyen **UDP/11194**.
2. Cél IP legyen inkább `192.168.226.31`, ne `192.168.10.1`.
3. OPNsense oldalon maradjon pass szabály az upstream interfészen a bejövő UDP/11194-re.
4. OpenVPN push route kapja meg a `192.168.10.0/24` hálózatot is, ha a MGMT-ot el kell érni.
5. OpenVPN interface szabályban legyen külön MGMT access policy.
6. Szükség esetén outbound NAT vagy explicit route legyen a `10.8.0.0/24` válaszútra.

## VLAN-onkénti ajánlott biztonsági modell

### MGMT / VLAN10
- csak admin workstation + VPN admin csoport
- WebGUI/SSH/API csak innen
- nincs általános internet, csak frissítés/DNS/NTP

### Server / VLAN20
- belső szolgáltatás-export
- csak szükséges portok Office/Dev felé
- internet egress minimális

### Dev / VLAN30
- internet mehet, de RFC1918 laterális hozzáférés csak célzottan
- RDP/SMB/SSH csak explicit allow

### Office / VLAN40
- teljes internet
- belső elérés csak publikált szolgáltatásokra

### Voice / VLAN50
- DHCP, DNS, NTP, SIP/RTP, provisioning only
- nincs admin és nincs általános laterális forgalom

### IoT / VLAN60
- csak DNS/NTP és szükséges célhostok
- blokkolt admin- és szerverelérés alapértelmezésként

### Upstream / 192.168.226.0/24
- csak gateway, monitoring, migrációs és break-glass hozzáférés
- az ideiglenes full self-access szabály megszüntetendő

### OpenVPN / WireGuard
- külön ACL csoportok
- VPN felől ne legyen implicit access minden belső hálózatra

## Dual-mode összegzés

### TESZT MÓD
- default GW: `192.168.226.3`
- OPNsense internet policy route/group: `GW_FAILOVER`
- Ubuntu végzi az internet kijáratot és a külső VPN DNAT-ot

### ÉLES MÓD
- PPPoE legyen elsődleges default gateway
- `192.168.226.3` maradjon fallback vagy karbantartási útvonal
- VoIP DHCP maradhat relay-jelleggel vagy átvihető OPNsense-re

## Konkrét optimalizálások

1. WebGUI limit csak MGMT + dedikált VPN admin access.
2. SSH: root login tiltás, password auth tiltás, csak kulcs + TOTP.
3. LDAP: külön read-only bind user, secret rotate, LDAPS/CA pinning.
4. WireGuard kulcsok és SNMP community azonnali rotációja.
5. Alias és szabályelnevezés egységesítése:
   - `ALI_NET_*`
   - `ALI_HOST_*`
   - `ALI_PORT_*`
   - rule descr: `[AI-Gen] ...`
6. OpenVPN route/firewall bővítés a MGMT hozzáféréshez csak szükség esetén.
7. Temporary `LAN2` admin rule kiváltása célzott management ACL-lel.

## Kötelező ellenőrzések változtatás előtt

> Figyelem: anti-lockout elérés elveszhet, ha a menedzsment interfész- vagy GUI-korlátot rossz interfészre teszed.

- Mentés: `/conf/config.xml`
- Path: `System` -> `Configuration` -> `Backups`
- API módosítás után apply/reconfigure szükséges:
  - `/api/firewall/filter/apply`
  - releváns VPN/interface service reconfigure endpoint


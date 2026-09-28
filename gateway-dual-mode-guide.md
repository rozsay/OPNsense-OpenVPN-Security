# Gateway dual-mode guide – TESZT ↔ ÉLES

> Figyelem: interfész- vagy default gateway váltás előtt mindig készíts mentést a `/conf/config.xml` fájlról.

## Cél

A váltás két mód között történik:

- **TESZT MÓD**: internet kijárat a `192.168.226.3` Ubuntu gateway-en keresztül
- **ÉLES MÓD**: közvetlen PPPoE kijárat az OPNsense-en

## Jelenlegi `empty.xml` állapot

- `LAN_GW = 192.168.226.3` default gateway
- `OPT8_PPPOE_PPPOE` már definiált
- gateway group: `GW_FAILOVER`
- külön group: `PPPOE_MODE`

Ez jó alap, mert az XML már tartalmazza mindkét gateway-elemet.

## TESZT MÓD célállapot

```text
OPNsense default GW: 192.168.226.3
Ubuntu 192.168.226.3: internet kijárat + VPN DNAT
PPPoE: előkészítve, de nem elsődleges
```

### Követelmények

- OPNsense default gateway: `LAN_GW`
- Ubuntu route a VLAN-ok felé `via 192.168.226.31`
- OpenVPN DNAT: `UDP/11194 -> 192.168.226.31:11194`
- Voice DHCP vagy relay maradjon konzisztens a topológiával

## ÉLES MÓD célállapot

```text
OPNsense default GW: PPPoE
Ubuntu 192.168.226.3: fallback / secondary
PPPoE: elsődleges internet
```

### Követelmények

- PPPoE gateway legyen elsődleges
- `192.168.226.3` csak fallback/maintenance
- WAN oldali OpenVPN publikálás közvetlenül OPNsense-ről történjen

## Ajánlott átállási sorrend

## TESZT -> ÉLES

1. Mentés készítése.
2. Ubuntu-n töröld a 11194 DNAT-ot.
3. Path: `Interfaces` -> `Point-to-Point` -> `Devices` -> ellenőrizd a PPPoE credentialt.
4. Path: `System` -> `Gateways` -> `Configuration` -> `OPT8_PPPOE_PPPOE` legyen preferált.
5. Path: `Firewall` -> `Rules` -> ellenőrizd a policy-routing szabályokat, amelyek még `GW_FAILOVER`-ra mutatnak.
6. Path: `Firewall` -> `NAT` -> `Outbound` -> legyen megfelelő internet NAT a PPPoE/WAN felé.
7. Path: `Firewall` -> `Rules` -> `WAN/OPT8` -> vedd fel az OpenVPN WAN allow szabályt közvetlenül az OPNsense-re.
8. Apply / reconfigure.

## ÉLES -> TESZT

1. Mentés készítése.
2. OPNsense default route vissza `LAN_GW` felé.
3. Ubuntu oldalon route-ok és OpenVPN DNAT visszaállítása.
4. PPPoE maradhat standby/fallback.
5. Apply / state ellenőrzés.

## OPNsense API / reconfigure megjegyzés

REST API módosítások után mindig kell apply/reconfigure. Minimum:

```bash
curl -k -u "$OPN_KEY:$OPN_SECRET" \
  -H "Content-Type: application/json" \
  -X POST "https://$OPN_HOST/api/firewall/filter/apply"
```

Szükség szerint futtasd a kapcsolódó gateway / interface / openvpn reconfigure hívást is.

## Voice DHCP javaslat

A Voice VLAN-ra két stabil modell van:

### A. Teszt módban Ubuntu ad DHCP-t
- OPNsense csak L3/VLAN gateway
- szükség esetén DHCP relay vagy helper kell

### B. Éles módban OPNsense ad DHCP-t
- egyszerűbb üzemeltetés
- VoIP option-ök közvetlenül a VLAN50 scope-ban kezelhetők

Ha a topológia marad vegyes üzemű, akkor a relay beállítás legyen külön dokumentált és ne maradjon implicit broadcast-függő állapotban.

## Ellenőrzési lista

- `netstat -rn4` / `route -n get default`
- PPPoE link state
- OpenVPN 11194/UDP elérés
- Office/Dev/Server internet kijárat
- Voice DHCP lease
- DNS feloldás VLAN-onként

## Script

A repo rootban lévő `gateway-switch.sh` egy biztonságos váltó-orchestration minta. Alapértelmezésben **dry-run**, és csak `--apply` esetén hajt végre változtatásokat.


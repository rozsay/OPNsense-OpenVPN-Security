# OpenVPN 11194 port forward javítás

## Rövid diagnózis

Az OPNsense OpenVPN szerver az `empty.xml` szerint **UDP/11194**-en figyel, ezért a `192.168.226.3` oldali **TCP/11194** forward hibás.

## Miért kap a kliens mégis `10.8.0.101` címet?

Mert a tunnel felépülhet az OPNsense OpenVPN instance felé, viszont a belső elérés utána még elbukhat:

- hiányzó `192.168.10.0/24` push route,
- hiányzó MGMT-access szabály az OpenVPN interfészen,
- nem megfelelő upstream DNAT cél (`192.168.10.1` helyett jobb a `192.168.226.31`),
- teszt mód miatti return-path/policy-routing mellékhatás.

## Ajánlott fix

## 1. Ubuntu gateway oldali DNAT

A port forward legyen:

```text
UDP/11194 -> 192.168.226.31:11194
```

Nem javasolt a `192.168.10.1` cél, mert az a MGMT interfész címe, nem az upstreamen natívan látható OPNsense-cím.

Példa nftables:

```bash
nft add rule ip nat prerouting iifname "pppoe0" udp dport 11194 dnat to 192.168.226.31:11194
```

Példa iptables:

```bash
iptables -t nat -A PREROUTING -i pppoe0 -p udp --dport 11194 -j DNAT --to-destination 192.168.226.31:11194
```

Standard Ubuntu DNAT+FORWARD esetben az OPNsense az `opt7` oldalon jellemzően a **`192.168.226.3` Ubuntu gatewayt fogja forrásként látni**, ezért az OPNsense upstream firewall szabályt ehhez a hophoz kell igazítani. Teszt módban továbbra is szükséges, hogy az OPNsense válaszútja a `192.168.226.3` felé menjen vissza, különben aszimmetrikus lehet a flow.

## 2. OPNsense upstream firewall ellenőrzés

Path: `Firewall` -> `Rules` -> `LAN2` -> `Add`

Szükséges szabály:

```text
Action: Pass
Protocol: UDP
Source: 192.168.226.3/32 vagy any
Destination: This Firewall (self)
Destination Port: 11194
Description: [AI-Gen] Allow OpenVPN from upstream gateway - Port forward 11194
```

## 3. OpenVPN instance ellenőrzés

Path: `VPN` -> `OpenVPN` -> `Instances` -> `Servers`

Ellenőrizendő:

- Protocol: `UDP IPv4`
- Port: `11194`
- Local port export preset is `11194`
- Local bind üresen hagyható vagy explicit `192.168.226.31`

## 4. Route propagation javítása

Ha a VPN kliensnek a MGMT hálózat is kell:

```text
push_route: 192.168.10.0/24,192.168.20.0/24,192.168.30.0/24,192.168.40.0/24,192.168.226.0/24
```

## 5. OpenVPN interface access control

Path: `Firewall` -> `Rules` -> `OpenVPN` -> `Add`

Adj külön szabályt a MGMT eléréshez csak admin VPN csoportnak:

```text
Action: Pass
Protocol: TCP
Source: OpenVPN net
Destination: 192.168.10.0/24
Destination Port: 443,22,8443,19992
Description: [AI-Gen] Allow VPN admins to MGMT - OpenVPN mgmt access
```

## 6. Return path ellenőrzés

Az OPNsense oldalon ellenőrizd, hogy a válaszcsomagok nem kerülnek-e rossz gateway groupra.

Teszt parancsok:

```bash
sockstat -4 -l | grep 11194
netstat -rn4 | grep default
clog /var/log/filter/filter_$(date +%F).log | grep 11194
```

Ubuntu oldalon:

```bash
ip route
conntrack -L -p udp | grep 11194
```

## 7. Mit kell látnod működő állapotban?

- Ubuntu WAN-on bejön `UDP/11194`
- DNAT megy `192.168.226.31:11194` felé
- OPNsense OpenVPN hallgat a 11194/UDP porton
- kliens kap `10.8.0.x` címet
- kliens route táblájában megjelenik a szükséges belső hálózat
- OPNsense Live View-ban nincs state violation a válaszokra

## Minimális hibamentes verzió

1. TCP forward törlése
2. UDP forward felvétele
3. cél IP csere `192.168.10.1` -> `192.168.226.31`
4. MGMT route + OpenVPN MGMT policy hozzáadása, ha a `192.168.10.1`-et is el kell érni


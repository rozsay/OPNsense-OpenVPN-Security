# OpenVPN Maximum Security Implementation Guide - OPNsense

## 📖 Teljes Implementációs Útmutató

---

## 1️⃣ Fázis: Előfeltételek és Tervezés

### 1.1 Rendszerkövetelmények

```
OPNsense verzió:     24.1.x vagy újabb
Kernel:             FreeBSD 13.2+
RAM:                Minimum 2GB (ajánlott 4GB)
Tárhely:            1GB szabad terület
Processz:           Minimum 2 mag
```

### 1.2 Portok és Hálózat

```
OpenVPN Port:       1194 UDP (alapértelmezett)
Alternatív:         443 TCP (tűzfal elkerüléshez)
MTU:                1500 (ajánlott: 1480)
Subnet:             192.168.30.0/24 (dev hálózat alapján)
VPN Range:          10.8.0.0/24 (OpenVPN default)
```

### 1.3 Tanúsítványok - Szükséges fájlok

```
ca.crt              - Certificate Authority
ca.key              - CA privát kulcs (SZUPER TITKOS!)
server.crt          - Szerver tanúsítvány
server.key          - Szerver privát kulcs
dh.pem              - Diffie-Hellman paraméterek (4096-bit)
ta.key              - TLS Auth key (stateless firewall elkerüléshez)
```

---

## 2️⃣ Fázis: Tanúsítványok Generálása

### 2.1 Easy-RSA Telepítés

```bash
# SSH-val csatlakozz az OPNsense-hez
ssh root@192.168.226.31

# Easy-RSA letöltése
cd /tmp
fetch https://github.com/OpenVPN/easy-rsa/releases/download/v3.1.7/EasyRSA-3.1.7.tgz
tar xzf EasyRSA-3.1.7.tgz
cd EasyRSA-3.1.7

# Inicializálás
./easyrsa init-pki
```

### 2.2 Certificate Authority (CA) Generálása

```bash
# CA létrehozása (interaktív - jelszót kér)
./easyrsa build-ca

# Output:
# CA certificate: /tmp/EasyRSA-3.1.7/pki/ca.crt
# CA key: /tmp/EasyRSA-3.1.7/pki/private/ca.key
```

### 2.3 Szerver Tanúsítvány és Privát Kulcs

```bash
# Szerver certificate request
./easyrsa gen-req server nopass

# Szerver tanúsítvány aláírása
./easyrsa sign-req server server

# Output:
# Szerver cert: /tmp/EasyRSA-3.1.7/pki/issued/server.crt
# Szerver key: /tmp/EasyRSA-3.1.7/pki/private/server.key
```

### 2.4 Diffie-Hellman Paraméterek (4096-bit)

```bash
# ⚠️ FIGYELEM: Ez 10-20 percig tarthat!
./easyrsa gen-dh

# Output:
# DH: /tmp/EasyRSA-3.1.7/pki/dh.pem
```

### 2.5 TLS Auth Kulcs (Firewall Elkerüléshez)

```bash
# TLS Auth key generálása (opcionális de ajánlott)
openvpn --genkey --secret ta.key

# Output:
# ta.key - Firewall elkerülési kulcs
```

### 2.6 Kliens Tanúsítványok

```bash
# Kliens certificate request
./easyrsa gen-req client1 nopass

# Kliens tanúsítvány aláírása
./easyrsa sign-req client client1

# Output:
# Kliens cert: /tmp/EasyRSA-3.1.7/pki/issued/client1.crt
# Kliens key: /tmp/EasyRSA-3.1.7/pki/private/client1.key

# Plusz kliensek (szükség szerint)
./easyrsa gen-req client2 nopass
./easyrsa sign-req client client2
./easyrsa gen-req client3 nopass
./easyrsa sign-req client client3
```

### 2.7 Tanúsítványok Másolása az OPNsense Cert Manager-be

```bash
# OPNsense WebUI -> System > Certificates > Authorities
# - CA tanúsítvány feltöltése (ca.crt)

# OPNsense WebUI -> System > Certificates > Certificates
# - Szerver tanúsítvány feltöltése (server.crt)
# - Szerver kulcs feltöltése (server.key)
```

---

## 3️⃣ Fázis: OPNsense OpenVPN Szerver Konfiguráció

### 3.1 WebUI Navigáció

```
VPN > OpenVPN > Instances > Servers > Add Server
```

### 3.2 Szerver Alapbeállítások

| Beállítás | Érték | Leírás |
|-----------|-------|--------|
| **Disabled** | ☐ | Engedélyezve |
| **Protocol** | UDP | Gyorsabb (TCP ha falak blokkolnak) |
| **Port** | 1194 | Standard port |
| **IPv4 Tunnel Network** | 10.8.0.0 | VPN szubnet |
| **IPv4 Local Network(s)** | 192.168.226.0/24,192.168.20.0/24,192.168.30.0/24 | Elérhető hálózatok |
| **IPv6** | ☐ | IPv6 támogatás |

### 3.3 Titkosítás és Biztonsági Beállítások

```xml
<!-- OPNsense XML konfig részlet -->
<crypto>
    <cipher>AES-256-GCM</cipher>           <!-- 256-bit AES AEAD -->
    <auth>SHA256</auth>                     <!-- Auth HMAC -->
    <dh_bits>4096</dh_bits>                 <!-- DH paraméter -->
    <tls_version>1.3</tls_version>          <!-- TLS 1.3 mandatory -->
    <tls_ciphers>TLS_AES_256_GCM_SHA384</tls_ciphers>
    <tls_ciphersuites>TLS_CHACHA20_POLY1305_SHA256</tls_ciphersuites>
    <ecdh_curve>secp384r1</ecdh_curve>      <!-- ECDH curve -->
    <pfs_enabled>1</pfs_enabled>            <!-- Perfect Forward Secrecy -->
    <renegotiate_seconds>3600</renegotiate_seconds>  <!-- 1 óra -->
</crypto>
```

### 3.4 TLS 1.3 Konfigurálás

```bash
# OPNsense WebUI -> VPN > OpenVPN > Instances > Servers > [Edit]
# Advanced Options -> Compression
# - Compression: Disabled (LZ4 támadásvektort nyit)

# Custom Options (Advanced)
# Paste the following:
tls-version 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
ecdh-curve secp384r1
renegotiate 3600
```

### 3.5 mTLS és Certificaate Pinning

```bash
# Custom Options (Advanced) - folytatás
# Mutual TLS authentication
tls-server
tls-auth ta.key 0

# Server authentication
require-certificate-verification

# Certificate pinning (kliens tanúsítványok ellen)
verify-x509-name server name
```

### 3.6 Keepalive és Reconnect

```bash
# Custom Options (Advanced) - folytatás
keepalive 10 120
connect-retry 3 5
explicit-exit-notify 1
```

### 3.7 Telemetria és Naplózás

```bash
# Custom Options (Advanced) - folytatás
status /var/log/openvpn/status.log
log /var/log/openvpn/openvpn.log
verb 4
```

---

## 4️⃣ Fázis: Kliens Konfiguráció

### 4.1 Kliens .OVPN Fájl Generálása

```bash
# SSH az OPNsense-hez és fájl összeállítás
cat > /tmp/client1.ovpn <<'EOF'
client
proto udp
remote firewall.local 1194
resolv-retry infinite
nobind
persist-key
persist-tun

# Titkosítás
cipher AES-256-GCM
auth SHA256
tls-version 1.3
tls-ciphersuites TLS_AES_256_GCM_SHA384
ecdh-curve secp384r1

# Biztonsági beállítások
key-direction 1
remote-cert-tls server
verify-x509-name server name

# Keepalive
keepalive 10 120
connect-retry 3 5
explicit-exit-notify 1

# Naplózás
verb 4
log openvpn.log
status status.log

# Tanúsítványok (inline)
<ca>
-----BEGIN CERTIFICATE-----
[ca.crt tartalom]
-----END CERTIFICATE-----
</ca>

<cert>
-----BEGIN CERTIFICATE-----
[client1.crt tartalom]
-----END CERTIFICATE-----
</cert>

<key>
-----BEGIN PRIVATE KEY-----
[client1.key tartalom]
-----END PRIVATE KEY-----
</key>

<tls-auth>
-----BEGIN OpenVPN Static key V1-----
[ta.key tartalom]
-----END OpenVPN Static key V1-----
</tls-auth>

# VPN routing
route 192.168.226.0 255.255.255.0
route 192.168.20.0 255.255.255.0
route 192.168.30.0 255.255.255.0

# Leállítási opciók
script-security 2
EOF
```

### 4.2 Kliens Tanúsítványok Beépítése

```bash
# Fájlok beillesztése az .OVPN fájlba
cat /tmp/EasyRSA-3.1.7/pki/ca.crt >> /tmp/client1.ovpn
cat /tmp/EasyRSA-3.1.7/pki/issued/client1.crt >> /tmp/client1.ovpn
cat /tmp/EasyRSA-3.1.7/pki/private/client1.key >> /tmp/client1.ovpn
cat /tmp/ta.key >> /tmp/client1.ovpn
```

---

## 5️⃣ Fázis: Tűzfal Szabályok

### 5.1 Bejövő Szabályok (WAN)

```xml
<!-- Firewall Rules > Inbound -->
<rule uuid="openvpn-wan-udp">
  <type>pass</type>
  <interface>wan</interface>
  <ipprotocol>inet</ipprotocol>
  <protocol>udp</protocol>
  <source>
    <any>1</any>
  </source>
  <destination>
    <network>wanip</network>
    <port>1194</port>
  </destination>
  <descr>OpenVPN UDP 1194</descr>
  <quick>1</quick>
</rule>
```

### 5.2 OpenVPN Interface Szabályok

```xml
<!-- Firewall Rules > OpenVPN Interface -->
<rule uuid="openvpn-interface-allow">
  <type>pass</type>
  <interface>openvpn</interface>
  <ipprotocol>inet</ipprotocol>
  <statetype>keep state</statetype>
  <source>
    <any>1</any>
  </source>
  <destination>
    <any>1</any>
  </destination>
  <descr>Allow All OpenVPN Traffic</descr>
</rule>
```

### 5.3 NAT Szabályok (kliens -> belső hálózat)

```xml
<!-- NAT Rules > Outbound -->
<rule>
  <protocol>all</protocol>
  <source>
    <network>10.8.0.0/24</network>
  </source>
  <destination>
    <any>1</any>
  </destination>
  <interface>wan</interface>
  <target>wanip</target>
  <descr>OpenVPN NAT Outbound</descr>
  <staticnatport>0</staticnatport>
</rule>
```

---

## 6️⃣ Fázis: CrowdSec Integrálás (IDS/IPS)

### 6.1 CrowdSec Engedélyezése

```bash
# OPNsense WebUI -> Services > CrowdSec > General
# - Agent Enabled: ✓
# - LAPI Enabled: ✓
# - Firewall Bouncer Enabled: ✓
```

### 6.2 OpenVPN Naplók Monitorozása

```bash
# SSH az OPNsense-hez
vim /usr/local/etc/crowdsec/acquis.d/openvpn.yaml

# Konfig:
---
source: file
filenames:
  - /var/log/openvpn/openvpn.log
labels:
  type: openvpn
```

### 6.3 CrowdSec Riasztások Ellenőrzése

```bash
# Gyanús aktivitások
cscli alerts list

# Blokk lista
cscli decisions list

# Eltávolítás
cscli decisions delete --id <ID>
```

---

## 7️⃣ Fázis: Monitorozás és Naplózás

### 7.1 OpenVPN Naplók

```bash
# Live naplók
tail -f /var/log/openvpn/openvpn.log

# OpenVPN státusz
tail -f /var/log/openvpn/status.log

# Csatlakozottak listája
grep "CONNECT" /var/log/openvpn/openvpn.log | tail -20
```

### 7.2 Syslog Konfigurálás

```xml
<!-- OPNsense WebUI -> System > Logging > Settings -->
<syslog>
  <enabled>1</enabled>
  <loglocal>1</loglocal>
  <maxpreserve>31</maxpreserve>
  <maxfilesize>10485760</maxfilesize>
  <facilities>
    <local3>openvpn</local3>
  </facilities>
</syslog>
```

### 7.3 Syslog Nézegető

```bash
# Összes OpenVPN üzenet
grep "openvpn" /var/log/messages

# Hiba nyomozás
grep "error\|ERROR" /var/log/openvpn/openvpn.log
```

---

## 8️⃣ Fázis: Kliens Csatlakozás Tesztelése

### 8.1 Linux/macOS Kliens

```bash
# Csatlakozás
sudo openvpn --config client1.ovpn

# Valós idejű naplók
sudo openvpn --config client1.ovpn --verb 6

# Leválasztás
Ctrl+C
```

### 8.2 Windows Kliens

```powershell
# OpenVPN GUI telepítése
choco install openvpn

# Fájl másolása
Copy-Item client1.ovpn "C:\Users\User\AppData\Roaming\OpenVPN\config\"

# OpenVPN GUI-ből csatlakozás
Right-click Tray Icon > Connect
```

### 8.3 Csatlakozás Ellenőrzése

```bash
# Nyilvános IP ellenőrzése
curl https://api.ipify.org

# VPN csatlakozás státusza
ifconfig tun0 (Linux/macOS)
ipconfig /all (Windows - TAP-Win32 adapter)

# Routing
route -n | grep 10.8 (Linux)
route print (Windows)
```

---

## 9️⃣ Fázis: Automatikus Tanúsítványrotáció

### 9.1 Cron Job Beállítása

```bash
# OPNsense SSH-val
crontab -e

# Hozzáadás (évente frissítés)
0 0 1 1 * /root/renew-openvpn-certs.sh
```

### 9.2 Tanúsítványfrissítés Script

```bash
#!/bin/bash
# /root/renew-openvpn-certs.sh

cd /tmp/EasyRSA-3.1.7

# Szerver tanúsítványok frissítése
./easyrsa renew server

# Kliensek frissítése
./easyrsa renew client1
./easyrsa renew client2
./easyrsa renew client3

# OPNsense frissítése
# Manuálisan vagy API-n keresztül

logger -t openvpn-renewal "Certificates renewed successfully"
```

---

## 🔟 Fázis: Biztonsági Ellenőrzés

### 10.1 TLS Ellenőrzés

```bash
# OpenSSL tesztelés
echo | openssl s_client -connect firewall.local:1194 -tls1_3

# Cipher suites
nmap --script ssl-enum-ciphers -p 1194 firewall.local
```

### 10.2 Tanúsítványok Validálása

```bash
# Szerver tanúsítvány érvényessége
openssl x509 -in /var/db/openvpn/server.crt -text -noout | grep -A2 "Validity"

# Privát kulcs ellenőrzése
openssl rsa -in /var/db/openvpn/server.key -check

# CA tanúsítvány ellenőrzése
openssl verify -CAfile ca.crt server.crt
```

### 10.3 Firewall Szabályok Ellenőrzése

```bash
# Aktív szabályok
pfctl -s rules | grep -i openvpn

# NAT szabályok
pfctl -s nat | grep -i openvpn

# Aktív kapcsolatok
netstat -an | grep 1194
```

---

## 🔐 Biztonsági Ellenőrzőlista

- [ ] TLS 1.3 engedélyezve
- [ ] AES-256-GCM titkosítás aktív
- [ ] mTLS konfigurálva
- [ ] Perfect Forward Secrecy engedélyezve
- [ ] Tanúsítvány pinning aktív
- [ ] CrowdSec integrálva
- [ ] Firewall szabályok szigorúak
- [ ] Naplózás engedélyezve
- [ ] Tanúsítványok érvényes
- [ ] Privát kulcsok biztonságban

---

## 🆘 Hibaelhárítás

### "Connection refused"

```bash
# OpenVPN szolgáltatás ellenőrzése
service openvpn status

# Port ellenőrzése
netstat -an | grep 1194

# Tűzfal szabályok
pfctl -s rules | grep openvpn
```

### "TLS handshake failed"

```bash
# Tanúsítványok validálása
openssl verify -CAfile ca.crt client1.crt

# Privát kulcs illesztése
openssl x509 -in server.crt -noout -modulus | md5
openssl rsa -in server.key -noout -modulus | md5
```

### "Certificate verification failed"

```bash
# Certificate pinning ellenőrzése
grep "verify-x509-name" /etc/openvpn/server.conf

# TA kulcs szinkronizálása
diff ta.key client1.ovpn
```

---

## 📚 Referenciák

- [OpenVPN Security](https://openvpn.net/community-resources/hardening-openvpn-security/)
- [OPNsense VPN](https://docs.opnsense.org/manual/vpn.html)
- [NIST Cryptography Guidelines](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-175B.pdf)
- [OWASP TLS Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Protection_Cheat_Sheet.html)

---

**Verzió**: 1.0.0  
**Utolsó frissítés**: 2026-09-03  
**Szerző**: OPNsense Security Team

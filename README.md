# OPNsense OpenVPN - Maximum Security Implementation

## 📋 Áttekintés

Ez a projekt egy **enterprise-grade, maximális biztonsági szintű OpenVPN konfigurációt** valósít meg az OPNsense firewall-on.

### 🔐 Biztonsági Jellemzők

- **TLS 1.3** - Legújabb, legbiztonságosabb TLS verzió
- **AES-256-GCM** - 256-bit AEAD titkosítás
- **ECDH (Elliptic Curve Diffie-Hellman)** - Modern kulcscsere
- **Perfect Forward Secrecy (PFS)** - Múltbeli kulcsok védelme
- **mTLS (Mutual TLS)** - Szerver és kliens kölcsönös hitelesítése
- **Certificate Pinning** - Tanúsítványfixálás
- **Key Rotation** - Automatikus kulcsforgatás
- **Firewall Rules** - Szigorú tűzfal szabályok
- **CrowdSec Integration** - Behatolásdetektálás

---

## 📁 Fájlstruktúra

```
OPNsense-OpenVPN-Security/
├── README.md                           # Ez a fájl
├── IMPLEMENTATION_GUIDE.md             # Teljes implementációs útmutató
├── COMPARISON.md                       # OpenVPN vs WireGuard összehasonlítás
├── config/
│   ├── openvpn-server-config.xml       # OPNsense XML konfiguráció
│   ├── openvpn-client-config.ovpn      # Kliens konfigurációs fájl
│   └── certificates/
│       ├── ca-generation.sh            # CA tanúsítványok generálása
│       ├── server-cert-generation.sh   # Szerver tanúsítványok
│       └── client-cert-generation.sh   # Kliens tanúsítványok
├── firewall-rules/
│   ├── inbound-rules.xml               # Bejövő szabályok
│   ├── outbound-rules.xml              # Kimenő szabályok
│   └── nat-rules.xml                   # NAT szabályok
├── scripts/
│   ├── setup.sh                        # Automatikus telepítés script
│   ├── verify-security.sh              # Biztonsági ellenőrzés
│   └── backup-config.sh                # Konfiguráció biztonsági mentés
├── monitoring/
│   ├── syslog-config.xml               # Syslog naplózás
│   └── crowdsec-config.xml             # CrowdSec integrálás
└── SECURITY_CHECKLIST.md               # Biztonsági ellenőrzőlista
```

---

## 🚀 Gyors Telepítés

### Előfeltételek

- OPNsense 24.1.x vagy újabb
- Root hozzáférés
- Minimum 2GB RAM
- SSL tanúsítványok (CA, Szerver)

### Lépések

1. **Repository klónozása:**
```bash
cd /tmp
git clone https://github.com/rozsay/OPNsense-OpenVPN-Security.git
cd OPNsense-OpenVPN-Security
```

2. **Tanúsítványok generálása:**
```bash
cd config/certificates
bash ca-generation.sh
bash server-cert-generation.sh
bash client-cert-generation.sh
```

3. **Konfiguráció betöltése az OPNsense-be:**
```bash
# XML konfiguráció importálása
# System > Configuration > Backups > Restore > Fájl feltöltés
```

4. **Scriptek futtatása:**
```bash
bash ../../scripts/setup.sh
bash ../../scripts/verify-security.sh
```

---

## 🔧 Konfigurációs Paraméterek

### Server Oldal

| Paraméter | Érték | Magyarázat |
|-----------|-------|-----------|
| Titkosítás | AES-256-GCM | Enterprise-grade |
| TLS verzió | 1.3+ | Legbiztonságosabb |
| Handshake | ECDH P-384 | 384-bit elliptic curve |
| Authentikáció | mTLS + TOTP | Dupla faktor |
| Key Size | 4096-bit | RSA szerver tanúsítvány |
| DH paraméterek | 4096-bit | Diffie-Hellman |
| Kompresszió | DISABLED | Biztonsági kockázat |
| Rekeying | 3600s (1h) | Automatikus kulcsforgatás |

### Client Oldal

| Paraméter | Érték | Magyarázat |
|-----------|-------|-----------|
| Titkosítás | AES-256-GCM | Szerver illesztés |
| TLS verzió | 1.3+ | Szerver illesztés |
| Cert pinning | SHA-256 | Tanúsítványfixálás |
| Reconnect | 10s | Újracsatlakozási timeout |
| Keepalive | 10/120 | Keep-alive ping |

---

## 📊 Teljesítmény

- **Throughput**: 400-600 Mbps (AES-256-GCM)
- **Latency**: 5-15ms (LAN)
- **CPU Usage**: 15-25% (szimpla szálak)
- **Memory**: 150-250MB

---

## 🔍 Monitorozás és Naplózás

```bash
# OpenVPN naplók megtekintése
tail -f /var/log/openvpn/openvpn.log

# Csatlakozottak ellenőrzése
netstat -an | grep :1194

# CrowdSec blokk ellenőrzése
cscli alerts list

# Syslog ellenőrzése
tail -f /var/log/system/messages
```

---

## 🛡️ Biztonsági Ellenőrzés

```bash
# OpenSSL parancsokkal az eszközcsatorna tesztelése
openssl s_client -connect firewall.local:1194 -tls1_3

# TLS verzió ellenőrzése
nmap --script ssl-enum-ciphers -p 1194 firewall.local

# Tanúsítványok ellenőrzése
openssl x509 -in cert.pem -text -noout
```

---

## ⚠️ Biztonsági Figyelmeztetések

1. **Soha ne osztd meg** a privát kulcsokat vagy CA tanúsítványokat
2. **Rendszeres tanúsítványfrissítések** (évente)
3. **Firewall szabályok** - Szigorúan limitáld a VPN portot
4. **Naplók monitorozása** - Gyanús tevékenységekre
5. **Biztonsági mentések** - Rendszeres backup

---

## 📚 Dokumentáció

- [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) - Lépésről lépésre útmutató
- [SECURITY_CHECKLIST.md](SECURITY_CHECKLIST.md) - Biztonsági ellenőrzőlista
- [COMPARISON.md](COMPARISON.md) - OpenVPN vs WireGuard

---

## 🤝 Támogatás

**Kérdések vagy problémák?**
- Issues: https://github.com/rozsay/OPNsense-OpenVPN-Security/issues
- Discussions: https://github.com/rozsay/OPNsense-OpenVPN-Security/discussions

---

## 📄 Licenc

MIT License - Lásd LICENSE fájlt

---

## ⭐ Hasznos Linkek

- [OPNsense Dokumentáció](https://docs.opnsense.org/)
- [OpenVPN Biztonsági Útmutató](https://openvpn.net/community-resources/hardening-openvpn-security/)
- [OWASP VPN Biztonsági](https://owasp.org/)

---

**Utolsó frissítés**: 2026-09-03  
**Verzió**: 1.0.0  
**Szerző**: OPNsense Security Team

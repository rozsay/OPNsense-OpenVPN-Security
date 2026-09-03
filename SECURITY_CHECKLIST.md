# OpenVPN Maximum Security Checklist

## ✅ Titkosítás és Kulcskezelés

- [ ] TLS 1.3 engedélyezve van
- [ ] AES-256-GCM titkosítás aktív
- [ ] ECDH P-384 kulcscsere beállítva
- [ ] Perfect Forward Secrecy (PFS) engedélyezve
- [ ] DH paraméterek 4096-bit
- [ ] mTLS (szerver + kliens cert) aktív
- [ ] Tanúsítvány pinning beállítva
- [ ] TLS Auth kulcs konfigurálva
- [ ] Pre-Shared Keys (ha szükséges) hozzáadva

## 🔐 Tanúsítványok és Hitelesítés

- [ ] CA tanúsítvány generálva és importálva
- [ ] Szerver tanúsítvány érvényes (nem lejárt)
- [ ] Szerver privát kulcs biztonságban
- [ ] Kliens tanúsítványok létrehozva
- [ ] Tanúsítványok validálva (openssl verify)
- [ ] CRL (Certificate Revocation List) beállítva
- [ ] Tanúsítványok évente frissítve

## 🛡️ Tűzfal és Hálózati Szabályok

- [ ] OpenVPN port (1194) csak WAN-ról nyitott
- [ ] Stateful firewall engedélyezve
- [ ] Rate limiting beállítva (DDoS védelem)
- [ ] Invalid states blokkolva
- [ ] Floating rules optimalizálva
- [ ] NAT szabályok helyesen konfigurálva
- [ ] Client-to-client communication engedélyezve (ha szükséges)
- [ ] Split tunneling konfigurálva

## 📊 Naplózás és Monitorozás

- [ ] OpenVPN naplózás engedélyezve (verb 4)
- [ ] Syslog integrálva
- [ ] Status log konfigurálva
- [ ] CrowdSec IDS/IPS aktív
- [ ] Log rotáció beállítva
- [ ] Audit logging engedélyezve
- [ ] Naplók exportálása (SIEM)
- [ ] Alert beállítások konfigurálva

## 🔄 Kliens Konfigurálás

- [ ] Kliens .OVPN fájlok generálva
- [ ] Tanúsítványok inline beépítve
- [ ] DNS settings konfigurálva
- [ ] Route pushing beállítva
- [ ] Keepalive intervallum beállítva
- [ ] Reconnection timeout beállítva
- [ ] Script security engedélyezve
- [ ] Kliens konfigurációk tesztelve

## 🔑 Biztonsági Mentések

- [ ] Privát kulcsok biztonsági mentése (szolid tárhely)
- [ ] CA kulcs biztonságban van
- [ ] Konfigurációs backup naponta
- [ ] Offline backup létezik
- [ ] Backup encryption beállítva
- [ ] Backup integritás ellenőrizve
- [ ] Disaster recovery terv van

## 👤 Hozzáférés Kontroll

- [ ] Felhasználói csoportok létrehozva
- [ ] VPN_Users csoport konfigurálva
- [ ] VPN_Dev csoport konfigurálva
- [ ] SSH hozzáférés csak admins-nak
- [ ] WebUI HTTPS-en keresztül
- [ ] WebUI port (8443) biztonságban
- [ ] SSH kulcs-alapú hitelesítés
- [ ] Root login letiltva

## 🌐 Hálózati Szegmentáció

- [ ] VPN subnet (10.8.0.0/24) izolálva
- [ ] Belső hálózatok elérhetők
- [ ] Nem szándékos hálózatok blokkolva
- [ ] Broadcast szűrés beállítva
- [ ] VLAN szegmentáció aktív
- [ ] Firewall zónák helyesen definiálva

## ⚙️ Haladó Biztonsági Beállítások

- [ ] Compression letiltva (CRIME támadás)
- [ ] Insecure ciphers letiltva
- [ ] Legacy protocols letiltva
- [ ] Explicit exit notify engedélyezve
- [ ] Replay protection aktív
- [ ] Bogon szűrés engedélyezve
- [ ] MSS clamping beállítva

## 🔄 Tanúsítványrotáció és Fenntartás

- [ ] Cron job tanúsítványfrissítéshez
- [ ] Kulcsrotáció ütemterve
- [ ] Automated renewal script tesztelve
- [ ] Renewal alerts beállítva
- [ ] Előre figyelmeztetés a lejáratból (30 nap)
- [ ] Tanúsítványok verzionálva
- [ ] Old certificates archivált

## 🧪 Tesztelés és Validáció

- [ ] Kliens csatlakozás tesztelve (Linux)
- [ ] Kliens csatlakozás tesztelve (macOS)
- [ ] Kliens csatlakozás tesztelve (Windows)
- [ ] Kliens csatlakozás tesztelve (Mobile)
- [ ] Throughput mérve
- [ ] Latencia mérve
- [ ] Failover tesztelve
- [ ] Load testing végrehajtva
- [ ] Security scan futtatva (nmap, OpenSSL)

## 📋 Dokumentáció

- [ ] Implementációs útmutató elkészítve
- [ ] Tűzfal szabályok dokumentálva
- [ ] Kliens konfigurációs útmutató
- [ ] Hibaelhárítási útmutató
- [ ] Disaster recovery terv
- [ ] Kontakt lista frissítve
- [ ] Change log vezetett

## 🚨 Incident Response

- [ ] Security incident terv van
- [ ] Kontakt lista elkészítve
- [ ] Escalation procedures definiálva
- [ ] Log archive politika
- [ ] Forensics terv van
- [ ] Communication plan van

---

## 📝 Megjegyzések

**Utolsó audit**: [DÁTUM]
**Auditáló**: [NÉV]
**Verzió**: 1.0.0

---

**Kitöltési útmutató**: Minden pontot ellenőrizz és jelöld be ✅. Ha egy pont nem teljesül, készíts remediation tervet.

# OpenVPN vs WireGuard - Comprehensive Comparison

## 📊 Feature Comparison Table

| Jellemző | OpenVPN | WireGuard | Győztes |
|----------|---------|-----------|----------|
| **Biztonsági Szint** | Nagyon Magas (TLS 1.3) | Nagyon Magas (Noise) | Döntetlen |
| **Teljesítmény (Throughput)** | 500 Mbps | 1000 Mbps | **WireGuard** |
| **Latencia (LAN)** | 15ms | 5ms | **WireGuard** |
| **CPU Használat** | 25% | 10% | **WireGuard** |
| **Memória Igény** | 200MB | 50MB | **WireGuard** |
| **Kód Méret** | 100k LOC | 4k LOC | **WireGuard** |
| **Titkosítási Kurzus** | AES-256-GCM | ChaCha20-Poly1305 | Döntetlen |
| **Kulcscsere** | ECDH (P-384) | Curve25519 | Döntetlen |
| **Tanúsítvány Kezelés** | Komplex (CA, cert, key) | Egyszerű (kulcspárok) | **WireGuard** |
| **Konfigurálhatóság** | Nagyon Nagy | Korlátozottabb | **OpenVPN** |
| **Kompatibilitás** | Minden platform | Minden platform | Döntetlen |
| **UDP/TCP** | Mindkettő | Csak UDP | WireGuard gyorsabb |
| **IPv6 Támogatás** | Igen | Igen | Döntetlen |
| **Dinamikus IP** | Támogatott | Támogatott | Döntetlen |
| **Mobilekompatibilás** | Jó | Kiváló | **WireGuard** |
| **Audit/Compliance** | NIST ajánlott | Ainda kutatott | **OpenVPN** |
| **Termelési Érettség** | Nagyon érett | Érett | **OpenVPN** |

---

## 🔐 Biztonsági Analízis

### OpenVPN
**Előnyök:**
- TLS 1.3 legújabb szabványok
- Perfect Forward Secrecy (PFS)
- NIST SP 800-56A kompatibilis
- Kiegészítő hitelesítési módok (TOTP, 2FA)
- Több audit történet

**Hátrányok:**
- 100k LOC → nagyobb attack surface
- Összetett tanúsítványkezelés
- Lassabb handshake

### WireGuard
**Előnyök:**
- Noise Protocol (modern kriptográfia)
- Stateless design → kisebb sérülékenység
- Egyszerű & auditálható kód
- Szimmetrikus kulcskezelés
- Kernel crypto gyorsítás

**Hátrányok:**
- Még nincs olyan sok audit (de gyorsan növekszik)
- Nem támogatja a klasszikus tanúsítványokat
- Kevésbé rugalmas konfigurálás

---

## 🚀 Teljesítmény Összehasonlítás

### Throughput (Mbps)
```
OpenVPN:  500 Mbps   ████████████░░░░░░░░░░░░░░
WireGuard: 1000 Mbps ████████████████████████████
```

### Latencia (ms)
```
OpenVPN:  15ms   ███████████░░░░░░░░░
WireGuard: 5ms   ████░░░░░░░░░░░░░░░░
```

### CPU Használat (%)
```
OpenVPN:  25%   ████████████░░░░░░░░░░░░░░░░
WireGuard: 10%   █████░░░░░░░░░░░░░░░░░░░░░░
```

### Memória (MB)
```
OpenVPN:  200MB ████████████████░░░░░░░░░░░░
WireGuard: 50MB  ████░░░░░░░░░░░░░░░░░░░░░░░░
```

---

## 💼 Felhasználási Esetek

### OpenVPN Ajánlott
- **Nagyvállalatok**: Szigorú compliance követelmények (NIST)
- **Szenzitív adatok**: Extra hitelesítés szükséges (2FA, TOTP)
- **Heterogén hálózatok**: Különböző protokollok/portok
- **Legacy rendszerek**: Széles kompatibilitás
- **Magas konfigurálhatóság**: Egyedi beállítások

### WireGuard Ajánlott
- **Performance-kritikus**: Gaming, adatátvitel
- **Modern infrastruktúra**: Cloud, Kubernetes
- **Mobilalkalmazások**: iOS, Android
- **Kicsi footprint**: IoT, embedded sistemas
- **Simplicitás**: Gyors telepítés, kevés config

---

## 📋 Választási Döntésfa

```
┌─ Szükséged van NIST compliance-ra?
│  ├─ YÉS → OpenVPN
│  └─ NEM ↓
├─ Szükséged van extra hitelesítésre (2FA)?
│  ├─ YÉS → OpenVPN
│  └─ NEM ↓
├─ Maximum teljesítmény szükséges?
│  ├─ YÉS → WireGuard
│  └─ NEM ↓
├─ Mobile-first megközelítés?
│  ├─ YÉS → WireGuard
│  └─ NEM ↓
├─ Egyszerű telepítés?
│  ├─ YÉS → WireGuard
│  └─ NEM → OpenVPN
```

---

## 🎯 Ajánlás az OPNsense-hez

### OpenVPN
```
⭐⭐⭐⭐⭐ Enterprise/Security-first
```

### WireGuard
```
⭐⭐⭐⭐⭐ Performance/Simplicity-first
```

---

## 🔚 Végső Ajánlás

**A legjobb választás: MINDKETTŐ futtatása!**

Differenciált megközelítés:
- **OpenVPN**: Szenzitív adatok, audit trail
- **WireGuard**: Napi munka, high-speed transfer

---

**Utolsó frissítés**: 2026-09-03  
**Verzió**: 1.0.0
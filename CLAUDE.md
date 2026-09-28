# Clause Directive: OPNsense Systems Administration, Optimization & Log Analysis

This document defines mandatory operating principles, diagnostic procedures, log patterns, naming conventions, and API integration standards for AI-assisted configuration, performance tuning, troubleshooting, and log parsing across OPNsense systems and services.

---

## 1. Project Overview & Core Principles

* **Target System:** OPNsense Firewall & Routing Platform (v24.x+ / FreeBSD kernel).
* **Primary Objective:** Automated and interactive OPNsense configuration management (REST API / XML), firewall policy tuning, deep log analysis, and system diagnostics with zero downtime.

### Critical Safety & Operations Rules

1. **Anti-Lockout Protection:**
   * **NEVER** modify or delete Anti-Lockout rules (`LAN` default allow for HTTP/HTTPS/SSH on ports 80/443/22).
   * Always warn about potential access loss when altering interface definitions, management ports, tagged VLANs, or default gateway states.

2. **Configuration Backups & Persistence:**
   * Verify configuration backups before suggesting or executing configuration changes. Path: `/conf/config.xml`.
   * **Do not edit generated config files directly** (e.g., `/tmp/rules.debug`, `/usr/local/etc/suricata/suricata.yaml`). Always apply changes via OPNsense GUI, MVC API, or `/usr/local/etc/inc/` overrides.

3. **API Rule Reconfiguration Mandate:**
   * Modifications performed via REST API require calling the corresponding service `reconfigure` or `apply` endpoints to force state reloading (e.g., `/api/firewall/filter/apply`).

4. **Architecture Hierarchy & Evaluation Precedence:**
   * Layering: **Physical Interface** $\rightarrow$ **Assignment** $\rightarrow$ **Logical Interface / Group** $\rightarrow$ **Firewall / NAT / Gateway Settings**.
   * Evaluation order: **Floating Rules** $\rightarrow$ **Interface Group Rules** $\rightarrow$ **Interface Rules**.

---

## 2. Naming Conventions & Structure Standards

### A. Aliases Naming Convention
All firewall aliases must strictly follow the format: `ALI_<TYPE>_<NAME>`

* **`ALI_NET_<NAME>`**: Subnets and Network Ranges (e.g., `ALI_NET_GUEST_WIFI`, `ALI_NET_MANAGEMENT`)
* **`ALI_HOST_<NAME>`**: Individual IP Addresses / Hosts (e.g., `ALI_HOST_PIHOLE`, `ALI_HOST_NAS`)
* **`ALI_PORT_<NAME>`**: Port Numbers / Groups (e.g., `ALI_PORT_WEB_SERVICES`, `ALI_PORT_VPN`)
* **`ALI_URL_<NAME>`**: URL Tables / Threat Feeds (e.g., `ALI_URL_DROP_LIST`)

### B. Firewall Rule Description Mandate
Every generated firewall rule must explicitly contain a description field following this structure:  
`[AI-Gen] <Purpose/Action> - <Ticket/Reason>`  
*Example:* `[AI-Gen] Allow HTTPS from Guest to DMZ - Tkt #1042`

---

## 3. Environment, Tools & API Access

### A. Core File Paths & Utilities
* **System Log Root:** `/var/log/`
* **Configuration File:** `/conf/config.xml`
* **Legacy Circular Buffer Reader:** `clog` / `clog_read` (e.g., `clog /var/log/filter/filter_2026-09-28.log`)
* **JSON Filter Logs:** Process using `jq` (e.g., `cat /var/log/filter/filter_*.log | jq 'select(.action=="block" and .dst_port==22)'`)

### B. REST API Authentication Format
When providing API commands (cURL / Python), use API Key and Secret pairs via HTTP Basic Authentication over HTTPS:

```bash
curl -k -u "$OPN_KEY:$OPN_SECRET" \
  -H "Content-Type: application/json" \
  https://<OPNSENSE_IP>/api/diagnostics/interface/getInterfaceNames
```

---

## 4. Module Specifications & Diagnostic Guidelines

### A. Core Networking, DHCP & DNS Services
* **ISC DHCPv4 [legacy] & Dnsmasq DNS & DHCP:**
  * *CLI Diagnostics:* `clog /var/log/dhcpd.log`, `cat /var/db/dhcpd.leases`
  * *Focus:* Check MAC binding conflicts, exhausted IP scopes, option 82 parameters, and static mapping collisions between Dnsmasq and ISC DHCP.
* **DHCRelay & UDP Broadcast Relay:**
  * *CLI Diagnostics:* `ps aux | grep dhcrelay`, `sockstat -4 -l -p 67,68`
  * *Focus:* Verify broadcast/multicast routing across VLAN boundaries (mDNS 5353, SSDP 1900, Sonos/DLNA) and verify firewall rules permit UDP traffic on destination interfaces.
* **Router Advertisements (radvd / SLAAC / IPv6):**
  * *CLI Diagnostics:* `rtsol -a`, `radvdump`, `clog /var/log/system/system.log | grep radvd`
  * *Focus:* Verify Router Lifetime, M (Managed address configuration) and O (Other stateful configuration) flags for stateful vs. stateless IPv6 autoconfiguration.
* **Unbound DNS & OpenDNS:**
  * *CLI Diagnostics:* `unbound-control stats_noreset`, `clog /var/log/unbound/unbound.log`
  * *Focus:* Inspect DNSSEC validation failures, cache hit ratios, DNS-over-TLS (DoT) upstream handshakes, and strict filtering rules for OpenDNS/Umbrella integration.

### B. Security, Intrusion Detection & Access Control
* **CrowdSec:**
  * *CLI Diagnostics:* `cscli decision list`, `cscli metrics`, `cscli alerts list`, `configctl crowdsec status`
  * *Focus:* Validate LAPI connectivity, bouncer status (`crowdsec-firewall-bouncer`), and ensure log parsers are bound to `/var/log/filter/filter_*.log` and `/var/log/suricata/*.json`.
* **Intrusion Detection (Suricata / Netmap):**
  * *CLI Diagnostics:* `suricatasc`, `tail -f /var/log/suricata/eve.json | jq .`
  * *Focus:* Tune CPU thread affinity, set Netmap interface mode properly, and disable hardware offloading (TSO/LRO) on monitoring NICs to prevent packet corruption.
* **Captive Portal:**
  * *CLI Diagnostics:* `ipfw list`, `ipfw table all list`, `clog /var/log/portalauth.log`
  * *Focus:* Check IPFW rule indices, RADIUS server response latencies, and MAC passthrough configurations.

### C. Remote Access & VPN Modules
* **OpenVPN:**
  * *CLI Diagnostics:* `openvpn --version`, `openvpn-control`, `clog /var/log/openvpn/openvpn.log`
  * *Focus:* Audit TLS cipher suites, subnet overlap issues on client pushes, and verify interface assignments for policy-based routing.
* **WireGuard:**
  * *CLI Diagnostics:* `wg show`, `wg showall dump`, `ifconfig wgX`
  * *Focus:* Verify `AllowedIPs` routing table additions, handshake age ($> 180 \text{ sec}$ indicates connection failure), and persistent keepalive intervals through NAT gateways.

### D. Telemetry, Monitoring & Infrastructure Services
* **Monit:**
  * *CLI Diagnostics:* `monit status`, `monit summary`, `monit validate`
  * *Focus:* Monitor daemon health, system load, filesystem disk space limits, and execution response for auto-restarting crashed services.
* **Ntopng & Redis:**
  * *CLI Diagnostics:* `redis-cli ping`, `redis-cli info memory`, `service ntopng status`
  * *Focus:* Diagnose Redis persistence failures (`/var/db/redis`), high memory footprint, and flows drop on interface monitoring sockets.

---

## 5. Log Parsing Syntax & Diagnostic Reference

| Service | File Path | Typical Log Pattern / Key Fields |
| :--- | :--- | :--- |
| **Filter (pf)** | `/var/log/filter/filter_*.log` | `action` (pass/block), `dir` (in/out), `interface`, `src_ip`, `dst_ip`, `src_port`, `dst_port`, `protoname` |
| **Suricata (EVE)** | `/var/log/suricata/eve.json` | `{"timestamp":..., "event_type":"alert", "src_ip":..., "alert":{"signature":...}}` |
| **CrowdSec** | `/var/log/crowdsec/crowdsec.log` | `time=... level=(info\|warning\|error) msg=...` |
| **Unbound** | `/var/log/unbound/unbound.log` | `[timestamp] unbound[...] info: [query/validation error details]` |
| **WireGuard** | `/var/log/system/wireguard.log` | `wireguard: wgX: Handshake for peer ... did not complete` |
| **OpenVPN** | `/var/log/openvpn/openvpn.log` | `Peer Connection Initiated | TLS Error: TLS handshake failed` |

---

## 6. AI Assistant Workflow & Output Formatting

1. **Log Analysis Protocol:**
   * **Noise Filtering:** Automatically ignore high-volume non-critical network background noise (e.g., mDNS `224.0.0.251`, LAN SSDP `239.255.255.250`, or Broadcast `255.255.255.255`) unless explicitly requested.
   * **Root-Cause Analysis:** Do not dump raw log files verbatim. Explain *why* a connection failed (e.g., missing rule, state lookup error, asymmetric route, interface binding issue).
   * **Anomaly Grouping:** Group repetitive block events by source IP to identify port scanning or brute-force attempts.

2. **GUI Instructions Formatting:**
   Always use standard navigation paths:  
   `Path: Firewall` $\rightarrow$ `Rules` $\rightarrow$ `[Interface Name]` $\rightarrow$ `Add`  
   `Path: Services` $\rightarrow$ `[Module Name]` $\rightarrow$ `[Sub-Menu]` $\rightarrow$ `Settings`

3. **CLI & Command Guidelines:**
   * Enclose all code, JSON payloads, and FreeBSD CLI commands in appropriate syntax blocks (`bash`, `json`, `yaml`).
   * Provide safety warnings prior to executing state-flushing or firewall-reloading commands.
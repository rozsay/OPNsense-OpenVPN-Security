#!/usr/local/bin/php
<?php
/*
 * topsoft-mode.php  v1.0  (2026-09-28)
 * topsoft.hu OPNsense 26.1 - TESZT / ÉLES üzemmód váltó
 *
 *   TESZT : internet a 192.168.226.3 (Ubuntu gw) PPPoE-ján át, OPNsense PPPoE (opt8) KIKAPCSOLVA
 *   ÉLES  : internet az OPNsense PPPoE-ján (opt8), a 226.3 PPPoE-ja lekapcsolva
 *
 * Hely:      /root/topsoft/topsoft-mode.php   (chmod 700)
 * Használat: topsoft-mode.php status
 *            topsoft-mode.php setup  [--mode test|eles] [--renumber-vpn] [--csv FILE] [--dry-run]
 *            topsoft-mode.php test   [--dry-run] [--no-reload]
 *            topsoft-mode.php eles   [--dry-run] [--no-reload]
 *
 * Tag-konvenció (a leírás eleje):
 *   [TEST] ... csak teszt módban engedélyezett
 *   [ELES] ... csak éles módban engedélyezett
 *   [ALL]  ... mindkét módban (a váltó nem nyúl hozzá)
 * A többi (tag nélküli) szabályhoz a váltó nem nyúl.
 *
 * Minden mentés új config revíziót hoz létre (System > Configuration > History),
 * onnan bármikor visszaállítható.
 *
 * Lokális teszt (nem OPNsense-en): --config export.xml -> export.xml.out
 */

const VERSION        = '1.0';
const IF_PPPOE       = 'opt8';
const IF_LAN2        = 'opt7';
const GW_PPPOE       = 'OPT8_PPPOE_PPPOE';
const GW_226_3       = 'LAN_GW';
const MON_PPPOE      = '1.1.1.1';
const MON_226_3      = '9.9.9.9';
const PPPOE_DEV      = 'pppoe0';
const MODE_FILE      = '/root/topsoft/mode';
const DEFAULT_CSV    = '/root/topsoft/eles_portforwards.csv';
const VPN_NET_OLD    = '10.8.0.0/24';
const VPN_NET_NEW    = '10.18.0.0/24';
const VPN_226_3_NET  = '10.8.0.0/24';   // a 226.3 OpenVPN (UDP 1987) tunnel hálója

// ------------------------------------------------------------------ args
$argv0 = array_shift($argv);
$cmd = $argv[0] ?? 'help';
$opt = ['dry-run' => false, 'no-reload' => false, 'renumber-vpn' => false,
        'mode' => 'test', 'csv' => DEFAULT_CSV, 'config' => null];
for ($i = 1; $i < count($argv); $i++) {
    $a = $argv[$i];
    if ($a === '--dry-run')        { $opt['dry-run'] = true; }
    elseif ($a === '--no-reload')  { $opt['no-reload'] = true; }
    elseif ($a === '--renumber-vpn') { $opt['renumber-vpn'] = true; }
    elseif ($a === '--mode')       { $opt['mode'] = $argv[++$i] ?? ''; }
    elseif ($a === '--csv')        { $opt['csv'] = $argv[++$i] ?? ''; }
    elseif ($a === '--config')     { $opt['config'] = $argv[++$i] ?? ''; }
    else { fail("Ismeretlen opció: $a"); }
}
if (!in_array($opt['mode'], ['test', 'eles'], true)) { fail("--mode csak test|eles lehet"); }

$LOCAL = $opt['config'] !== null;          // lokális teszt mód
$CHANGES = [];

// ------------------------------------------------------------------ backend
if ($LOCAL) {
    $cfg = simplexml_load_file($opt['config']) or fail("Nem olvasható: {$opt['config']}");
} else {
    if (!is_dir('/usr/local/opnsense')) { fail("Nem OPNsense (használd: --config FILE a teszthez)"); }
    if (posix_geteuid() !== 0) { fail("root jogosultság kell"); }
    require_once('script/load_phalcon.php');
    require_once('config.inc');
    require_once('util.inc');
    require_once('interfaces.inc');
    $cfg = \OPNsense\Core\Config::getInstance()->object();
}

function out($m)  { fwrite(STDOUT, $m . "\n"); }
function warn($m) { fwrite(STDERR, "[!] $m\n"); }
function fail($m) { fwrite(STDERR, "[X] $m\n"); exit(1); }
function chg($m)  { global $CHANGES; $CHANGES[] = $m; out("  ~ $m"); }

function uuid4() {
    $d = random_bytes(16);
    $d[6] = chr((ord($d[6]) & 0x0f) | 0x40);
    $d[8] = chr((ord($d[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($d), 4));
}

/** mező érték beállítása, csak ha változik; üres string = üres elem */
function setf(SimpleXMLElement $e, string $field, ?string $val, string $label) {
    $cur = isset($e->$field) ? (string)$e->$field : null;
    if ($val === null) {                       // törlés
        if ($cur !== null) { unset($e->$field); chg("$label: $field törölve (volt: '$cur')"); }
        return;
    }
    if ($cur !== $val) { $e->$field = $val; chg("$label: $field '" . ($cur ?? '-') . "' -> '$val'"); }
}

function clone_after(SimpleXMLElement $tpl): SimpleXMLElement {
    $dom = dom_import_simplexml($tpl);
    $new = $dom->cloneNode(true);
    $dom->parentNode->appendChild($new);
    return simplexml_import_dom($new);
}

function tag_of(string $desc): ?string {
    if (preg_match('/^\[(TEST|ELES|ALL)\]/', $desc, $m)) { return $m[1]; }
    return null;
}

// ------------------------------------------------------------------ keresők
function filter_rules($cfg) { return $cfg->OPNsense->Firewall->Filter->rules->rule ?? []; }
function rule_by_uuid($cfg, $u) { foreach (filter_rules($cfg) as $r) { if ((string)$r['uuid'] === $u) return $r; } return null; }
function rule_by_desc($cfg, $d) { foreach (filter_rules($cfg) as $r) { if ((string)$r->description === $d) return $r; } return null; }
function nat_by_uuid($cfg, $u)  { foreach ($cfg->nat->rule ?? [] as $r) { if ((string)$r['uuid'] === $u) return $r; } return null; }
function nat_by_desc($cfg, $d)  { foreach ($cfg->nat->rule ?? [] as $r) { if ((string)$r->descr === $d) return $r; } return null; }
function alias_by_name($cfg, $n) { foreach ($cfg->OPNsense->Firewall->Alias->aliases->alias ?? [] as $a) { if ((string)$a->name === $n) return $a; } return null; }
function gw_by_name($cfg, $n)   { foreach ($cfg->OPNsense->Gateways->gateway_item ?? [] as $g) { if ((string)$g->name === $n) return $g; } return null; }

function retag(SimpleXMLElement $e, string $field, string $tag, string $label) {
    $d = (string)$e->$field;
    if (tag_of($d) === $tag) return;
    $d = preg_replace('/^\[(TEST|ELES|ALL)\]\s*/', '', $d);
    setf($e, $field, "[$tag] " . ($d !== '' ? $d : $label), $label);
}

// ------------------------------------------------------------------ mód felismerés
function detect_mode($cfg): string {
    $pppoe_on = isset($cfg->interfaces->{IF_PPPOE}->enable) && (string)$cfg->interfaces->{IF_PPPOE}->enable === '1';
    $g = gw_by_name($cfg, GW_226_3);
    $lan_default = $g && (string)$g->defaultgw === '1';
    if ($pppoe_on && !$lan_default) return 'eles';
    if (!$pppoe_on && $lan_default) return 'test';
    return 'VEGYES (' . ($pppoe_on ? 'PPPoE BE' : 'PPPoE KI') . ', LAN_GW default=' . ($lan_default ? 'igen' : 'nem') . ')';
}

// ------------------------------------------------------------------ tagek kapcsolása
function apply_tags($cfg, string $mode) {
    $want = fn($tag) => $tag === 'ALL' || ($tag === 'TEST' && $mode === 'test') || ($tag === 'ELES' && $mode === 'eles');
    foreach (filter_rules($cfg) as $r) {
        $t = tag_of((string)$r->description);
        if ($t === null || $t === 'ALL') continue;
        setf($r, 'enabled', $want($t) ? '1' : '0', "filter '" . $r->description . "'");
    }
    foreach ($cfg->nat->rule ?? [] as $r) {
        $t = tag_of((string)$r->descr);
        if ($t === null || $t === 'ALL') continue;
        setf($r, 'disabled', $want($t) ? '0' : '1', "portfwd '" . $r->descr . "'");
    }
    foreach ($cfg->nat->outbound->rule ?? [] as $r) {
        $t = tag_of((string)$r->descr);
        if ($t === null || $t === 'ALL') continue;
        if ($want($t)) { setf($r, 'disabled', null, "outbound '" . $r->descr . "'"); }
        else           { setf($r, 'disabled', '1', "outbound '" . $r->descr . "'"); }
    }
}

// ------------------------------------------------------------------ mód alkalmazása
function apply_mode($cfg, string $mode) {
    out("== Mód: " . strtoupper($mode));
    $ifp = $cfg->interfaces->{IF_PPPOE};
    if (!$ifp) fail("Nincs " . IF_PPPOE . " interfész");
    $gp = gw_by_name($cfg, GW_PPPOE);  if (!$gp) fail("Nincs gateway: " . GW_PPPOE);
    $gl = gw_by_name($cfg, GW_226_3);  if (!$gl) fail("Nincs gateway: " . GW_226_3);

    if ($mode === 'test') {
        setf($ifp, 'enable', null, 'PPPoE interfész (opt8)');            // KI: ne tárcsázzon a 226.3 mellett!
        foreach (['defaultgw' => '1', 'priority' => '5', 'monitor_disable' => '0', 'monitor' => MON_226_3, 'disabled' => '0'] as $k => $v) setf($gl, $k, $v, 'GW ' . GW_226_3);
        foreach (['defaultgw' => '1', 'priority' => '10', 'monitor_disable' => '1', 'monitor' => MON_PPPOE] as $k => $v) setf($gp, $k, $v, 'GW ' . GW_PPPOE);
        setf($cfg->system, 'disablereplyto', 'yes', 'system');
    } else {
        setf($ifp, 'enable', '1', 'PPPoE interfész (opt8)');
        foreach (['defaultgw' => '1', 'priority' => '5', 'monitor_disable' => '0', 'monitor' => MON_PPPOE, 'disabled' => '0'] as $k => $v) setf($gp, $k, $v, 'GW ' . GW_PPPOE);
        // a 226.3 ÉLES módban nem internet-kijárat (a PPPoE-ja le van kapcsolva) -> nem lehet default,
        // monitor ki (a 8.8.8.8/9.9.9.9 host route hurkot okozna 226.3 <-> 226.31 között),
        // de gatewayként megmarad a 10.8.0.0/24 statikus route célpontjának
        foreach (['defaultgw' => '0', 'priority' => '255', 'monitor_disable' => '1'] as $k => $v) setf($gl, $k, $v, 'GW ' . GW_226_3);
        setf($cfg->system, 'disablereplyto', null, 'system');
    }
    apply_tags($cfg, $mode);
}

// ------------------------------------------------------------------ setup (egyszeri, idempotens)
function ensure_alias($cfg, string $name, string $type, string $content, string $desc) {
    if (alias_by_name($cfg, $name)) { out("  = alias megvan: $name"); return; }
    $tpl = null;
    foreach ($cfg->OPNsense->Firewall->Alias->aliases->alias as $a) { $tpl = $a; break; }
    if (!$tpl) fail("Nincs alias sablon");
    $n = clone_after($tpl);
    $n['uuid'] = uuid4();
    foreach (['enabled' => '1', 'name' => $name, 'type' => $type, 'content' => $content, 'description' => $desc,
              'proto' => '', 'interface' => '', 'counters' => '0', 'updatefreq' => '', 'path_expression' => '', 'categories' => ''] as $k => $v) {
        $n->$k = $v;
    }
    chg("alias létrehozva: $name = " . str_replace("\n", ',', $content));
}

function ensure_rule($cfg, array $f) {
    if (rule_by_desc($cfg, $f['description'])) { out("  = szabály megvan: {$f['description']}"); return; }
    $tpl = null;
    foreach (filter_rules($cfg) as $r) { $tpl = $r; break; }
    if (!$tpl) fail("Nincs filter szabály sablon");
    $n = clone_after($tpl);
    $n['uuid'] = uuid4();
    $base = ['enabled' => '1', 'statetype' => 'keep', 'action' => 'pass', 'quick' => '1', 'interfacenot' => '0',
             'direction' => 'in', 'ipprotocol' => 'inet', 'protocol' => 'any', 'source_net' => 'any', 'source_not' => '0',
             'source_port' => '', 'destination_net' => 'any', 'destination_not' => '0', 'destination_port' => '',
             'gateway' => '', 'log' => '0', 'allowopts' => '0', 'tag' => '', 'tagged' => '', 'sched' => '', 'categories' => ''];
    foreach (array_merge($base, $f) as $k => $v) { $n->$k = (string)$v; }
    chg("szabály létrehozva: {$f['description']} (seq {$f['sequence']}, {$f['interface']})");
}

function ensure_portfwd($cfg, array $f, string $mode) {
    if (nat_by_desc($cfg, $f['descr'])) { out("  = port forward megvan: {$f['descr']}"); return; }
    foreach ($cfg->nat->rule ?? [] as $r) {
        if ((string)$r->interface === IF_PPPOE && (string)$r->protocol === $f['proto']
            && (string)$r->destination->port === $f['dport']) {
            warn("port forward kihagyva, már van {$f['proto']}/{$f['dport']} opt8-on: '" . $r->descr . "'"); return;
        }
    }
    $tpl = null;
    foreach ($cfg->nat->rule ?? [] as $r) { $tpl = $r; break; }
    if ($tpl) {
        $n = clone_after($tpl);
    } else {
        $n = $cfg->nat->addChild('rule');
        foreach (['source', 'destination', 'created', 'updated'] as $c) $n->addChild($c);
    }
    $n['uuid'] = uuid4();
    $max = 0; foreach ($cfg->nat->rule as $r) { $max = max($max, (int)$r->sequence); }
    $vals = ['sequence' => (string)($max + 100), 'disabled' => ($mode === 'eles' ? '0' : '1'), 'nordr' => '0',
             'interface' => IF_PPPOE, 'ipprotocol' => 'inet', 'protocol' => $f['proto'],
             'target' => $f['target'], 'local-port' => $f['lport'], 'log' => '0', 'descr' => $f['descr'],
             'nosync' => '0', 'natreflection' => '', 'pass' => 'pass', 'associated-rule-id' => '', 'poolopts' => '',
             'category' => '', 'tag' => '', 'tagged' => ''];
    foreach ($vals as $k => $v) { $n->$k = $v; }
    $n->source->network = $f['src']; $n->source->port = ''; $n->source->not = '0';
    $n->destination->network = 'opt8ip'; $n->destination->port = $f['dport']; $n->destination->not = '0';
    foreach (['created', 'updated'] as $c) { $n->$c->username = 'topsoft-mode.php'; $n->$c->time = sprintf('%.2f', microtime(true)); $n->$c->description = 'setup'; }
    chg("port forward létrehozva: {$f['descr']} ({$f['proto']} opt8ip:{$f['dport']} -> {$f['target']}:{$f['lport']}, " . ($mode === 'eles' ? 'aktív' : 'tiltva') . ")");
}

function read_csv(string $file): array {
    if (!is_readable($file)) { warn("CSV nem olvasható: $file (port forward import kimarad)"); return []; }
    $rows = [];
    foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $ln => $line) {
        if ($line[0] === '#' || stripos($line, 'proto,') === 0) continue;
        $c = str_getcsv($line);
        if (count($c) < 6) { warn("CSV sor " . ($ln + 1) . " hibás, kihagyva: $line"); continue; }
        [$proto, $dport, $target, $lport, $src, $descr] = array_map('trim', $c);
        if (!in_array($proto, ['tcp', 'udp', 'tcp/udp'], true) || !filter_var($target, FILTER_VALIDATE_IP)
            || !preg_match('/^\d+(-\d+)?$/', $dport) || !preg_match('/^\d+(-\d+)?$/', $lport)) {
            warn("CSV sor " . ($ln + 1) . " érvénytelen, kihagyva: $line"); continue;
        }
        $rows[] = ['proto' => $proto, 'dport' => $dport, 'target' => $target, 'lport' => $lport,
                   'src' => $src === '' ? 'any' : $src, 'descr' => '[ELES] ' . preg_replace('/^\[(TEST|ELES|ALL)\]\s*/', '', $descr)];
    }
    return $rows;
}

function setup($cfg, array $opt) {
    out("== SETUP (egyszeri, idempotens)");
    // 1. aliasok
    ensure_alias($cfg, 'RFC1918', 'network', "10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16", 'Privát tartományok');
    ensure_alias($cfg, 'IP_LOVAS', 'host', '37.220.139.52', 'Lovas külső IP (SQL 1433)');
    ensure_alias($cfg, 'NET_VPN_226_3', 'network', VPN_226_3_NET, '226.3 OpenVPN (UDP 1987) kliensek');

    // 2. új szabályok
    ensure_rule($cfg, ['sequence' => '245', 'interface' => IF_LAN2, 'protocol' => 'UDP', 'destination_net' => 'opt7ip',
        'destination_port' => '11194', 'description' => '[TEST] OpenVPN 11194 a 226.3 DNAT-jan at (-> 192.168.226.31)']);
    ensure_rule($cfg, ['sequence' => '375', 'interface' => IF_PPPOE, 'protocol' => 'UDP', 'destination_net' => 'opt8ip',
        'destination_port' => '11194', 'description' => '[ELES] OpenVPN 11194 PPPoE']);
    ensure_rule($cfg, ['sequence' => '295', 'interface' => IF_LAN2, 'source_net' => 'NET_VPN_226_3',
        'destination_net' => 'NET_DEV,NET_INFRA', 'description' => '[ALL] 226.3 VPN kliensek (10.8.0.0/24) -> DEV/INFRA']);
    ensure_rule($cfg, ['sequence' => '900', 'interface' => IF_LAN2, 'source_net' => 'opt7', 'destination_net' => 'RFC1918',
        'destination_not' => '1', 'description' => '[ELES] LAN2 (226/24, VoIP is) -> internet PPPoE-n']);

    // 3. meglévő elemek tagelése / javítása
    foreach ([['39b4ed11-d105-4fcd-9ee1-04374cfe66ec', 'ELES', 'WireGuard in (PPPoE)'],
              ['e9d30d00-43f6-484b-88fc-5b0e3282c36d', 'ELES', 'SQL 1433 IP_LOVAS'],
              ['1ad6b5d9-3046-4f66-b897-5a86c096b4a1', 'ELES', 'VoIP -> PPPoE']] as [$u, $t, $l]) {
        if ($r = rule_by_uuid($cfg, $u)) retag($r, 'description', $t, $l);
    }
    if ($r = rule_by_uuid($cfg, '39b4ed11-d105-4fcd-9ee1-04374cfe66ec')) setf($r, 'source_net', 'any', 'WG in');
    if ($r = rule_by_uuid($cfg, 'e9d30d00-43f6-484b-88fc-5b0e3282c36d')) setf($r, 'source_net', 'IP_LOVAS', 'SQL in');

    if ($r = nat_by_uuid($cfg, '8951c90a-51c8-46b1-941b-c00cdf02707c')) {          // NAT 900 SQL
        setf($r->source, 'network', 'IP_LOVAS', 'NAT 900');
        setf($r->destination, 'network', 'opt8ip', 'NAT 900');
        retag($r, 'descr', 'ELES', 'SQL 1433 csak IP_LOVAS');
    }
    if ($r = nat_by_uuid($cfg, '1e048cdb-c438-4f5f-821c-37535b5c58b2')) {          // NAT 1100 Postfix
        setf($r->source, 'network', 'any', 'NAT 1100');
        setf($r->source, 'port', '', 'NAT 1100');
        setf($r->destination, 'network', 'opt8ip', 'NAT 1100');
        retag($r, 'descr', 'ELES', 'Postfix bejovo levelezes -> 226.3');
    }
    if ($r = nat_by_uuid($cfg, '40c68261-9aa0-4277-9f4c-75f01bac26ec')) {          // NAT 1000 no-op
        $dom = dom_import_simplexml($r); $dom->parentNode->removeChild($dom);
        chg("NAT 1000 (192.168.20.23 -> önmaga, no-op) törölve");
    }
    foreach ($cfg->nat->outbound->rule ?? [] as $r) {
        $src = (string)$r->source->network; $if = (string)$r->interface;
        if ($if === IF_PPPOE && in_array($src, ['GW', 'VOIP_PHONES'], true)) retag($r, 'descr', 'ELES', "outbound $src -> PPPoE");
    }

    // 4. statikus route: a 226.3 OpenVPN kliensei mindkét módban a 226.3 felé
    $sr = $cfg->staticroutes;
    $has = false;
    foreach ($sr->route ?? [] as $rt) { if ((string)$rt->network === VPN_226_3_NET) $has = true; }
    if (!$has) {
        foreach ($sr->route ?? [] as $rt) { if (trim((string)$rt->network) === '' && count($rt->children()) === 0) { $d = dom_import_simplexml($rt); $d->parentNode->removeChild($d); break; } }
        $rt = $sr->addChild('route');
        $rt['uuid'] = uuid4();
        $rt->network = VPN_226_3_NET; $rt->gateway = GW_226_3; $rt->descr = '[ALL] 226.3 OpenVPN (1987) kliensek'; $rt->disabled = '0';
        chg("statikus route: " . VPN_226_3_NET . " via " . GW_226_3);
    } else { out("  = statikus route megvan: " . VPN_226_3_NET); }

    // 5. OpenVPN / Unbound
    $inst = $cfg->OPNsense->OpenVPN->Instances->Instance ?? null;
    if ($inst && $opt['renumber-vpn'] && (string)$inst->server === VPN_NET_OLD) {
        setf($inst, 'server', VPN_NET_NEW, 'OpenVPN instance (ütközés a 226.3 1987-es VPN-jével)');
        foreach ($cfg->OPNsense->unboundplus->acls->acl ?? [] as $a) {
            if (strpos((string)$a->networks, VPN_NET_OLD) !== false) setf($a, 'networks', str_replace(VPN_NET_OLD, VPN_NET_NEW, (string)$a->networks), 'Unbound ACL');
        }
    } elseif ($inst && (string)$inst->server === VPN_NET_OLD) {
        warn("Az OPNsense OpenVPN tunnel hálója " . VPN_NET_OLD . " = a 226.3 VPN hálója! Futtasd --renumber-vpn opcióval.");
    }
    $ug = $cfg->OPNsense->unboundplus->general ?? null;
    if ($ug) setf($ug, 'active_interface', '', 'Unbound (minden interfész, a VPN DNS push 192.168.10.1 miatt)');

    // 6. PPPoE interfész finomhangolás
    $ifp = $cfg->interfaces->{IF_PPPOE};
    setf($ifp, 'mss', '1452', 'opt8');
    setf($ifp, 'blockpriv', '1', 'opt8');
    setf($ifp, 'blockbogons', '1', 'opt8');

    // 7. dnsmasq ne fusson a PPPoE-n
    if (isset($cfg->dnsmasq->interface)) {
        $l = array_values(array_filter(explode(',', (string)$cfg->dnsmasq->interface), fn($x) => $x !== IF_PPPOE && $x !== ''));
        setf($cfg->dnsmasq, 'interface', implode(',', $l), 'dnsmasq');
    }

    // 8. port forwardok CSV-ből
    foreach (read_csv($opt['csv']) as $f) ensure_portfwd($cfg, $f, $opt['mode']);

    // 9. tagek a megadott módnak megfelelően
    out("== Tagek beállítása a(z) '{$opt['mode']}' módhoz");
    apply_tags($cfg, $opt['mode']);
}

// ------------------------------------------------------------------ mentés + reload
function save_cfg($cfg, array $opt, string $why) {
    global $CHANGES, $LOCAL;
    if (!$CHANGES) { out("Nincs változás."); return false; }
    if ($opt['dry-run']) { out("DRY-RUN: " . count($CHANGES) . " változás, NINCS mentve."); return false; }
    if ($LOCAL) {
        $f = $opt['config'] . '.out';
        $dom = new DOMDocument('1.0'); $dom->preserveWhiteSpace = false; $dom->formatOutput = true;
        $dom->loadXML($cfg->asXML()); $dom->save($f);
        out("Mentve (lokális): $f"); return true;
    }
    \OPNsense\Core\Config::getInstance()->save(null, true);
    out("Config mentve (" . count($CHANGES) . " változás) - revízió: $why");
    return true;
}

function sh($c) { out("  \$ $c"); passthru($c . ' 2>&1', $rc); return $rc; }

function pppoe_ip(): string {
    $o = shell_exec('/sbin/ifconfig ' . PPPOE_DEV . ' 2>/dev/null') ?? '';
    return preg_match('/inet (\d+\.\d+\.\d+\.\d+)/', $o, $m) ? $m[1] : '';
}

function reload_all(array $opt) {
    global $LOCAL;
    if ($LOCAL || $opt['dry-run']) return;
    if ($opt['no-reload']) { out("--no-reload: futtasd kézzel: /usr/local/etc/rc.reload_all"); return; }
    out("== Újratöltés (rc.reload_all, néhány mp kiesés az összes interfészen)");
    sh('/usr/local/etc/rc.reload_all');
}

// ------------------------------------------------------------------ status
function status($cfg) {
    out("topsoft-mode.php v" . VERSION);
    out("Felismert mód  : " . detect_mode($cfg));
    out("Mód fájl       : " . (is_readable(MODE_FILE) ? trim(file_get_contents(MODE_FILE)) : '-'));
    out("PPPoE (opt8)   : " . ((string)($cfg->interfaces->{IF_PPPOE}->enable ?? '') === '1' ? 'ENGEDÉLYEZVE' : 'kikapcsolva')
        . (function_exists('posix_geteuid') && is_dir('/usr/local/opnsense') ? ', ' . PPPOE_DEV . ' IP: ' . (pppoe_ip() ?: '-') : ''));
    foreach ([GW_226_3, GW_PPPOE] as $n) {
        $g = gw_by_name($cfg, $n);
        if ($g) out(sprintf("GW %-18s: default=%s prio=%s monitor=%s%s", $n, $g->defaultgw, $g->priority,
            (string)$g->monitor_disable === '1' ? 'KI' : 'be', (string)$g->monitor ? " ({$g->monitor})" : ''));
    }
    out("disablereplyto : " . ((string)($cfg->system->disablereplyto ?? '') ?: '(reply-to aktív)'));
    $inst = $cfg->OPNsense->OpenVPN->Instances->Instance ?? null;
    if ($inst) out("OpenVPN        : {$inst->proto} {$inst->port}, tunnel {$inst->server}, local='" . $inst->local . "'"
        . ((string)$inst->server === VPN_226_3_NET ? '  <-- ÜTKÖZIK a 226.3 VPN-nel!' : ''));
    out("Tagelt elemek:");
    foreach (filter_rules($cfg) as $r) { if (($t = tag_of((string)$r->description)) !== null) out(sprintf("  filter  %-4s %-3s %s", $t, (string)$r->enabled === '1' ? 'BE' : 'ki', $r->description)); }
    foreach ($cfg->nat->rule ?? [] as $r) { if (($t = tag_of((string)$r->descr)) !== null) out(sprintf("  portfwd %-4s %-3s %s", $t, (string)$r->disabled === '1' ? 'ki' : 'BE', $r->descr)); }
    foreach ($cfg->nat->outbound->rule ?? [] as $r) { if (($t = tag_of((string)$r->descr)) !== null) out(sprintf("  outbnd  %-4s %-3s %s", $t, (string)$r->disabled === '1' ? 'ki' : 'BE', $r->descr)); }
}

// ------------------------------------------------------------------ main
switch ($cmd) {
    case 'status':
        status($cfg);
        break;

    case 'setup':
        setup($cfg, $opt);
        if (save_cfg($cfg, $opt, 'topsoft-mode setup') && !$LOCAL) { sh('configctl filter reload'); }
        out("Setup kész. Következő lépés: topsoft-mode.php {$opt['mode']}");
        break;

    case 'test':
    case 'eles':
        $mode = $cmd;
        if ($mode === 'test' && !$LOCAL && !$opt['dry-run'] && pppoe_ip() !== '') {
            out("== PPPoE bontása (hogy a 226.3 fel tudja venni a fix IP-s sessiont)");
            if (function_exists('interface_bring_down')) { interface_bring_down(IF_PPPOE); }
            foreach (glob('/var/run/*' . IF_PPPOE . '*.pid') ?: [] as $pf) { sh("/bin/pkill -F $pf"); }
        }
        apply_mode($cfg, $mode);
        $saved = save_cfg($cfg, $opt, "topsoft-mode $mode");
        if (!$LOCAL && !$opt['dry-run']) {
            @mkdir(dirname(MODE_FILE), 0700, true);
            file_put_contents(MODE_FILE, $mode . "\n");
        }
        if ($saved) reload_all($opt);
        if ($mode === 'eles' && !$LOCAL && !$opt['dry-run'] && !$opt['no-reload']) {
            out("== PPPoE felépülésére várok (max 90 mp)");
            for ($i = 0; $i < 45 && pppoe_ip() === ''; $i++) sleep(2);
            $ip = pppoe_ip();
            if ($ip === '') { warn("A PPPoE NEM épült fel! Visszaállás: topsoft-mode.php test (és a 226.3-on: topsoft-mode.sh test)"); exit(2); }
            out("PPPoE fent: $ip");
        }
        if ($mode === 'test' && !$LOCAL && !$opt['dry-run'] && pppoe_ip() !== '') {
            warn(PPPOE_DEV . " még mindig kapott IP-t - ellenőrizd: Interfaces > OPT8_PPPOE (Enable ki)"); exit(2);
        }
        out("Kész: " . strtoupper($mode));
        break;

    default:
        out("Használat: $argv0 status | setup [--mode test|eles] [--renumber-vpn] [--csv FILE] | test | eles  [--dry-run] [--no-reload]");
        exit($cmd === 'help' ? 0 : 1);
}

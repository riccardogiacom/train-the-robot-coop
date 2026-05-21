#!/bin/bash
# SPF resolver + CIDR aggregator
# Requisiti: dig (sudo apt install dnsutils)
#            python3 + netaddr (pip3 install netaddr)

set -euo pipefail

if ! command -v dig &>/dev/null; then
    echo "ERRORE: dig non trovato. Installa con: sudo apt install dnsutils"
    exit 1
fi
if ! python3 -c "import netaddr" 2>/dev/null; then
    echo "ERRORE: netaddr non trovato. Installa con: pip3 install netaddr"
    exit 1
fi

ROOT_DOMAINS=(
    "spf.turbo-smtp.com"
    "zcsend.net"
    "sender.zohobooks.com"
    "one.zoho.eu"
)

declare -A VISITED
declare -a ALL_IPS

get_spf_record() {
    local domain="$1"
    # dig TXT (senza +short) mette tutti gli chunk di un record sulla STESSA riga,
    # es:  zcsend.net. 3600 IN TXT "parte1" "parte2"
    # Così sed può unire i chunk prima che grep filtri la riga.
    dig TXT "$domain" 2>/dev/null \
        | grep -v '^;' \
        | grep -iE 'IN[[:space:]]+TXT' \
        | grep -i 'v=spf1' \
        | sed 's/.*IN[[:space:]]*TXT[[:space:]]*//' \
        | sed 's/"[[:space:]]*"//g; s/"//g' \
        | head -1
}

resolve_spf() {
    local domain="$1"
    [[ -n "${VISITED[$domain]+x}" ]] && return
    VISITED[$domain]=1

    local txt
    txt=$(get_spf_record "$domain")

    if [[ -z "$txt" ]]; then
        echo "  [WARN] nessun record SPF per: $domain"
        return
    fi

    echo "  [SPF] $domain"
    echo "        $txt"

    for token in $txt; do
        case "$token" in
            ip4:*|ip6:*)  ALL_IPS+=("${token#*:}") ;;
            include:*)    resolve_spf "${token#include:}" ;;
            redirect=*)   resolve_spf "${token#redirect=}" ;;
        esac
    done
}

echo ""
echo "╔══ FASE 1: risoluzione SPF ricorsiva ══════════════════════════════════╗"
for domain in "${ROOT_DOMAINS[@]}"; do
    echo ""
    echo "  [ROOT] $domain"
    resolve_spf "$domain"
done

mapfile -t DEDUPED < <(printf '%s\n' "${ALL_IPS[@]}" | sort -u)

echo ""
echo "╠══ FASE 2: deduplicazione ═════════════════════════════════════════════╣"
echo "  IP trovati (con duplicati) : ${#ALL_IPS[@]}"
echo "  IP dopo deduplicazione     : ${#DEDUPED[@]}"

echo ""
echo "╠══ FASE 3: aggregazione CIDR ══════════════════════════════════════════╣"

AGGREGATED=$(python3 - "${DEDUPED[@]}" <<'PYEOF'
import sys
from netaddr import IPNetwork, cidr_merge

ips = sys.argv[1:]
ip4_raw = [ip for ip in ips if ":" not in ip]
ip6_raw = [ip for ip in ips if ":" in ip]

def safe_parse(lst, label):
    nets = []
    for i in lst:
        try:
            nets.append(IPNetwork(i))
        except Exception as e:
            print(f"  [WARN] IP non valido ignorato ({label}): {i!r} -> {e}", file=sys.stderr)
    return nets

ip4_nets = safe_parse(ip4_raw, "ip4")
ip6_nets = safe_parse(ip6_raw, "ip6")

merged4 = list(cidr_merge(ip4_nets)) if ip4_nets else []
merged6 = list(cidr_merge(ip6_nets)) if ip6_nets else []

print(f"  IP4 prima: {len(ip4_raw)}  dopo aggregazione: {len(merged4)}")
print(f"  IP6 prima: {len(ip6_raw)}  dopo aggregazione: {len(merged6)}")

parts = ["v=spf1"]
parts += [f"ip4:{n}" for n in merged4]
parts += [f"ip6:{n}" for n in merged6]
parts.append("~all")
print("RECORD:" + " ".join(str(p) for p in parts))
PYEOF
)

echo "$AGGREGATED" | grep -v "^RECORD:" || true

FINAL_RECORD=$(echo "$AGGREGATED" | grep "^RECORD:" | sed 's/^RECORD://')

echo ""
echo "╠══ RISULTATO FINALE ═══════════════════════════════════════════════════╣"
echo ""
echo "$FINAL_RECORD"
echo ""
echo "  Lunghezza record : ${#FINAL_RECORD} caratteri"
echo "  DNS lookup       : 0  (nessun include/redirect)"

if (( ${#FINAL_RECORD} > 450 )); then
    echo ""
    echo "  ATTENZIONE: Record > 450 caratteri. Alcuni MTA legacy potrebbero"
    echo "  avere problemi. Valuta di spezzarlo in due sottodomini SPF."
fi

echo ""
echo "╚═══════════════════════════════════════════════════════════════════════╝"

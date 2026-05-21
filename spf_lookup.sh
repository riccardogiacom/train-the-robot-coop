#!/bin/bash
# SPF resolver + CIDR aggregator
# Risolve ricorsivamente tutti gli include/redirect, deduplica gli IP,
# aggrega i CIDR sovrapposti e produce un record SPF piatto senza lookup.
#
# Requisiti: dig (sudo apt install dnsutils)
#            python3 + netaddr (pip3 install netaddr)

set -euo pipefail

# ── Controllo dipendenze ──────────────────────────────────────────────────────
if ! command -v dig &>/dev/null; then
    echo "ERRORE: dig non trovato. Installa con: sudo apt install dnsutils"
    exit 1
fi
if ! python3 -c "import netaddr" 2>/dev/null; then
    echo "ERRORE: netaddr non trovato. Installa con: pip3 install netaddr"
    exit 1
fi

# ── Domini di partenza ────────────────────────────────────────────────────────
ROOT_DOMAINS=(
    "spf.turbo-smtp.com"
    "zcsend.net"
    "sender.zohobooks.com"
    "one.zoho.eu"
)

declare -A VISITED
declare -a ALL_IPS

# ── Funzione ricorsiva ────────────────────────────────────────────────────────
resolve_spf() {
    local domain="$1"
    [[ -n "${VISITED[$domain]+x}" ]] && return
    VISITED[$domain]=1

    local txt
    txt=$(dig +short TXT "$domain" 2>/dev/null \
        | tr -d '"' | tr '\n' ' ' \
        | grep -io 'v=spf1[^"]*' | head -1)

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

# ── Fase 1: risoluzione ───────────────────────────────────────────────────────
echo ""
echo "╔══ FASE 1: risoluzione SPF ricorsiva ══════════════════════════════════╗"
for domain in "${ROOT_DOMAINS[@]}"; do
    echo ""
    echo "  [ROOT] $domain"
    resolve_spf "$domain"
done

# ── Fase 2: deduplicazione base ───────────────────────────────────────────────
mapfile -t DEDUPED < <(printf '%s\n' "${ALL_IPS[@]}" | sort -u)

echo ""
echo "╠══ FASE 2: deduplicazione ═════════════════════════════════════════════╣"
echo "  IP trovati (con duplicati) : ${#ALL_IPS[@]}"
echo "  IP dopo deduplicazione     : ${#DEDUPED[@]}"

# ── Fase 3: aggregazione CIDR ─────────────────────────────────────────────────
echo ""
echo "╠══ FASE 3: aggregazione CIDR ══════════════════════════════════════════╣"

AGGREGATED=$(python3 - "${DEDUPED[@]}" <<'PYEOF'
import sys
from netaddr import IPNetwork, cidr_merge

ips = sys.argv[1:]
ip4 = [ip for ip in ips if ":" not in ip]
ip6 = [ip for ip in ips if ":" in ip]

merged4 = cidr_merge([IPNetwork(i) for i in ip4]) if ip4 else []
merged6 = cidr_merge([IPNetwork(i) for i in ip6]) if ip6 else []

print(f"IP4 prima: {len(ip4)}  dopo aggregazione: {len(merged4)}")
print(f"IP6 prima: {len(ip6)}  dopo aggregazione: {len(merged6)}")

parts = ["v=spf1"]
parts += [f"ip4:{n}" for n in merged4]
parts += [f"ip6:{n}" for n in merged6]
parts.append("~all")
print("RECORD:" + " ".join(str(p) for p in parts))
PYEOF
)

echo "$AGGREGATED" | grep -v "^RECORD:"

FINAL_RECORD=$(echo "$AGGREGATED" | grep "^RECORD:" | sed 's/^RECORD://')

# ── Risultato finale ──────────────────────────────────────────────────────────
echo ""
echo "╠══ RISULTATO FINALE ═══════════════════════════════════════════════════╣"
echo ""
echo "$FINAL_RECORD"
echo ""
echo "  Lunghezza record : ${#FINAL_RECORD} caratteri"
echo "  DNS lookup       : 0  (nessun include/redirect)"

if (( ${#FINAL_RECORD} > 450 )); then
    echo ""
    echo "  ⚠  Record > 450 caratteri. Alcuni MTA legacy potrebbero avere"
    echo "     problemi. Valuta di spezzarlo in due sottodomini SPF con"
    echo "     al massimo 2 include: nel record principale."
fi

echo ""
echo "╚═══════════════════════════════════════════════════════════════════════╝"

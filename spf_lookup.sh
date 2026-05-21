#!/bin/bash
# SPF resolver + CIDR aggregator
# Uso:  bash spf_lookup.sh           → record piatto unico
#       bash spf_lookup.sh --split   → divide in due sottodomini (consigliato se > 450 chars)
#
# Requisiti: dig (sudo apt install dnsutils)
#            python3 + netaddr (pip3 install netaddr)

set -euo pipefail

SPLIT_MODE=false
[[ "${1:-}" == "--split" ]] && SPLIT_MODE=true

if ! command -v dig &>/dev/null; then
    echo "ERRORE: dig non trovato. Installa con: sudo apt install dnsutils"; exit 1
fi
if ! python3 -c "import netaddr" 2>/dev/null; then
    echo "ERRORE: netaddr non trovato. Installa con: pip3 install netaddr"; exit 1
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
    # dig TXT (senza +short) tiene tutti i chunk dello stesso record sulla stessa riga:
    #   example.com. 3600 IN TXT "parte1" "parte2"
    # sed rimuove i confini tra chunk prima di togliere le virgolette,
    # evitando spazi spuri nel mezzo degli indirizzi IPv6.
    dig TXT "$1" 2>/dev/null \
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
        echo "  [WARN] nessun record SPF per: $domain"; return
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

# ── FASE 1 ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══ FASE 1: risoluzione SPF ricorsiva ══════════════════════════════════╗"
for domain in "${ROOT_DOMAINS[@]}"; do
    echo ""; echo "  [ROOT] $domain"
    resolve_spf "$domain"
done

mapfile -t DEDUPED < <(printf '%s\n' "${ALL_IPS[@]}" | sort -u)

echo ""
echo "╠══ FASE 2: deduplicazione ═════════════════════════════════════════════╣"
echo "  IP trovati (con duplicati) : ${#ALL_IPS[@]}"
echo "  IP dopo deduplicazione     : ${#DEDUPED[@]}"

# ── FASE 3: aggregazione + output ─────────────────────────────────────────────
echo ""
echo "╠══ FASE 3: aggregazione CIDR ══════════════════════════════════════════╣"

python3 - "${SPLIT_MODE}" "${DEDUPED[@]}" <<'PYEOF'
import sys
from netaddr import IPNetwork, cidr_merge

split_mode = sys.argv[1] == "true"
ips = sys.argv[2:]

ip4_raw = [ip for ip in ips if ":" not in ip]
ip6_raw = [ip for ip in ips if ":" in ip]

def safe_parse(lst, label):
    nets = []
    for i in lst:
        try:
            nets.append(IPNetwork(i))
        except Exception as e:
            print(f"  [WARN] IP ignorato ({label}): {i!r} → {e}", file=sys.stderr)
    return nets

merged4 = list(cidr_merge(safe_parse(ip4_raw, "ip4"))) if ip4_raw else []
merged6 = list(cidr_merge(safe_parse(ip6_raw, "ip6"))) if ip6_raw else []
all_merged = [f"ip4:{n}" for n in merged4] + [f"ip6:{n}" for n in merged6]

print(f"  IP4 prima: {len(ip4_raw)}  dopo aggregazione: {len(merged4)}")
print(f"  IP6 prima: {len(ip6_raw)}  dopo aggregazione: {len(merged6)}")
print(f"  Totale range finali: {len(all_merged)}")

def make_record(tokens, suffix="~all"):
    return "v=spf1 " + " ".join(str(t) for t in tokens) + " " + suffix

SEP = "\n" + "─" * 72

if not split_mode:
    rec = make_record(all_merged)
    print(f"\n╠══ RISULTATO FINALE ═══════════════════════════════════════════════════╣")
    print(f"\n{rec}\n")
    print(f"  Lunghezza : {len(rec)} caratteri  |  DNS lookup: 0")
    if len(rec) > 450:
        print(f"\n  ATTENZIONE: > 450 caratteri.")
        print(f"  Riesegui con:  bash spf_lookup.sh --split")
    print(f"\n╚═══════════════════════════════════════════════════════════════════════╝")
else:
    # Dividere a metà cercando il punto di taglio che bilancia le lunghezze
    mid = len(all_merged) // 2
    spf1_tokens = all_merged[:mid]
    spf2_tokens = all_merged[mid:]

    rec1 = make_record(spf1_tokens)
    rec2 = make_record(spf2_tokens)
    # Il record principale usa 2 include (2 lookup DNS, ben sotto il limite di 10)
    main = "v=spf1 include:_spf1.TUODOMINIO.com include:_spf2.TUODOMINIO.com ~all"

    print(f"\n╠══ MODALITÀ SPLIT (2 lookup DNS totali) ═══════════════════════════════╣")
    print(f"\n  Sostituisci TUODOMINIO.com con il tuo dominio reale.")
    print(f"\n  Record principale (va sul dominio che manda mail):")
    print(f"  {main}")
    print(f"  ({len(main)} caratteri)\n")
    print(SEP)
    print(f"\n  TXT su _spf1.TUODOMINIO.com  ({len(rec1)} caratteri):")
    print(f"  {rec1}\n")
    print(SEP)
    print(f"\n  TXT su _spf2.TUODOMINIO.com  ({len(rec2)} caratteri):")
    print(f"  {rec2}\n")
    print(f"╚═══════════════════════════════════════════════════════════════════════╝")
PYEOF

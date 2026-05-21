#!/bin/bash
# SPF recursive resolver
# Usage: bash spf_lookup.sh
# Requires: dig (apt install dnsutils)

set -euo pipefail

if ! command -v dig &>/dev/null; then
    echo "ERROR: dig not found. Install it with: sudo apt install dnsutils" >&2
    exit 1
fi

declare -A VISITED
declare -a ALL_IPS

ROOT_DOMAINS=(
    "spf.turbo-smtp.com"
    "zcsend.net"
    "sender.zohobooks.com"
    "one.zoho.eu"
)

get_spf_txt() {
    local domain="$1"
    # +short may return multiple quoted strings per line; join them and strip quotes
    dig +short TXT "$domain" 2>/dev/null \
        | tr -d '"' \
        | tr '\n' ' ' \
        | grep -io 'v=spf1[^"]*' \
        | head -1
}

resolve_spf() {
    local domain="$1"

    [[ -n "${VISITED[$domain]+x}" ]] && return
    VISITED[$domain]=1

    local txt
    txt=$(get_spf_txt "$domain")

    if [[ -z "$txt" ]]; then
        echo "  [WARN] no SPF TXT found for: $domain" >&2
        return
    fi

    echo "  [SPF] $domain" >&2
    echo "        $txt" >&2

    # Parse tokens
    for token in $txt; do
        case "$token" in
            ip4:*|ip6:*)
                local ip="${token#*:}"
                ALL_IPS+=("$ip")
                ;;
            include:*)
                local inc="${token#include:}"
                echo "  [INC] $domain -> $inc" >&2
                resolve_spf "$inc"
                ;;
            redirect=*)
                local redir="${token#redirect=}"
                echo "  [RED] $domain -> $redir" >&2
                resolve_spf "$redir"
                ;;
            a:*|mx:*)
                echo "  [SKIP-DNS-LOOKUP] $token (kept as-is in final record if needed)" >&2
                ;;
        esac
    done
}

echo "=== Resolving SPF records ===" >&2
for domain in "${ROOT_DOMAINS[@]}"; do
    echo "[ROOT] $domain" >&2
    resolve_spf "$domain"
done

# Deduplicate preserving order (sort -u also works)
mapfile -t UNIQUE_IPS < <(printf '%s\n' "${ALL_IPS[@]}" | sort -u)

echo ""
echo "=== Unique IPs found (${#UNIQUE_IPS[@]}) ==="
for ip in "${UNIQUE_IPS[@]}"; do
    echo "$ip"
done

# Build flat SPF record
echo ""
echo "=== Suggested flat SPF record (0 DNS lookups) ==="
SPF_PARTS="v=spf1"
for ip in "${UNIQUE_IPS[@]}"; do
    if [[ "$ip" =~ : ]]; then
        SPF_PARTS+=" ip6:$ip"
    else
        SPF_PARTS+=" ip4:$ip"
    fi
done
SPF_PARTS+=" ~all"
echo ""
echo "$SPF_PARTS"
echo ""
echo "Record length : ${#SPF_PARTS} chars (max recommended ~450)"
echo "DNS lookups   : 0 (no includes/redirects)"
echo "Unique IPs    : ${#UNIQUE_IPS[@]}"

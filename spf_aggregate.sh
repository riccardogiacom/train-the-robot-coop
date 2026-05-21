#!/bin/bash
# Legge il record SPF generato da spf_lookup.sh e aggrega i CIDR sovrapposti
# Richiede: python3 (preinstallato su WSL), pacchetto netaddr
# Installa con: pip3 install netaddr

if ! python3 -c "import netaddr" 2>/dev/null; then
    echo "Installa netaddr: pip3 install netaddr" >&2
    exit 1
fi

if [[ -z "$1" ]]; then
    echo "Uso: bash spf_aggregate.sh \"v=spf1 ip4:... ip4:... ~all\""
    exit 1
fi

RECORD="$1"

python3 - "$RECORD" <<'PYEOF'
import sys
from netaddr import IPNetwork, cidr_merge

record = sys.argv[1]
tokens = record.split()

ip4_list = []
ip6_list = []
other = []

for t in tokens:
    if t.startswith("ip4:"):
        ip4_list.append(t[4:])
    elif t.startswith("ip6:"):
        ip6_list.append(t[4:])
    elif t not in ("v=spf1",) and not t.endswith("all"):
        other.append(t)

# Aggrega CIDR
try:
    merged4 = cidr_merge([IPNetwork(ip) for ip in ip4_list])
except Exception as e:
    print(f"Errore ip4: {e}", file=sys.stderr)
    merged4 = [IPNetwork(ip) for ip in ip4_list]

try:
    merged6 = cidr_merge([IPNetwork(ip) for ip in ip6_list])
except Exception as e:
    print(f"Errore ip6: {e}", file=sys.stderr)
    merged6 = [IPNetwork(ip) for ip in ip6_list]

parts = ["v=spf1"]
parts += [f"ip4:{n}" for n in merged4]
parts += [f"ip6:{n}" for n in merged6]
parts += other
parts.append("~all")

result = " ".join(str(p) for p in parts)

print(f"\n=== Prima: {len(sys.argv[1])} IP4={len(ip4_list)} IP6={len(ip6_list)} ===")
print(f"=== Dopo:  {len(result)} IP4={len(merged4)} IP6={len(merged6)} ===\n")
print(result)
PYEOF

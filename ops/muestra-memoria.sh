#!/bin/bash
CSV=/var/log/memoria-optica.csv
[ -f "$CSV" ] || echo "fecha;mem_used_mb;mem_available_mb;swap_used_mb;contenedores" > "$CSV"
L=$(free -m | awk '/^Mem:/{u=$3; a=$7} /^Swap:/{s=$3} END{print u";"a";"s}')
C=$(docker stats --no-stream --format '{{.Name}}={{.MemUsage}}' | tr '\n' '|')
echo "$(date -Is);$L;$C" >> "$CSV"

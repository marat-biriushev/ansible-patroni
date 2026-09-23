#!/bin/bash
# Проверка внутреннего зеркала PGDG с целевого хоста (RHEL 9/10).
# Использование: scripts/check_mirror.sh [mirror_base] [pg_major]
set -uo pipefail
BASE="${1:-http://mirror.ipotekabank.uz/repos}/postgre/yum"
PG="${2:-18}"
M=$(rpm -E %rhel)
A=$(uname -m)

declare -A REPOS=(
  [postgres${PG}]="${BASE}/${PG}/redhat/rhel-${M}-${A}/"
  [postgres-common]="${BASE}/common/redhat/rhel-${M}-${A}/"
  [postgres-extras]="${BASE}/common/pgdg-rhel${M}-extras/redhat/rhel-${M}-${A}/"
)

echo "== repodata (RHEL ${M}, ${A})"
available=()
for name in "${!REPOS[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${REPOS[$name]}repodata/repomd.xml")
  printf '%-16s HTTP %s  %s\n' "$name" "$code" "${REPOS[$name]}"
  [[ "$code" == "200" ]] && available+=("--repofrompath=${name},${REPOS[$name]}")
done

echo
echo "== packages"
if [[ ${#available[@]} -eq 0 ]]; then
  echo "Ни один репозиторий не доступен"
  exit 1
fi
for pkg in "postgresql${PG}-server" "postgresql${PG}-contrib" patroni patroni-etcd etcd pgbackrest pgbouncer; do
  found=$(dnf -q --disablerepo='*' "${available[@]}" --setopt='*.gpgcheck=0' \
          repoquery --latest-limit=1 --qf '%{name}-%{version}-%{release} [%{repoid}]' "$pkg" 2>/dev/null)
  printf '%-24s %s\n' "$pkg" "${found:-НЕ НАЙДЕН}"
done

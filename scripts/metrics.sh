#!/usr/bin/env bash
# How many people run Container Desktop, and which version.
#
# Reads the D1 database behind the appcast Worker. "Active" means the install
# checked for updates in the last 30 days — one that stopped checking has most
# likely been deleted, and counting it for ever would only inflate the number.
#
# Needs `wrangler login` once. Queries cost rows read, not writes.
set -euo pipefail

cd "$(dirname "$0")/../metrics"
DB=containerdesktop-installs

# wrangler prints its own banner and wraps results in metadata; only the rows
# are interesting, so the JSON is formatted here rather than shown raw.
query() {
    npx --yes wrangler d1 execute "$DB" --remote --json --command "$1" 2>/dev/null \
        | python3 -c '
import sys, json
rows = json.load(sys.stdin)[0]["results"]
if not rows:
    print("  (brak danych)")
    sys.exit()
headers = list(rows[0])
widths = [max(len(h), *(len(str(r[h])) for r in rows)) for h in headers]
line = "  " + "  ".join(h.replace("_", " ").ljust(w) for h, w in zip(headers, widths))
print(line)
print("  " + "  ".join("─" * w for w in widths))
for r in rows:
    print("  " + "  ".join(str(r[h]).ljust(w) for h, w in zip(headers, widths)))
'
}

echo
echo "Ilu ludzi używa programu"
query "SELECT
         COUNT(*)                                    AS lacznie,
         SUM(last_seen > datetime('now','-30 day'))  AS aktywne_30d,
         SUM(last_seen > datetime('now','-7 day'))   AS aktywne_7d,
         SUM(first_seen > datetime('now','-30 day')) AS nowe_30d
       FROM installs"

echo
echo "Jaka wersja (aktywne w 30 dniach)"
query "SELECT version AS wersja, COUNT(*) AS ile
       FROM installs WHERE last_seen > datetime('now','-30 day')
       GROUP BY version ORDER BY ile DESC"

echo
echo "Jaki macOS (aktywne w 30 dniach)"
query "SELECT COALESCE(os,'?') AS macos, COUNT(*) AS ile
       FROM installs WHERE last_seen > datetime('now','-30 day')
       GROUP BY os ORDER BY ile DESC"
echo

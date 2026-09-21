#!/usr/bin/env bash
# How many people run Container Desktop, and which version.
#
# Reads the D1 database behind the appcast Worker. "Active" means the install
# checked for updates in the last 30 days — an install that stopped checking has
# most likely been deleted, and counting it for ever would only inflate the
# number.
#
# Needs `wrangler login` once. Queries run against the deployed database, so
# they cost rows read, not writes.
set -euo pipefail

cd "$(dirname "$0")/../metrics"

DB=containerdesktop-installs
run() { npx --yes wrangler d1 execute "$DB" --remote --command "$1"; }

echo "── Ilu ludzi używa programu ─────────────────────────────"
run "SELECT
       COUNT(*)                                                    AS instalacje_lacznie,
       SUM(last_seen > datetime('now','-30 day'))                  AS aktywne_30_dni,
       SUM(last_seen > datetime('now','-7 day'))                   AS aktywne_7_dni,
       SUM(first_seen > datetime('now','-30 day'))                 AS nowe_w_30_dni
     FROM installs"

echo
echo "── Jaką wersję (aktywne w 30 dniach) ────────────────────"
run "SELECT version AS wersja, COUNT(*) AS ile
     FROM installs
     WHERE last_seen > datetime('now','-30 day')
     GROUP BY version
     ORDER BY ile DESC"

echo
echo "── Na jakim macOS ───────────────────────────────────────"
run "SELECT COALESCE(os,'?') AS macos, COUNT(*) AS ile
     FROM installs
     WHERE last_seen > datetime('now','-30 day')
     GROUP BY os
     ORDER BY ile DESC"

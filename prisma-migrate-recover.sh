#!/bin/bash
# Recover from Prisma P3018 when schema objects exist but migrate history is out of sync (legacy db push).
# Usage: sudo bash prisma-migrate-recover.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

beeshost_source_env || exit 1
export BEESHOST_PRISMA_MODE=update

pg=/opt/beeshost/postgres
prisma_bin="$pg/node_modules/.bin/prisma"

section "Prisma migration recovery"
beeshost_prisma_migrate_auto_resolve "$pg" "$prisma_bin" || warn "Nothing to auto-resolve"
beeshost_prisma_run_in_pg "$pg" "$prisma_bin" migrate deploy
ok "Done. If errors remain: cd $pg && npx prisma migrate status"

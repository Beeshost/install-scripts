#!/usr/bin/env bash
# Fresh npm install (with devDependencies), prisma generate where needed, build, and test
# for every Node package under ./backend except backend/.continue and backend/tmp.
#
# Usage (from repo root or any cwd):
#   bash scripts/backend-fresh-ci.sh
#   SKIP_TESTS=1 bash scripts/backend-fresh-ci.sh   # build only

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BACKEND="$REPO_ROOT/backend"

if [ ! -d "$BACKEND" ]; then
  echo "ERROR: expected backend directory at $BACKEND" >&2
  exit 1
fi

export CI=true

run_pkg() {
  local dir=$1
  local label=$2

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " $label"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  (
    cd "$dir"
    rm -rf node_modules
    if [ -f package-lock.json ]; then
      npm ci --include=dev
    else
      npm install --include=dev
    fi
    if [ -f prisma/schema.prisma ] && grep -q '"generate"' package.json; then
      npm run generate
    fi
    if grep -q '"build"' package.json; then
      npm run build
    fi
    if [ "${SKIP_TESTS:-0}" != 1 ] && grep -q '"test"' package.json; then
      npm test
    fi
  )
}

count=0
while IFS= read -r -d '' pkg; do
  count=$((count + 1))
  dir=$(dirname "$pkg")
  rel="${dir#$BACKEND/}"
  run_pkg "$dir" "$rel"
done < <(find "$BACKEND" \
  \( -path "$BACKEND/.continue/*" -o -path "$BACKEND/tmp/*" -o -path "*/node_modules/*" \) -prune -o \
  -name package.json -print0 | sort -z)

if [ "$count" -eq 0 ]; then
  echo "ERROR: no package.json found under $BACKEND" >&2
  exit 1
fi

echo ""
echo "OK: all backend packages processed ($count)."

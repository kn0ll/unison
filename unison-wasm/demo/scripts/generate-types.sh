set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/../dist"

mkdir -p "$DIST_DIR"

echo "⏳ Generating types"
LANG=C.UTF-8 LC_ALL=C.UTF-8 stack exec unison-wasm-poc -- \
    generate-types \
    'calculatePrice:bigint,bigint->[bigint,bigint,bigint]' \
    > "$DIST_DIR/bundle.d.ts" || {
  echo "Error: Type generation failed"
  exit 1
}

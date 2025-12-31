set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WASM_DIR="$SCRIPT_DIR/../../"
DIST_DIR="$SCRIPT_DIR/../dist"
CODEBASE_DIR="$SCRIPT_DIR/../.unison"

# Ensure dist directory exists
mkdir -p "$DIST_DIR"


cd "$WASM_DIR"

# Compile calculatePrice from codebase
echo "⏳ Compiling codebase"
LANG=C.UTF-8 LC_ALL=C.UTF-8 stack exec unison-wasm-poc -- \
    compile-codebase \
    --codebase "$CODEBASE_DIR" \
    --project demo \
    --branch main \
    calculatePrice > "$DIST_DIR/bundle.wat" || {
  echo "Error: Compilation failed"
  exit 1
}

wat2wasm "$DIST_DIR/bundle.wat" -o "$DIST_DIR/bundle.wasm"

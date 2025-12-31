set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WASM_DIR="$SCRIPT_DIR/../../"

echo "⏳ Installing wabt"
if ! command -v wat2wasm &> /dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq wabt
fi

echo "⏳ Building CLI"
cd "$WASM_DIR"
LANG=C.UTF-8 LC_ALL=C.UTF-8 stack build unison-wasm:exe:unison-wasm-poc --fast 2>/dev/null || {
  echo "Error: Could not build unison-wasm-poc"
  exit 1
}

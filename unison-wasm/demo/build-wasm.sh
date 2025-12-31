#!/bin/bash
# build-wasm.sh
# Compiles pricing functions from Unison to WASM
#
# This script:
# 1. Creates a Unison codebase from src/pricing.u (if needed)
# 2. Compiles all pricing functions (calculatePrice, calculateDiscount, calculateSubtotal)
# 3. Converts to WASM binary using wat2wasm (if available)

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WASM_DIR="$SCRIPT_DIR/.."
DIST_DIR="$SCRIPT_DIR/dist"
CODEBASE_DIR="$SCRIPT_DIR/.unison"

# Ensure dist directory exists
mkdir -p "$DIST_DIR"

echo "Building WASM module from Unison pricing functions..."

# Build the CLI if needed
cd "$WASM_DIR"
echo "  Building unison-wasm-poc..."
LANG=C.UTF-8 LC_ALL=C.UTF-8 stack build unison-wasm:exe:unison-wasm-poc --fast 2>/dev/null || {
  echo "Error: Could not build unison-wasm-poc"
  exit 1
}

# Always recreate codebase to pick up pricing.u changes
echo "  Creating demo codebase..."
cd "$SCRIPT_DIR"
rm -rf "$CODEBASE_DIR" setup-codebase.output.md
unison transcript --save-codebase-to "$CODEBASE_DIR" setup-codebase.md >/dev/null 2>&1 || {
  echo "Error: Could not create codebase"
  exit 1
}

cd "$WASM_DIR"

# Compile all pricing functions from codebase
echo "  Compiling pricing functions from codebase..."
LANG=C.UTF-8 LC_ALL=C.UTF-8 stack exec unison-wasm-poc -- \
    compile-codebase \
    --codebase "$CODEBASE_DIR" \
    --project demo \
    --branch main \
    calculatePrice calculateDiscount calculateSubtotal calculatePriceWithDelay > "$DIST_DIR/pricing.wat" || {
  echo "Error: Compilation failed"
  exit 1
}
echo "  ✓ Compiled pricing functions to $DIST_DIR/pricing.wat"

# Convert WAT to WASM binary (if wat2wasm available)
if command -v wat2wasm &>/dev/null; then
  echo "  Converting to WASM binary..."
  wat2wasm "$DIST_DIR/pricing.wat" -o "$DIST_DIR/pricing.wasm"
  echo "  ✓ Created $DIST_DIR/pricing.wasm"
else
  echo "  Note: wat2wasm not found, skipping binary conversion"
  echo "        Install wabt for binary output: brew install wabt (macOS)"
fi

echo ""
echo "Build complete!"
echo "  WAT: $DIST_DIR/pricing.wat"
[ -f "$DIST_DIR/pricing.wasm" ] && echo "  WASM: $DIST_DIR/pricing.wasm"

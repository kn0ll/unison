set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEBASE_DIR="$SCRIPT_DIR/.unison"

# Always recreate codebase to pick up pricing.u changes
echo "⏳ Creating demo codebase..."
cd "$SCRIPT_DIR"
rm -rf "$CODEBASE_DIR" setup-codebase.output.md
unison transcript --save-codebase-to "$CODEBASE_DIR" setup-codebase.md >/dev/null 2>&1 || {
  echo "Error: Could not create codebase"
  exit 1
}
echo "✅ Created demo codebase"


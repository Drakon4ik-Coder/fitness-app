#!/usr/bin/env sh
set -e

HOOK_DIR=".git/hooks"
HOOK_PATH="$HOOK_DIR/pre-push"

mkdir -p "$HOOK_DIR"

cat > "$HOOK_PATH" <<'EOF'
#!/usr/bin/env sh
set -e

echo "==> pre-push: make check"
make check
EOF

chmod +x "$HOOK_PATH"

echo "Installed pre-push hook at $HOOK_PATH"
echo "To remove: rm $HOOK_PATH"

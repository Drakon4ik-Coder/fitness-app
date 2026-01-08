#!/usr/bin/env sh
set -e

HOOK_DIR=".git/hooks"
HOOK_PATH="$HOOK_DIR/pre-push"
HOOK_MARKER="# fitness-app pre-push hook: run make check"

mkdir -p "$HOOK_DIR"

if [ -f "$HOOK_PATH" ]; then
  if grep -q "$HOOK_MARKER" "$HOOK_PATH"; then
    echo "Pre-push hook already installed at $HOOK_PATH"
    exit 0
  fi
  BACKUP_PATH="${HOOK_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$HOOK_PATH" "$BACKUP_PATH"
  echo "Existing pre-push hook found; backed up to $BACKUP_PATH"
fi

cat > "$HOOK_PATH" <<'EOF'
#!/usr/bin/env sh
set -e

## fitness-app pre-push hook: run make check
echo "==> pre-push: make check"
make check
EOF

chmod +x "$HOOK_PATH"

echo "Installed pre-push hook at $HOOK_PATH"
echo "To remove: rm $HOOK_PATH"

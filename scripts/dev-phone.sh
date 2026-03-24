#!/usr/bin/env bash
# dev-phone.sh — Start backend + run Flutter on a wirelessly-connected phone.
# Usage: ./scripts/dev-phone.sh
#
# Prerequisites:
#   1. Phone and PC on the same WiFi network
#   2. Phone paired via `adb pair <ip>:<port>` (one-time)
#   3. avahi-utils installed (sudo apt install avahi-utils) — optional but enables auto-connect

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Use Google's ADB if available (Debian's has broken wireless pairing)
if [[ -x "$HOME/Android/Sdk/platform-tools/adb" ]]; then
  ADB="$HOME/Android/Sdk/platform-tools/adb"
else
  ADB="$(command -v adb)"
fi
echo "🔧 Using ADB: $($ADB version | head -1) ($ADB)"

# ---------- auto-discover & connect phone ----------
auto_connect_phone() {
  # Method 1: Check if already connected
  if $ADB devices | grep -q "device$"; then
    echo "📱 Phone already connected"
    return 0
  fi

  # Method 2: mDNS discovery via avahi-browse
  if command -v avahi-browse &> /dev/null; then
    echo "🔍 Scanning for wireless debugging devices (5s)..."
    local mdns_output
    mdns_output=$(timeout 5 avahi-browse -rpt _adb-tls-connect._tcp 2>/dev/null || true)
    
    if [[ -n "$mdns_output" ]]; then
      # Parse: =;interface;protocol;name;type;domain;hostname;address;port;txt
      local phone_ip phone_port
      phone_ip=$(echo "$mdns_output" | grep "^=" | head -1 | cut -d';' -f8)
      phone_port=$(echo "$mdns_output" | grep "^=" | head -1 | cut -d';' -f9)
      
      if [[ -n "$phone_ip" && -n "$phone_port" ]]; then
        echo "📡 Found device at $phone_ip:$phone_port via mDNS"
        $ADB connect "$phone_ip:$phone_port" 2>/dev/null && return 0
      fi
    fi
  fi

  # Method 3: ADB mdns services (built-in, ADB 35+)
  local adb_mdns
  adb_mdns=$($ADB mdns services 2>/dev/null || true)
  if echo "$adb_mdns" | grep -q "adb-tls-connect"; then
    local svc_line
    svc_line=$(echo "$adb_mdns" | grep "adb-tls-connect" | head -1)
    # Format varies but typically: <name>  _adb-tls-connect._tcp  <ip>:<port>
    local target
    target=$(echo "$svc_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+')
    if [[ -n "$target" ]]; then
      echo "📡 Found device at $target via ADB mDNS"
      $ADB connect "$target" 2>/dev/null && return 0
    fi
  fi

  return 1
}

if ! auto_connect_phone; then
  echo ""
  echo "📱 No phone found automatically."
  echo ""
  # Interactive fallback: ask for IP:port
  echo "   Options:"
  echo "   1. Enter the IP:port from your phone's Wireless Debugging screen"
  echo "   2. Press Ctrl+C to cancel"
  echo ""
  read -rp "   Phone IP:port (e.g. 192.168.1.133:33487): " phone_addr
  if [[ -n "$phone_addr" ]]; then
    $ADB connect "$phone_addr"
  fi
  
  # Final check
  if ! $ADB devices | grep -q "device$"; then
    echo ""
    echo "❌ Still no device. Make sure:"
    echo "   - Phone has Wireless debugging enabled"
    echo "   - Phone is paired: adb pair <ip>:<pairing-port>"
    echo "   - Phone and PC are on the same WiFi"
    echo ""
    echo "   Install avahi-utils for auto-discovery: sudo apt install avahi-utils"
    exit 1
  fi
fi

PHONE_LINE=$($ADB devices | grep "device$" | head -1)
echo "✅ Connected: $PHONE_LINE"

# ---------- detect LAN IP ----------
LAN_IP="${LAN_IP:-}"
if [[ -z "$LAN_IP" ]]; then
  LAN_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
fi
if [[ -z "$LAN_IP" ]]; then
  LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [[ -z "$LAN_IP" ]]; then
  echo "❌ Could not detect LAN IP. Set it manually:"
  echo "   LAN_IP=192.168.x.x $0"
  exit 1
fi
echo "🌐 PC LAN IP: $LAN_IP"

# ---------- start backend ----------
echo "🐳 Starting backend services..."
docker compose -f "$REPO_ROOT/docker-compose.yml" up --build -d

echo "⏳ Waiting for backend on :8080..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:8080/health/" > /dev/null 2>&1; then
    echo "✅ Backend is up at http://$LAN_IP:8080"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "❌ Backend did not start in time. Check: docker compose logs backend"
    exit 1
  fi
  sleep 1
done

# ---------- run Flutter ----------
echo "🚀 Launching Flutter app → API at http://$LAN_IP:8080"
cd "$REPO_ROOT/apps/mobile"
flutter run --dart-define="API_BASE_URL=http://$LAN_IP:8080"

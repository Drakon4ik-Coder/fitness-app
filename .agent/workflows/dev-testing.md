---
description: How to test the app on PC (localhost) and on a physical phone via wireless debugging
---

# Dev Testing Workflow

## Option A — PC only (emulator or Chrome)

// turbo
1. Start backend services:
```bash
make up
make migrate   # first time only
```

2. Run Flutter on Android emulator (uses `10.0.2.2` to reach host):
```bash
cd apps/mobile && flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

Or use the shortcut:
```bash
make dev-local
```

---

## Option B — Physical phone over WiFi (wireless debugging)

### One-time setup

1. **Use Google's ADB** (the Debian `adb` package has broken wireless pairing):
   ```bash
   # Should already exist at ~/Android/Sdk/platform-tools/adb
   # Add to ~/.bashrc for persistence:
   echo 'export PATH="$HOME/Android/Sdk/platform-tools:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```

2. **Install avahi-utils** for auto-discovery (optional but recommended):
   ```bash
   sudo apt install -y avahi-utils
   ```

3. **Disable AP/client isolation** on your router if phone and PC can't ping each other.

4. **Enable Developer Options** on your phone:
   - Go to Settings → About phone → Tap "Build number" 7 times

5. **Enable Wireless debugging**:
   - Settings → Developer options → Wireless debugging → ON

6. **Pair your phone** (one-time per network):
   - Tap "Pair device with pairing code" on the phone
   - On PC, run:
     ```bash
     adb pair <phone-ip>:<pairing-port>
     ```
   - Enter the 6-digit code shown on your phone

### Daily testing

// turbo
Run the all-in-one script (auto-discovers phone via mDNS, falls back to interactive prompt):
```bash
make dev-phone
```

This will:
1. Auto-detect the phone via mDNS (if avahi-utils installed) or ADB mdns
2. Fall back to asking you for IP:port if auto-discovery fails
3. Start the Docker backend
4. Wait for backend health check
5. Launch Flutter on your phone with the correct `API_BASE_URL`

### Manual steps (if you prefer)

// turbo
1. Start backend:
```bash
make up
```

2. Find your PC's LAN IP:
```bash
ip route get 1 | awk '{print $7; exit}'
```

3. Connect phone (get IP:port from phone's Wireless Debugging screen):
```bash
adb connect <phone-ip>:<port>
```

4. Run Flutter:
```bash
cd apps/mobile
flutter run --dart-define=API_BASE_URL=http://<your-lan-ip>:8080
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `Unable to start pairing client` | Use Google's ADB (`~/Android/Sdk/platform-tools/adb`), not Debian's `/usr/bin/adb` |
| Phone can't reach backend / 100% packet loss | Disable AP/client isolation on your router |
| `ERR_CLEARTEXT_NOT_PERMITTED` | Rebuild: `flutter clean && flutter run ...` |
| ADB disconnects | Re-run `adb connect <phone-ip>:<port>` or re-run `make dev-phone` |
| Backend not starting | Check `docker compose logs backend` |
| Wrong API URL on phone | Override with `LAN_IP=x.x.x.x ./scripts/dev-phone.sh` |

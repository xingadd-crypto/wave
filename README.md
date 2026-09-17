# Wave

Wave is a decentralized **P2P instant messenger** built on **iroh**. Messages, files, and voice all travel through direct peer-to-peer connections with no central server — only friend discovery relies on an optional Moon discovery service.

Cross-platform: **Android** and **Windows**. The same identity works on both platforms simultaneously, with version interoperability and mutual update delivery.

---

## Key Features

### Messaging
- **Text messages**: three-state delivery status — sending → delivered → read.
- **Image messages**: send and receive photos directly from the chat input — picker integration, automatic compression and thumbnail generation for fast transfer, and tap for full-screen preview with pinch-to-zoom.
- **File transfer**: chunked transfer with live progress.
  - The receiver always gets an **Accept / Reject** dialog with the option to choose a save location — files are never silently written to disk.
  - The sender can **cancel** mid-transfer; a cancelled message is marked failed and never auto-retried.
  - After delivery you can **open the file** or **open its containing folder** (Windows).
- **Voice messages**: G.711 μ-law encoding, unread red-dot indicator, tap to play/pause.
- **Voice calls**: real-time P2P calls with call/answer/reject/busy/hang-up states and a live call timer UI.

### Friends
- **QR-code add-friend**: scan a friend's QR code to exchange identities (one successful scan makes both sides friends).
- **Ultrasonic add-friend**: exchange identities over sound for close-proximity setups (where screen sharing is impractical).
- **Online presence**: real-time peer-to-peer probing — only reciprocal friends are shown as online; strangers always appear offline, with status-change notifications.
- Contact management: add/remove friends, view contact details and status.

### Moments
- Publish posts with text + images; images are fetched on demand; friends' posts are pushed in real time with offline caching.

### Update Distribution
- Friends can send each other **update packages** (`wave_*.zip`) with automatic platform/version matching — only the exact version the package declares is accepted.
- Incoming packages are **validated for platform, version, and path safety** before the user confirms extraction and installation; the app restarts to complete the update.

### Email Vault
- IMAP-based email sync and encrypted archiving (`enough_mail` + AES), with searchable webmail import and export/restore.

### Other
- **Message persistence**: SQLite-backed local storage for history, friends, and file indexes — nothing is lost on restart.
- **Notifications & background service**: foreground service + local notifications keep incoming calls and file transfers working in the background / off-screen (Android).
- **Identity security**: Ed25519 signatures + BLAKE3 hashing + iroh end-to-end encrypted channels; all P2P payloads are signed and encrypted.
- Incoming files are hash-verified; corrupted transfers are retried automatically.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Cross-platform framework | Flutter (Material 3) |
| P2P transport | iroh (QUIC hole-punching, Ed25519 identities, end-to-end encryption) |
| State management | flutter_riverpod |
| Database | SQLite (persistence_service) |
| Voice calls / recording | custom `wave_audio` native plugin (WASAPI / AAudio) + G.711 codec |
| Ultrasonic | `ggwave_native` plugin (DPSK audio encoding) |
| Email | enough_mail (IMAP) |
| Crypto | cryptography (AES), blake3_dart, flutter_secure_storage |
| Notifications | flutter_local_notifications + flutter_foreground_task |

---

## Building

```bash
# Windows (requires Visual Studio 17+ Build Tools with the C++ desktop workload)
flutter build windows --release

# Android (split per-ABI builds)
flutter build apk --release --split-per-abi
# Artifacts land in build/app/outputs/flutter-apk/
```

> ⚠️ Windows note: if `build/windows/x64/runner/Release` only produces the exe (missing runtime DLLs/data), delete `build/windows/x64/CMakeCache.txt` and rebuild to get a complete release package.

---

## Releases

Each version is published to GitHub Releases with 4 artifacts:

- `wave-<version>-windows.zip` — complete Windows portable bundle
- `wave-<version>-arm64.apk` / `armv7.apk` / `x86_64.apk` — Android per-architecture packages

## Project Layout

```
lib/
  screens/     # chat, contacts, moments, email, settings UI
  services/    # iroh P2P, file transfer, calls, updates, email core logic
  models/      # message / friend / file-transfer data models
  providers/   # Riverpod state management
  widgets/     # chat bubbles, waveforms, and other chat components
plugins/       # custom native plugins (wave_audio, ggwave_native)
```
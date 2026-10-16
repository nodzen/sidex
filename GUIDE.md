# sidex beginner guide

`sidex` installs any `.ipa` on your iPhone with just your Mac and a free Apple
ID — no Sideloadly, no AltStore server, no paid account. It uses Xcode's own
login, so third-party outages don't affect it.

## Minimum versions

| Thing | Minimum | Notes |
|---|---|---|
| Mac | macOS 13.5+ | Intel and Apple Silicon |
| Xcode | **15+**, full app (not CLT-only) | Free from the App Store. Tested on 27.0; older devicectl syntax may differ |
| iPhone | iOS 15+ (tested on 27.2) | Beta iOS needs matching beta Xcode, see below |
| Apple ID | free is fine | Paid works too (fewer limits) |

No `devicectl` below Xcode 15 (Monterey and earlier) — that Mac can't run this.

## Before you run (one-time, ~10 min)

1. **Install Xcode** from the App Store and open it once.
2. **Log in:** Xcode → Settings → Accounts → `+` → Apple ID.
3. **Connect iPhone** via USB (Wi-Fi works once paired). Tap **Trust**, keep it
   **unlocked**.
4. **Developer Mode:** iPhone → Settings → Privacy & Security → Developer Mode → ON.
   (Needed since iOS 16. Reboot if you just enabled it.)

## Run it

```bash
/bin/bash sidex /path/to/app.ipa
```

No path? Run `/bin/bash sidex` — a menu appears, and you can **drag & drop**
the `.ipa` into the terminal.

What happens (~5 min, all automatic):

```
==> Device: 00008150-00100D91028A401C
==> Team: XXXXXXXXXX
==> App: com.example.app
==> New ID: com.example.app.XXXXXXXXXX    # or "Already installed, updating"
  ok app / ok Widget / ...                # one profile per bundle
==> Profile valid until: 2026-10-19...    # free profiles live 7 days
Launched application ...                  # installed and started
```

Already installed? It **updates in place** — data is kept.

## The one GUI step (fallback only)

If Apple doesn't see a fresh device in your team you'll get:

> Apple still does not see the device in your team. Fallback: open …/StubApp.xcodeproj in Xcode, select your team, destination = your iPhone, press Run once, then re-run this script.

Do that once per new device, then re-run. Never needed again.

## Weekly refresh

Free profiles expire after **7 days** — the app stops opening. Just re-run the
same command; data is kept.

## Options

- `--keep-watch` — keep the Watch app. Stripped by default (free accounts can't
  sign it).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Xcode 15+ required` | Install full Xcode from the App Store (not CLT) |
| `No iPhone found` | Cable/Wi-Fi, Trust tapped, phone unlocked; same network for Wi-Fi |
| `Failed to mint profile for …` | Read Apple's error: device not registered (GUI step above) or App ID quota full (below) |
| `not enough available app IDs` | Free teams get ~10 App IDs. Reinstalling reuses them; new apps exhaust the quota |
| Pairing hangs on `Unlock the iPhone…` | Unlock the phone, stay on the Home Screen, tap **Trust**. Works on a clean Mac, no sudo |
| sudo asked / `Operation not permitted` | Only the `/var/db/lockdown` fallback needs Full Disk Access (sudo doesn't bypass it): enable it for your terminal app, quit (Cmd+Q), reopen, retry |
| Beta iOS + stable Xcode | Install matching beta Xcode, `sudo xcode-select -s`, re-run |
| Widget/extension dead | It needs a capability free profiles can't grant — the app installs, that feature degrades |
| No notifications | Normal: no push entitlements on free accounts |

## FAQ

**Windows/Linux?** No — needs Xcode by design.

**Jailbreak / warranty?** No. Standard free-tier dev signing, like Xcode does.

**3-app limit?** Free IDs keep ~3 apps at once. `sidex apps` shows the count;
iOS refuses a 4th — delete one on the phone and retry.

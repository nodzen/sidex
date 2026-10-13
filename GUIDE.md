# sidex beginner guide

`sidex` installs any `.ipa` on your iPhone using only your Mac and a free Apple ID.
No Sideloadly, no AltStore server, no Anisette, no paid account. If those tools are
down (or you just don't trust them), this still works — because it uses Apple's
own client (Xcode) instead of third-party login flows.

## Minimum versions

| Thing | Minimum | Notes |
|---|---|---|
| Mac | anything running macOS 13.5+ (Ventura) | Intel and Apple Silicon both fine |
| Xcode | **15+**, full app (not CLT-only) | Free from the App Store, ~7–15 GB download. Tested on 27.0; older 15.x–25.x should work but devicectl syntax varied across versions — report breakage |
| iPhone | iOS 17+ recommended (16 best-effort) | Beta iOS needs matching/beta Xcode, see below |
| Apple ID | free is fine | Paid also works (fewer limits) |

Older Macs that can't run Xcode 15 (stuck on Monterey or earlier) cannot use this —
there is no `devicectl` there. That's a hard wall, not a bug.

## Before you run (one-time, ~10 min)

1. **Install Xcode** from the App Store and open it once.
2. **Log in:** Xcode → Settings → Accounts → `+` → Apple ID. Any Apple ID works,
   burner included.
3. **Connect iPhone** via USB (Wi-Fi works too once paired). Tap **Trust** on the
   phone, keep it **unlocked**.
4. **Developer Mode:** iPhone → Settings → Privacy & Security → Developer Mode → ON.
   (Required since iOS 16 to run self-signed apps. Reboot if you just enabled it.)

## Run it

```bash
/bin/bash sidex /path/to/app.ipa
```

No path? Just run `/bin/bash sidex` — it asks, and you can **drag & drop**
the `.ipa` file straight into the terminal window, then press Enter.

What happens (all automatic, ~5 min):

```
==> Device: 00008150-00100D91028A401C     # your iPhone, found by itself
==> Team: XXXXXXXXXX                      # your Team ID, found by itself
==> App: com.example.app
==> New ID: com.example.app.XXXXXXXXXX    # or "Already installed, updating"
  ok app / ok Widget / ...                # one provisioning profile per bundle
==> Certificate: Apple Development: ...   # created in your keychain if missing
==> Done: .../signed.ipa
==> Profile valid until: 2026-10-19...    # free profiles live 7 days
Launched application ...                  # installed and started on your phone
```

If the app was already installed, it **updates in place** — data is kept.

## The one GUI step (only if asked)

Sometimes Apple doesn't see a freshly connected device yet. The script will say:

> Apple does not see the device in your team. Open …/StubApp.xcodeproj in Xcode,
> select your team, destination=iPhone, press Run once, then re-run this script.

Do exactly that (a throwaway blank app builds and registers the device), then run
the script again. You do this once per new device, never again.

## Weekly refresh

Free provisioning profiles expire after **7 days** — then the app stops opening.
That's Apple's rule for everyone (Sideloadly apps die the same way). Just run the
same command again; it re-issues profiles and updates the app, data is kept.

## Options

- `--keep-watch` — keep the Apple Watch app inside the IPA. Removed by default:
  free accounts cannot sign it and it breaks installation. You don't need it on
  the phone anyway.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Xcode 15+ required` | Install/update full Xcode from the App Store (not CLT) |
| `No iPhone found` | Cable/Wi-Fi, Trust tapped, phone unlocked; same network for Wi-Fi |
| `Failed to mint profile for …` + Apple error text | Read the Apple error: usually device not registered (do the one GUI Run above) or App ID quota full (see below) |
| `not enough available app IDs` | Free teams get ~10 App IDs, no web UI to delete them. Reinstalling the same apps reuses IDs; constantly new apps exhaust the quota |
| Beta iOS + stable Xcode: device unsupported | Install matching beta Xcode (free), switch with `sudo xcode-select -s`, re-run |
| App installs but a widget/extension is dead | That extension needs a capability free profiles can't grant (App Groups etc.) — install works, that feature degrades |
| No notifications ever | Normal on free accounts: Apple doesn't issue push entitlements without paid membership |

## FAQ

**Windows/Linux?** No — this needs Xcode by design.

**Why not Sideloadly/AltStore?** Those are great when their servers work. They log
into Apple through emulated third-party flows; when Apple tightens that endpoint,
they all break at once. `sidex` uses Xcode's genuine session, so server outages
don't affect it.

**Is this a jailbreak / does it void warranty?** No. It's standard free-tier
development signing — the same thing Xcode does with your own apps.

**3-app limit?** Free Apple IDs can keep ~3 sideloaded apps installed at once.
The script tells you nothing about it — iOS will refuse a 4th. Delete something
on the phone and retry.

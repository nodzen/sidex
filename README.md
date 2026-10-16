# sidex

Install any `.ipa` on your iPhone with a **free Apple ID** — using only Xcode.
No third-party servers, no Anisette, no signing services.

## Why

Tools like Sideloadly, AltStore and iLoader log into Apple through GrandSlam with
emulated Anisette. Whenever Apple tightens that endpoint, they all break at once
— and you're stuck waiting for an update. `sidex` takes the boring road instead:
Apple's own client (Xcode) with your own login. There is no third-party login to
block, so server outages don't affect it.

## Install

```bash
git clone https://github.com/nodzen/sidex.git
cd sidex
/bin/bash sidex /path/to/app.ipa
```

No arguments? You get a menu — install an app, export a certificate or push a
pairing file. For install you can **drag & drop** the `.ipa` into the terminal.

New to this? Follow **[GUIDE.md](GUIDE.md)** step by step (Xcode setup, Developer
Mode, troubleshooting).

## Requirements

- macOS + full **Xcode 15+** with your Apple ID logged in (`Xcode → Settings → Accounts`)
- iPhone connected (USB or same Wi-Fi), unlocked. Trust is no longer a step:
  if the iPhone is not paired, sidex pairs it itself (see below).
- Nothing else. No Homebrew packages, no Python, no paid account — sidex
  compiles its own tiny native helper (`sidex-helper.swift`) with Xcode's
  `swiftc` on first use — **one time only** (≈1 s on a MacBook Air M5) — then
  it is cached by source hash next to the repo in `helper-cache/`
  (gitignored, one copy — old builds are pruned automatically) and every later run
  picks it up instantly.

> Tested on Xcode 27.0 + iOS 27.2. The gate is Xcode 15+ (`devicectl` era), but
> older devicectl syntax may differ — if it breaks on your version, the error
> will be visible (install just won't run), please report it as an issue.

## How it works

1. Finds your iPhone (asks which one if several are connected) and your Team ID
   — nothing to look up by hand.
2. Reads the IPA and decides bundle IDs (updates the installed app in place when
   found, preserving data).
3. Builds a tiny stub project a few times so Xcode mints a development
   certificate + provisioning profiles for every bundle (app + extensions), and
   registers your device with Apple automatically (manual Xcode run is a
   fallback).
4. Re-signs everything: bundle IDs namespaced to your team, entitlements
   mirrored from the profiles, frameworks and extensions signed inside-out.
5. Installs via `devicectl` and launches the app. Prints the profile expiry date.

Takes ~5 minutes. Re-run the same command to refresh.

### Automatic pairing

The install used to die with `The device must be paired before it can be
connected` when the pairing was missing. Now sidex detects it and runs
`devicectl manage pair` itself — on a fresh Mac the iPhone shows
**"Trust This Computer?"** (tap it and keep the phone unlocked, the command
waits), when the phone already knows this Mac it completes silently — then the
install just keeps going.

## Flags

- `--keep-watch` — keep the Apple Watch app inside the IPA (removed by default:
  free accounts cannot sign it and it breaks installation).
- `sidex pair [--to NAME|BUNDLE] [--out FILE] [--save-only]` — get the
  lockdown pairing record and push it into the app's Documents via `devicectl`
  (SideStore/LiveContainer/StikDebug pick it up from there; without `--to`
  you choose from apps found **on the device**). Asks usbmuxd first (no sudo,
  no permissions needed; the iPhone needs the USB cable here). On a fresh Mac
  with no record at all it runs the same **ProtocolVersion 2 Pair
  handshake Xcode uses** and pairs with the iPhone itself (unlock the phone,
  tap Trust). `/var/db/lockdown` with sudo + Full Disk Access remains the
  last fallback. Lockdown only; RPPairing still needs `idevice_pair`.
- `sidex cert [--password PW] [--out FILE] [--push-to NAME|BUNDLE]` — export
  the Apple Development identity as `.p12` for LiveContainer → Settings →
  Import Certificate (JIT-less mode).
- `sidex devices` — list connected iPhones/iPads. `sidex apps` — list what is
  installed and how many apps count against your free-account limit (~3).
- `sidex unpair` — forget this Mac on the iPhone (device-side + usbmuxd copy):
  the next `sidex pair` shows the "Trust This Computer?" dialog again. USB cable.
- `SIDEX_TEAM=XXXXXXXXXX sidex …` — skip Team ID auto-detection when several
  Apple IDs are in Xcode.

## Honest limits (free Apple ID, Apple's rules — same for every free signer)

- Profiles live **7 days** — re-run weekly.
- **10 App IDs** per team — reinstalling the same app reuses them; constantly new
  apps can exhaust the quota.
- Special capabilities (App Groups, Push, etc.) only work if already enabled on
  those App IDs. Push notifications never work on free accounts, anywhere.
- macOS + Xcode only. No Windows/Linux (needs Xcode by design).

# sidex

Install any `.ipa` on your iPhone with a **free Apple ID** — Xcode only.
No servers, no Anisette, no signing services.

## Why

Sideloadly/AltStore log into Apple via emulated Anisette; when Apple tightens
it, they all break at once. `sidex` uses Xcode's own login, so there is nothing
third-party to block.

## Install

```bash
git clone https://github.com/nodzen/sidex.git
cd sidex
/bin/bash sidex /path/to/app.ipa
```

No arguments? You get a menu (install / certificate / pairing); you can
**drag & drop** the `.ipa` into the terminal.

New to this? See **[GUIDE.md](GUIDE.md)** (Xcode setup, Developer Mode,
troubleshooting).

## Requirements

- macOS + full **Xcode 15+** with your Apple ID (`Xcode → Settings → Accounts`)
- iPhone on USB or same Wi-Fi, unlocked. Unpaired phones get paired automatically.
- Nothing else: the helper (`sidex-helper.swift`) compiles once with `swiftc`
  (~1 s) and is cached in `helper-cache/`.

> Tested on Xcode 27.0 + iOS 27.2. Older devicectl syntax may differ — report
> breakage as an issue.

## How it works

1. Finds your iPhone and Team ID.
2. Reads the IPA; updates in place if already installed (data kept).
3. Builds a stub project so Xcode mints profiles for app + extensions (also
   registers the device; a manual Xcode run is the fallback).
4. Re-signs everything with your team, entitlements taken from the profiles.
5. Installs via `devicectl`, launches the app, prints the profile expiry date.

Takes ~5 minutes. Re-run the same command to refresh. A missing pairing is
fixed mid-install (`devicectl manage pair` — tap Trust on a fresh Mac).

## Flags

- `--keep-watch` — keep the Watch app (stripped by default: free accounts
  cannot sign it).
- `sidex pair [--to NAME|BUNDLE] [--out FILE] [--save-only]` — pairing file,
  optionally pushed into the app's Documents (SideStore/LiveContainer/StikDebug
  read it there; without `--to` you pick from apps on the device). Tries usbmuxd
  (no sudo, USB cable), then a live Pair handshake, then `/var/db/lockdown`
  (needs Full Disk Access). Lockdown only.
- `sidex cert [--password PW] [--out FILE] [--push-to NAME|BUNDLE]` — export the
  dev identity as `.p12` for LiveContainer → Import Certificate (JIT-less).
- `sidex devices` / `sidex apps` — list devices / installed apps (free IDs keep
  ~3).
- `sidex unpair` — forget this Mac (Trust is asked again). USB cable.
- `SIDEX_TEAM=XXXXXXXXXX sidex …` — skip Team ID detection with several Apple IDs.

## Limits (Apple's free-tier rules, same for every free signer)

- Profiles last **7 days** — re-run weekly.
- **10 App IDs** per team — reinstalls reuse them; constantly new apps exhaust
  the quota.
- Push never works; other capabilities only if already on those App IDs.
- macOS + Xcode only.

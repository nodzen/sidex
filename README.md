# sidex

Install any `.ipa` on your iPhone with a free Apple ID. Uses Xcode's own login — no servers, no Anisette.

## Requirements

- macOS + full Xcode 15+ with your Apple ID (Xcode → Settings → Accounts)
- iPhone on USB or Wi-Fi, unlocked, Developer Mode on
- Nothing else: helper compiles once with `swiftc` and is cached in `helper-cache/`

## Install

```bash
git clone https://github.com/nodzen/sidex.git
cd sidex
/bin/bash sidex /path/to/app.ipa
```

No path → interactive menu (install / certificate / pairing). Drag & drop the `.ipa` works.

## How it works

1. Find iPhone + Team ID.
2. Read IPA; update in place if already installed (data kept).
3. Build a stub project so Xcode mints profiles (also registers the device).
4. Re-sign everything with your team, entitlements from profiles.
5. Install via `devicectl`, launch, print profile expiry.

~5 min. Re-run to refresh. Missing pairing fixed mid-install.

## Commands

- `sidex <app.ipa> [--keep-watch]` — install/refresh
- `sidex pair [--to NAME|BUNDLE] [--out FILE] [--save-only]` — pairing file
- `sidex cert [--password PW] [--out FILE] [--push-to NAME|BUNDLE]` — dev identity `.p12`
- `sidex devices` / `sidex apps` — list
- `sidex unpair` — forget this Mac
- `SIDEX_TEAM=XXXXXXXXXX sidex …` — skip Team ID detection

## Limits (free Apple ID)

- Profiles last 7 days — re-run weekly.
- ~3 apps installed at once, ~10 App IDs per team.
- No push; other capabilities only if already on those App IDs.

Run `/bin/bash sidex` with no args for the interactive menu.
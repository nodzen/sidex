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

No arguments? It asks — you can **drag & drop** the `.ipa` into the terminal.

New to this? Follow **[GUIDE.md](GUIDE.md)** step by step (Xcode setup, Developer
Mode, troubleshooting).

## Requirements

- macOS + full **Xcode 15+** with your Apple ID logged in (`Xcode → Settings → Accounts`)
- iPhone connected (USB or same Wi-Fi), Trust tapped, unlocked
- Nothing else. No Homebrew packages, no Python modules, no paid account.

## How it works

1. Finds your iPhone and your Team ID — nothing to look up by hand.
2. Reads the IPA and decides bundle IDs (updates the installed app in place when
   found, preserving data).
3. Builds a tiny stub project a few times so Xcode mints a development
   certificate + provisioning profiles for every bundle (app + extensions).
4. Re-signs everything: bundle IDs namespaced to your team, entitlements
   mirrored from the profiles, frameworks and extensions signed inside-out.
5. Installs via `devicectl` and launches the app. Prints the profile expiry date.

Takes ~5 minutes. Re-run the same command to refresh.

## Flags

- `--keep-watch` — keep the Apple Watch app inside the IPA (removed by default:
  free accounts cannot sign it and it breaks installation).

## Honest limits (free Apple ID, Apple's rules — same for every free signer)

- Profiles live **7 days** — re-run weekly.
- **10 App IDs** per team — reinstalling the same app reuses them; constantly new
  apps can exhaust the quota.
- Special capabilities (App Groups, Push, etc.) only work if already enabled on
  those App IDs. Push notifications never work on free accounts, anywhere.
- macOS + Xcode only. No Windows/Linux (needs Xcode by design).

# sidex

Install any `.ipa` on your iPhone with a **free Apple ID** — using only Xcode. No third-party servers, no Anisette, no accounts on shady signing services.

```bash
/bin/bash sidex /path/to/app.ipa
# or run it with no args, then drag & drop the .ipa into the terminal
```

New here? Read **[GUIDE.md](GUIDE.md)** — versions, setup, troubleshooting.

## Requirements

- macOS + full **Xcode 15+** with your Apple ID logged in (`Xcode → Settings → Accounts`)
- iPhone connected (USB or same Wi-Fi), tapped Trust, unlocked
- That's it. No Homebrew packages, no Python modules, no paid account.

## What it does

1. Finds your iPhone and your Team ID (fully automatic, nothing to look up).
2. Reads the IPA, decides bundle IDs (updates the installed app in place when found, preserving data).
3. Builds a tiny stub project a few times to make Xcode mint a development certificate + provisioning profiles for every bundle (app + extensions).
4. Re-signs everything: bundle IDs namespaced to your team, entitlements mirrored from the profiles, frameworks/extensions signed inside-out.
5. Installs via `devicectl` and launches the app. Prints the profile expiry date.

Takes ~5 minutes. Re-run the same command to refresh.

## Flags

- `--keep-watch` — keep the Apple Watch app inside the IPA (removed by default: free accounts cannot sign it and it breaks installation).

## Honest limits (free Apple ID, Apple's rules)

- Profiles live **7 days** — re-run weekly.
- **10 App IDs** per team — reinstalling the same app reuses them; constantly new apps can exhaust the quota.
- Special capabilities (App Groups, Push, etc.) only work if already enabled on those App IDs.
- macOS + Xcode only. No Windows/Linux (needs Xcode by design).

## Why this exists

Third-party signers (Sideloadly/AltStore/iLoader-style) log into Apple through GrandSlam with emulated Anisette. When Apple tightens that endpoint, they all break at once. This script takes the boring road instead: Apple's own client (Xcode) with your own login — nothing to block.

# Grok Bot Usage

A free, open-source **macOS 14+ menu bar app** that shows your **Grok Bot weekly included usage %** (the Cursor “Sand” allowance).

Menu bar label: triangle icon + used percent (e.g. `33%`).  
Dropdown panel: used %, remaining %, reset time, last refresh, Refresh, Demo Mode, Quit, and a link to the Cursor usage dashboard.

MIT licensed. Ready for [umichsteve/grokbot-usage](https://github.com/umichsteve/grokbot-usage).

## Requirements

- macOS 14 Sonoma or later
- Apple silicon or Intel Mac
- Xcode 15+ (Swift 5.9+)
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — recommended

You must be signed in to **Cursor / Grok Bot** on this Mac (or provide a local session cookie file). **Never paste cookies into chat.**

## Quick start (Apple silicon + Xcode)

### Option A — XcodeGen (recommended)

```bash
git clone https://github.com/umichsteve/grokbot-usage.git
cd grokbot-usage
brew install xcodegen   # if needed
xcodegen generate
open GrokBotUsage.xcodeproj
```

In Xcode:

1. Select the **GrokBotUsage** scheme (My Mac).
2. Press **⌘R** to build & run.
3. Look in the menu bar for the triangle + percent (Demo Mode is on by default — shows ~33% until you add credentials and turn it off).

The app is an `LSUIElement` agent — **no Dock icon**.

### Option B — Open `Package.swift` in Xcode

```bash
open Package.swift
```

Xcode can build the executable target. For a proper menu-bar `.app` with `LSUIElement`, prefer Option A (`project.yml` → `.xcodeproj`). Option B is fine for compiling/checking sources.

### Option C — `swift build` (CLI check)

```bash
swift build -c release
```

This compiles the target; packaging as a `.app` still goes through Xcode / XcodeGen.

## Demo Mode

Demo Mode defaults **on** for first launch so the menu bar shows a fixed **~33%** used / **~67%** remaining without credentials. Toggle it off in the dropdown once auth is configured. No network calls while Demo Mode is on.

## Authentication (v1)

The app calls:

```http
POST https://cursor.com/api/dashboard/get-sand-usage-status
Origin: https://cursor.com
Cookie: WorkosCursorSessionToken=…
```

Resolution order (first hit wins):

1. **Environment variable** `GROKBOT_USAGE_COOKIE`  
   - Bare token **or** full `WorkosCursorSessionToken=…` / `Cookie:` header value.
2. **Local config file** `~/.config/grokbot-usage/session`  
   - Same contents as above. Create once on your machine:
   ```bash
   mkdir -p ~/.config/grokbot-usage
   chmod 700 ~/.config/grokbot-usage
   # Put ONLY the token (or name=value) in the file — do not commit it.
   nano ~/.config/grokbot-usage/session
   chmod 600 ~/.config/grokbot-usage/session
   ```
3. **Chromium cookie DB (best-effort)**  
   - Reads `WorkosCursorSessionToken` for `*.cursor.com` from Chrome / Chromium / Edge / Brave / Arc profile `Cookies` SQLite DBs.  
   - Decrypts with the browser’s Keychain “Safe Storage” password via `/usr/bin/security`. macOS may prompt once for Keychain access.  
   - No App Sandbox / special entitlements required for a normal local build. Failures fall through silently.

Safari binary cookies and Cursor.app `state.vscdb` JWT import are intentionally out of scope for v1 (entitlements / format complexity). Primary documented path: **local session file** or **Chromium cookies** after you’ve signed in at [cursor.com](https://cursor.com).

See `session.example` in this repo for the file format (never commit a real token).

## API response fields

Parsed flexibly (CodexBar-compatible), including:

| Field | Meaning |
|-------|---------|
| `usagePercent` | Weekly Grok Bot used % (0–100, or 0–1 fraction) |
| `nextResetTimestampUtc` | ISO-8601 weekly reset |
| `currentPeriodStart` | ISO-8601 period start |
| `hasAvailableUsage` | Whether usage remains |
| `hasNonZeroIncludedLimit` | If `false`, account has no Bot allowance (meter hidden / message shown) |

Example:

```json
{
  "currentPeriodStart": "2026-08-17T07:57:50.647Z",
  "nextResetTimestampUtc": "2026-08-24T07:57:50.647Z",
  "usagePercent": 33,
  "hasAvailableUsage": true,
  "hasNonZeroIncludedLimit": true
}
```

## Project layout

```
Package.swift                 # SPM executable (macOS 14+)
project.yml                   # XcodeGen → GrokBotUsage.xcodeproj
LICENSE                       # MIT
README.md
session.example
Fixtures/sand-usage-status.sample.json
Sources/GrokBotUsage/
  GrokBotUsageApp.swift       # MenuBarExtra entry
  Info.plist                  # LSUIElement = true
  Models/
    SandUsageStatus.swift
    UsageStore.swift
  Services/
    AuthResolver.swift
    ChromeCookieReader.swift
    UsageAPIClient.swift
  Views/
    MenuBarLabelView.swift
    UsagePanelView.swift
  Resources/Assets.xcassets/
```

## Privacy

- Session cookies stay on your Mac (env / local file / Keychain-backed browser decrypt).
- The only network call is to `cursor.com` for usage status (unless Demo Mode is on).
- No analytics, no third-party trackers.

## License

MIT — see [LICENSE](LICENSE).

## Credits

Response field names and endpoint behavior aligned with [CodexBar](https://github.com/steipete/CodexBar)’s Cursor Sand / Grok Bot support (`usagePercent`, `nextResetTimestampUtc`, `hasNonZeroIncludedLimit`).

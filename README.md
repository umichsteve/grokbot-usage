# Super Grok — Grok weekly usage

A free, open-source **macOS 14+ menu bar app** that shows your **Super Grok (xAI / grok.com) weekly usage %** — the same shared weekly pool as Settings → Usage on [grok.com](https://grok.com).

Menu bar label: triangle icon + used percent of the Super Grok weekly pool (`creditUsagePercent`), or **—** when the CLI billing payload omits the percent.  
Dropdown panel: used %, remaining %, reset time (`currentPeriod.end`), optional plan tier from `/v1/settings`, last refresh, Refresh, Demo Mode, Quit, optional product breakdown (Chat / Build / Imagine / …), and a link to [grok.com](https://grok.com) (Settings → Usage).

MIT licensed. Repo: [umichsteve/grokbot-usage](https://github.com/umichsteve/grokbot-usage).

> **Not Cursor sand / Grok Bot.** This meter talks to xAI’s Grok CLI billing endpoint with a `grok login` session. It does **not** read Cursor cookies.

## Requirements

- macOS 14 Sonoma or later
- Apple silicon or Intel Mac
- Xcode 15+ (Swift 5.9+)
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — recommended
- **[Grok CLI](https://grok.com)** installed and signed in via `grok login` (writes `~/.grok/auth.json`)

## Quick start

### 1. Sign in with Grok CLI

```bash
# Install Grok CLI if you do not already have it (see grok.com / xAI docs).
grok login
```

That stores an OIDC session in `~/.grok/auth.json` (mode `0600`). This app reads that file and refreshes the access token the same way the CLI / GrokUsageBar do.

### 2. Build & run (Apple silicon + Xcode)

#### Option A — XcodeGen (recommended)

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
3. Look in the menu bar for the triangle + percent (Demo Mode is on by default — shows ~33% until you turn it off after `grok login`).

The app is an `LSUIElement` agent — **no Dock icon**.

#### Option B — Open `Package.swift` in Xcode

```bash
open Package.swift
```

Xcode can build the executable target. For a proper menu-bar `.app` with `LSUIElement`, prefer Option A.

#### Option C — `swift build` (CLI check)

```bash
swift build -c release
```

## Demo Mode

Demo Mode defaults **on** for first launch so the menu bar shows a fixed **~33%** used / **~67%** remaining without credentials. Toggle it off in the dropdown once `grok login` (or a fallback token) is configured. No network calls while Demo Mode is on.

## Authentication

### Primary — Grok CLI (`~/.grok/auth.json`)

```bash
grok login
```

Typical fields per session entry:

| Field | Meaning |
|-------|---------|
| `key` or `access_token` | Bearer access token |
| `refresh_token` | OIDC refresh token |
| `expires_at` | Access token expiry (ISO-8601) |
| `oidc_issuer` | e.g. `https://auth.x.ai` |
| `oidc_client_id` | Grok CLI client id |

When the access token is within **5 minutes** of expiry, or the billing API returns **401/403**, the app POSTs to `{oidc_issuer}/oauth2/token` with `grant_type=refresh_token` and writes `key` / `refresh_token` / `expires_at` back to `~/.grok/auth.json` (mode `0600`), sharing the renewed session with the Grok CLI.

### Advanced fallbacks

1. **Environment variable** `SUPERGROK_USAGE_TOKEN` — bare Bearer token (or `Bearer …`).
2. **Local file** `~/.config/grokbot-usage/session` — same contents (one token line; `#` comments allowed).

```bash
mkdir -p ~/.config/grokbot-usage
chmod 700 ~/.config/grokbot-usage
# Put ONLY the Bearer token in the file — do not commit it.
nano ~/.config/grokbot-usage/session
chmod 600 ~/.config/grokbot-usage/session
```

See `session.example`. **Never paste tokens into chat.**

Cursor `WorkosCursorSessionToken` / Chrome cursor.com cookies are **not** used.

## API

```http
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Authorization: Bearer <token>
X-XAI-Token-Auth: xai-grok-cli
x-grok-client-surface: menu-bar
```

Parsed flexibly from `config`:

| Field | Meaning |
|-------|---------|
| `creditUsagePercent` | Weekly Super Grok used % (0–100, or 0–1 fraction). **Only when present.** |
| `currentPeriod.type` | e.g. `USAGE_PERIOD_TYPE_WEEKLY` |
| `currentPeriod.start` / `end` | Period window; **reset time** = `end` |
| `productUsage[].product` | e.g. `GrokChat`, `GrokBuild`, `GrokImagine` |
| `productUsage[].usagePercent` | Per-product share of the weekly pool |

Optional companion call (best-effort; failure does not fail the refresh):

```http
GET https://cli-chat-proxy.grok.com/v1/settings
```

Used for `subscription_tier_display` (e.g. `SuperGrok`) in the panel header / Plan row.

### Period-only payloads (no percent)

Some SuperGrok accounts get HTTP 200 with a weekly `currentPeriod` but **omit** `creditUsagePercent` and `productUsage` entirely (known xAI / unified-billing drift). grok.com’s web UI may still show a real percent (~19% etc.).

This app follows CodexBar / OpenUsage guidance:

- **Omitted percent + period = unknown usage** — menu bar shows **—**, panel says *Weekly % not reported by Grok CLI billing yet*, and still shows reset time / plan when available.
- **Never invent 0%** from an omitted field. `0%` only appears when the API sends an explicit `creditUsagePercent: 0`.
- A grok.com web scrape / gRPC cookie path is **not** implemented; prefer honest unavailable over fake zeros until xAI includes the field or a real web fallback is added later.

Fixture: `Fixtures/billing-credits.period-only.sample.json`.

Example (full credits shape):

```json
{
  "config": {
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "start": "2026-09-02T12:00:00.000Z",
      "end": "2026-09-09T12:00:00.000Z"
    },
    "creditUsagePercent": 33.0,
    "productUsage": [
      { "product": "GrokChat", "usagePercent": 18.0 },
      { "product": "GrokBuild", "usagePercent": 12.0 },
      { "product": "GrokImagine", "usagePercent": 3.0 }
    ]
  }
}
```

## Project layout

```
Package.swift                 # SPM executable (macOS 14+)
project.yml                   # XcodeGen → GrokBotUsage.xcodeproj
LICENSE                       # MIT
README.md
session.example               # Advanced Bearer token fallback template
Fixtures/billing-credits.sample.json
Fixtures/billing-credits.period-only.sample.json
Sources/GrokBotUsage/
  GrokBotUsageApp.swift       # MenuBarExtra entry
  Info.plist                  # LSUIElement = true
  Models/
    SuperGrokUsage.swift
    UsageStore.swift
  Services/
    AuthResolver.swift        # ~/.grok/auth.json + OIDC refresh + fallbacks
    UsageAPIClient.swift      # billing?format=credits + optional /v1/settings
  Views/
    MenuBarLabelView.swift
    UsagePanelView.swift
  Resources/Assets.xcassets/
```

## Privacy

- Tokens stay on your Mac (`~/.grok/auth.json`, optional env / local session file).
- The only network calls (when Demo Mode is off) are to xAI hosts: OIDC token refresh, `cli-chat-proxy.grok.com` billing, and best-effort `/v1/settings`.
- No analytics, no third-party trackers.

## License

MIT — see [LICENSE](LICENSE).

## Credits

Auth + billing shapes aligned with public meters such as [GrokUsageBar](https://github.com/SergioComeron/GrokUsageBar) and [OpenUsage](https://github.com/robinebers/openusage) (Grok CLI `~/.grok/auth.json`, `creditUsagePercent`). Omitted-percent handling follows CodexBar / OpenUsage: unknown, not fabricated 0%.

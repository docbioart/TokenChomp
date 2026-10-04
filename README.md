# TokenChomp

A small native macOS menu-bar companion that shows how much of your Codex and Claude Code subscription limits are left: the Claude session window, the weekly window, per-model weekly limits such as Fable, and Codex's windows, each with its reset time. SwiftUI + AppKit, macOS 13+, no third-party dependencies, server, account, telemetry, or credential storage.

<img width="358" height="257" alt="image" src="https://github.com/user-attachments/assets/bfe00154-994a-482a-af33-059f7047b8a5" />



## Credit

TokenChomp exists because of **[TokenFish](https://github.com/pixelsncodes/tokenfish)** by [@pixelsncodes](https://github.com/pixelsncodes), "a little fish for your AI limits": a Windows tray companion for Codex and Claude Code. The core ideas here come from TokenFish:

- a glanceable companion for both tools' subscription quota, with reset countdowns and freshness;
- a character that chomps token pellets along a rail whose position follows consumed quota, with mint for Codex;
- a compact desktop widget alongside a fuller view, and no account, backend, or telemetry.

If you are on Windows, use TokenFish. Go star it.

TokenChomp is an independent macOS reimplementation of those ideas in SwiftUI. No TokenFish source code, artwork, or assets are used. The chomper and ghost are drawn in code here.

Open **preview.html** in a browser to try the visual idea with sample data. Drag the quota slider: a yellow chomper advances along the pellet rail, a purple ghost appears at 70% used, and the ghost turns coral and closes in at 90%. At 100%, the label reads “Limit reached.” Pellets are decorative; position is provider-reported percent used. The label shows percent left.

## Build on a Mac

Install Xcode Command Line Tools (`xcode-select --install`), then from this directory:

```sh
bash scripts/build-app.sh
cp -R dist/TokenChomp.app /Applications/
open /Applications/TokenChomp.app
```

If no icon appears, check your menu-bar manager: Ice and Bartender put a newly launched item in their hidden section, and on a notched MacBook macOS hides items that do not fit to the right of the notch. ⌘-drag the icon into the visible area once. The menu-bar icon is a frame rendered to an image, because `MenuBarExtra` labels only display `Image` and `Text`.

The script runs the core tests, compiles a release executable, creates an app bundle, and signs it locally. Apple Developer signing and notarization are not configured. The app lives in the menu bar; click its animated icon for quota. Quit from the popover. **Connections & options** has provider toggles, a start-at-login toggle (registered through `SMAppService`, so it also appears under System Settings › General › Login Items), animation controls, demo mode, and a desktop widget. The widget is one line per window with the same renderer. By default it shows the most consumed window per provider; **Widget lists every window** adds the rest, including per-model weekly buckets such as Fable. It can be dragged and remembers its position. It is not always on top.

## Connect your tools

**Codex:** install and sign in to the CLI separately. The app checks `/opt/homebrew/bin/codex` and `/usr/local/bin/codex`; enter your absolute executable path in Connections if needed. It launches `codex app-server`, initializes the JSON line protocol, and requests `account/rateLimits/read`. Refresh runs off the main thread, once a minute, with a 15-second deadline and process cleanup. No terminal shell or credential-file reading is involved. Primary and secondary subscription quota are shown only when reported. Token totals and API billing are outside this first version.

**Claude Code:** move the app to its permanent location first. Click **Copy Claude bridge configuration** in Connections. Manually merge its `statusLine` object into `~/.claude/settings.json`, preserving unrelated settings. It includes `"refreshInterval": 300`, which makes Claude Code re-run the bridge every five minutes even while a session is idle. Claude readings go stale after 15 minutes without an update, so an interval of 5 or 10 minutes keeps them fresh without costing much battery; without it, readings go stale 15 minutes after your last message. Back up an existing status line before replacing it. Start a Claude Code session. The same executable runs in `--claude-bridge` mode, reading stdin without opening a UI and saving only these fields:

- `rate_limits.five_hour.used_percentage` / `resets_at` (shown as **Session**)
- `rate_limits.seven_day.used_percentage` / `resets_at` (shown as **Weekly**)
- `rate_limits.seven_day_opus` and `seven_day_sonnet` `used_percentage` / `resets_at`, when present
- `rate_limits.model_scoped[].display_name` / `utilization` / `resets_at`, the per-model weekly buckets Claude Code adds for models such as Fable. `utilization` arrives as a 0–1 fraction, so values at or below 1 are scaled to percent.

**Per-model limits (Fable and others):** Claude Code's status line does not include per-model weekly limits, so TokenChomp also reads `~/.claude.json` read-only and keeps only `cachedUsageUtilization.fetchedAtMs` and the `limits[]` rows of kind `weekly_scoped` (percent, reset time, model display name). Account IDs, email, and everything else in that file are ignored and never stored. Claude Code refreshes that cache only when it fetches usage, for example when you run `/usage`. Weekly usage only rises until its reset, so these rows show their age ("4h old") rather than going stale; they go stale at reset. Run `/usage` to refresh them. Turn this off with the **Per-model limits** toggle in Connections.

No context-window usage is treated as subscription quota. Missing provider fields remain missing. The bridge does not keep raw input, prompts, responses, identity, or credentials. It prints a short usage status line. Overlapping invocations use a file lock; writes are atomic and merge observations per window. Claude data lives in `~/Library/Application Support/TokenChomp/claude.json`; preferences live in the app's macOS UserDefaults. Moving the app requires recopying the bridge command.

## Freshness and motion

Failed refreshes retain the last successful observation with a visible failure message. A reading becomes stale when its reported reset time passes, or when it has not updated for five minutes (Codex) or 15 minutes (Claude). A stale rail stops animating and never pretends the quota reset. Each row shows the time until reset; hover a row for the observation time and the exact reset date. Missing data is an explicit connection state, not 0% usage. Demo data is labeled and never saved to the Claude file.

Animation uses one vector renderer across the menu-bar icon, popover, and widget. macOS Reduce Motion and the app's animation toggle stop mouth and ghost movement. Percentage text, freshness, and warning labels remain readable without motion or color. SwiftUI animation timelines are tied to visible views.

## Validation / status

Built and run on macOS 26 (Apple silicon) with `scripts/build-app.sh`. Core tests cover provider payloads, missing/invalid values, privacy allowlisting, ghost thresholds, reset parsing, the per-model snapshot, and staleness. Checked by hand on that machine: the menu-bar icon, the popover, the desktop widget, live Codex quota, the Claude bridge, and the Fable row from Claude Code's usage cache.

Not yet checked: Intel Macs, macOS 13–15, Reduce Motion, and Codex timeout recovery. Provider contracts can change with CLI versions; the Claude per-model rows depend on an undocumented cache in `~/.claude.json`.

Keep scope small: two quota readers, one model, one renderer, one dashboard. No plugin system or generic provider framework.

## License

MIT. See [LICENSE](LICENSE). The license covers TokenChomp's own code only; TokenFish is a separate project with its own terms.

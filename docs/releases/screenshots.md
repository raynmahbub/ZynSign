# App Store screenshot pack

One template, five screens, two device classes. Composed by
`python3 Scripts/compose_screenshots.py` from raw simulator captures in
`Assets/Screenshots/raw/`; the manifest with headlines lives beside them.

| # | Screen | Headline | Subtitle |
|---|---|---|---|
| 1 | Smart Workspace (morning, session card, Quick Sign) | One Workspace. | Continue where you left off. Sign in one tap. |
| 2 | Signing in progress, stage list | Smart Sign. | Nine stages, on your device, verified independently. |
| 3 | Install Health card expanded | Install Health. | Know before you install. Nothing is assumed. |
| 4 | Certificate Studio | Your Keys. Your Device. | Keychain-bound identities that never leave the phone. |
| 5 | Library, grid, Binary Inspector peek | Every App, Inspected. | Binaries, entitlements, resources — read-only, honest. |

## Capture rules

* iPhone 16 Pro Max simulator (1290 × 2796) and iPad Pro 13" (2064 × 2752); light appearance for 1–3, dark for 4–5 so both appear.
* Status bar via `xcrun simctl status_bar … override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`.
* Seed data: synthetic IPAs (the host vectors under `Tests/Host/` produce valid ones) with `com.example.*` identifiers; a throw-away self-signed identity — never a personal certificate or a real team ID.
* No badges, no toasts mid-animation; wait for `ZMotion.hero` to settle.

## Compose

```bash
python3 Scripts/compose_screenshots.py --canvas 6.7
python3 Scripts/compose_screenshots.py --canvas 6.1
python3 Scripts/compose_screenshots.py --canvas ipad-13
```

Outputs go to `Assets/Screenshots/store/` (ignored by Git; upload directly).
The template alone can be reviewed at any time with `--preview`
(`Assets/Screenshots/template-preview.png`).

## App Preview (15–20 s)

Storyboard, same template: 0–3 s the ribbon draws (hero motion) · 3–8 s open
an app from Quick Sign and start a run · 8–14 s stages complete, Install
Health goes to 96 · 14–18 s Deliver: QR appears · 18–20 s lockup. Captured
with `xcrun simctl io booted recordVideo`, no voice-over, no music.

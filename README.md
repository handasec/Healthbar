# Healthbar

Your Mac's vitals as three bars, on a translucent note that sits on your desktop.
Disk, CPU, and memory at a glance — it floats above your windows, follows you across
Spaces, and stays out of the way.

- Native Cocoa, single Swift file, no dependencies and no frameworks to install
- Reads straight from the kernel (`statfs`, `host_statistics`) — no shelling out, negligible CPU
- Universal binary: Apple Silicon and Intel
- Requires macOS 13 (Ventura) or later

| Row | Shows |
|---|---|
| DISK | Free space on the data volume, bar is percent used |
| CPU | Percent busy, sampled every 2 seconds |
| MEMORY | Percent and bytes used — app + wired + compressed, matching Activity Monitor |

Bars are green, turning amber past 75% and red past 90%.

## Install

### Option A — build it yourself (recommended)

Nothing is downloaded from the internet, so macOS raises no security prompts at all.
You need the Xcode Command Line Tools (`xcode-select --install`), nothing else.

```sh
git clone https://github.com/handasec/Healthbar.git
cd Healthbar
./build.sh
cp -R build/Healthbar.app /Applications/
open /Applications/Healthbar.app
```

### Option B — download a release

Grab `Healthbar-x.y.z-universal.zip` from the [Releases](../../releases) page, unzip it,
and drag `Healthbar.app` into `/Applications`.

This app is **not notarized by Apple**, so macOS will refuse to open it the first time
and say it cannot be verified. That is expected for an unsigned app from the internet,
not a sign that anything is wrong with it. To get past it, do one of:

**Clear the download flag** (fastest):

```sh
xattr -dr com.apple.quarantine /Applications/Healthbar.app
open /Applications/Healthbar.app
```

**Or approve it in System Settings:** try to open the app, then go to
**System Settings → Privacy & Security**, scroll to the Security section, and click
**Open Anyway** next to the Healthbar message. On recent macOS versions this is the only
route through the UI — Control-clicking the app and choosing Open no longer bypasses the check.

## Using it

- **Move it** — drag the note anywhere. Its position is remembered between launches.
- **Quit it** — hover over the note and click the ✕, or right-click → Quit.
- **Reset position** — right-click → Reset Position puts it back in the top-left corner.
- **Start at login** — System Settings → General → Login Items & Extensions → **＋** under
  "Open at Login" → choose Healthbar.

## Building

```sh
./build.sh                    # universal, ad-hoc signed, writes build/
VERSION=1.2.0 ./build.sh      # stamp a version into the bundle and zip
```

The build produces both `build/Healthbar.app` and a zip ready to attach to a release.
`main.swift` is the whole program — edit the `Glass` enum at the top to change colors,
`StickyNoteView.size` to resize, or `tick` in `AppDelegate` to change the refresh rate.

## Releasing

Tag and push; the GitHub Actions workflow in `.github/workflows/release.yml` builds the
universal app on a macOS runner and attaches the zip to a GitHub release.

```sh
git tag v1.0.0
git push origin v1.0.0
```

### Shipping it without the Gatekeeper warning

The warning in Option B goes away only with an Apple Developer Program membership
($99/year). With one:

1. Create a **Developer ID Application** certificate and install it in your keychain.
2. Build signed, with the hardened runtime:
   ```sh
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
   ```
3. Notarize the zip and staple the ticket to the app:
   ```sh
   xcrun notarytool submit build/Healthbar-1.0.0-universal.zip \
       --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD \
       --wait
   xcrun stapler staple build/Healthbar.app
   ditto -c -k --keepParent build/Healthbar.app build/Healthbar-1.0.0-universal.zip
   ```

The re-zip after stapling matters — the ticket is attached to the `.app`, and without
repacking you would ship the unstapled copy.

## License

MIT — see [LICENSE](LICENSE).

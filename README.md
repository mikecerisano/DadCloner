# DadCloner

macOS menu bar app for scheduled drive backups. Never deletes anything from the backup, just archives it when it disappears from the source.

My dad's 75 and has decades of recording sessions and jingles on external drives. He needed backups that would actually happen without him thinking about it, and couldn't risk anything getting deleted. Time Machine was a non-starter. Mac OS 9 was his jam, his dock is longer than War and Peace. So, let's keep it dead simple:

## How it works

Pick a source drive. Pick a backup drive. Set a schedule. Done.

The app syncs changes automatically using rsync. If a file gets removed from the source, it moves to a `DadCloner_Archive` folder on the backup instead of disappearing forever. He will delete things accidentally, I know it. But he can always get them back now. And his backup drive is 10 TB and his main is like 4 TB. It will never run out of space for these archived files.

Everything lives in a `DadCloner Backup` folder on your destination drive:
- Mirrored files from source
- `DadCloner_Archive/` subfolder for anything that got removed

## What it doesn't do

- Touch your source drive (read only, always)
- Use `--delete` or any other destructive rsync flags
- Format or partition anything
- Require you to think about it after setup

## Building

Xcode 15+. The app bundles rsync 3.2.7 so it works without Homebrew.

The bundled rsync binary is currently Apple Silicon only. For Intel Macs, replace `DadCloner/Resources/rsync` with an x86_64 or universal rsync binary before building.
```bash
git clone [repo]
open DadCloner.xcodeproj
```

In Xcode:
1. Select the **DadCloner** target in the project navigator
2. Go to **Signing & Capabilities**
3. Set your **Team** to your Apple Developer account (or Personal Team for local builds)
4. Build and run

## Releasing

Use a Developer ID Application certificate for public builds. Sign the bundled `rsync` binary before re-signing and notarizing the app bundle.

Basic beta checklist:

```bash
xcodebuild -project DadCloner.xcodeproj -scheme DadCloner -configuration Release clean build
APP="path/to/DadCloner.app"
IDENTITY="Developer ID Application: Your Name (TEAMID)"
codesign --force --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/rsync"
codesign --force --options runtime --timestamp --entitlements DadCloner/DadCloner.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" DadCloner-0.1-beta.zip
xcrun notarytool submit DadCloner-0.1-beta.zip --keychain-profile "notarytool-profile" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=4 "$APP"
```

Do not ship a "Sign to Run Locally" build. The release artifact should show a Developer ID signature and a successful notarization result.

## License

MIT. Use it for your parents, rebuild it, whatever.

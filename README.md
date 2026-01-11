# DadCloner

macOS menu bar app for scheduled drive backups. Never deletes anything from the backup, just archives it when it disappears from the source.

My dad's 75 and has decades of recording sessions and jingles on external drives. He needed backups that would actually happen without him thinking about it, and couldn't risk anything getting deleted. Time Machine was a non-starter. Mac OS 9 was his jam, his dock is longer than war and peace. So, lets keep it dead simple:

## How it works

Pick a source drive. Pick a backup drive. Set a schedule. Done.

The app syncs changes automatically using rsync. If a file gets removed from the source, it moves to an `_archived` folder on the backup instead of disappearing forever.

Everything lives in a `DadCloner Backup` folder on your destination drive:
- Mirrored files from source
- `_archived/` subfolder for anything that got removed

## What it doesn't do

- Touch your source drive (read only, always)
- Use `--delete` or any other destructive rsync flags
- Format or partition anything
- Require you to think about it after setup

## Building

Xcode 15+. The app bundles rsync 3.2.7 so it works without Homebrew.
```bash
git clone [repo]
open DadCloner.xcodeproj
```

## License

MIT. Use it for your parents, rebuild it, whatever.

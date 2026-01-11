# DadCloner

I made this because my dad is 75 and I wanted backups that are:
1) automatic,
2) hard to screw up,
3) incapable of deleting the stuff he loves.

It's a tiny macOS menu bar app that clones one external drive to another. No Time Machine. No "choose this, choose that." Just: pick source, pick backup, done.

## What it does

- Copies only what changed after the first run (thanks, rsync).
- Never deletes from the backup. If a file disappears from the source, it gets archived on the backup.
- Puts everything inside a single folder on the backup drive: `DadCloner Backup`.
- Runs on a schedule and stays out of the way.

## What it does NOT do

- It won't wipe your source drive. It never writes to the source, and it never uses `--delete`.
- It won't format disks or change partitions.

## How it works (plain English)

1. You pick a source drive and a backup drive.
2. DadCloner creates a folder on the backup drive and syncs everything into it.
3. Every day at the chosen time, it syncs only what changed.
4. Anything removed from the source gets moved into an archive folder on the backup instead of being deleted.

## Why it's simple

Because if it isn't simple, it won't get used. And if it doesn't get used, it's useless.

## Build

- Xcode 15+
- macOS target per your project settings

The app bundles rsync 3.2.7 so it works consistently without Homebrew.

## License

Do whatever you want with it. Use it for your parents. Rebuild it into something else. It's all off-the-shelf stuff and zero drama.

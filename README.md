# DadCloner 👨‍👦💾

Because "Dad, did you back up your files?" shouldn't be a weekly argument.

## The Origin Story

My dad is 75. He's got decades of jingles, sessions, and memories on hard drives. Time Machine confused him. Cloud backup scared him. Drag-and-drop? He'd forget.
So I built this: a macOS menu bar app so simple that set-it-and-forget-it isn't a marketing slogan -- it's the entire interface.
DadCloner does one thing: it clones one drive to another, automatically, without ever deleting anything he cares about.

## What It Does ✨

- Copies only what changed after the first run (rsync under the hood)
- Never deletes from the backup -- if a file vanishes from the source, it gets archived instead
- Keeps everything tidy in a single `DadCloner Backup` folder on the destination
- Runs on schedule and stays out of the way in your menu bar
- Zero configuration hell -- pick source, pick backup, done

## What It Does NOT Do 🚫

- Won't touch your source drive (read-only, always)
- Won't format or partition anything
- Won't use `--delete` flags or other scary rsync options
- Won't judge your dad's folder naming conventions

## How It Works (No Jargon Version)

1. You pick a source drive (the one with all the stuff)
2. You pick a backup drive (the one that should have all the stuff)
3. DadCloner creates a folder on the backup and syncs everything into it
4. Every day at your chosen time, it syncs only what changed
5. If something disappears from the source, it gets archived on the backup, not deleted

Philosophy: If it isn't simple enough for a 75-year-old to trust, it isn't simple enough.

## Tech Specs 🔧

- Built for: macOS (Xcode 15+)
- Bundled with: rsync 3.2.7 (so it works out-of-the-box, no Homebrew required)
- Languages: Swift, SwiftUI, and a little bit of shell scripting
- Complexity: Intentionally minimal

## Why This Exists

Because backups shouldn't require a PhD in IT. Because losing your life's work to a dead drive is heartbreaking. Because sometimes the best technology is the kind that just works and gets out of the way.
This is my first public GitHub project. It's not fancy. But it's kept my dad's jingles safe for months, and maybe it'll help your parents too.

## Build It Yourself

```bash
git clone https://github.com/mikecerisano/DadCloner.git
cd DadCloner
open DadCloner.xcodeproj
# Build and run in Xcode
```

## License 📜

Do whatever you want with it.
Use it for your parents. Rebuild it. Ship it to your grandma. Turn it into a TikTok. I don't care. It's yours.
Zero drama. Zero strings. Just working software for people you care about.

## Credits

Built with ☕ and mild panic about hard drive mortality by a guy who works in film and needed his dad's archive to survive.
If this helped you, cool. If you have ideas to make it better, open an issue. If you just want to say hi, that works too.

"The best backup is the one that happens automatically."
-- Every IT person ever, probably

# Scheduler Reliability Fixes — Design

Date: 2026-07-01
Scope: beta 2 reliability pass. No new features, no UI redesign.

## Problems

1. **Scheduled backups silently miss when the Mac sleeps.** `SchedulerManager`
   uses a one-shot `Timer` aimed at the exact schedule time. macOS does not
   wake for `Timer`, and the setup flow recommends 2 AM — so on any machine
   that sleeps overnight the daily backup never fires. There is also no
   wake hook: catch-up only runs once, at app launch.
2. **A failed sync defeats overdue detection.** `recordSyncResult` stamps
   `lastSyncDate` on both success and failure, so after a failure the app
   believes it is fresh for 25 hours: no catch-up, no overdue warning, and
   "Last backup: N minutes ago" in the popover refers to a backup that failed.
3. **Reset button is not gated as intended.** The code comment says
   "Hidden reset option (hold Option key)" but the button is always visible.
   A confirmation dialog exists, but the destructive escape hatch should not
   be one stray click away for the target user.

## Design

### 1. Tick-based scheduler with wake catch-up

Replace the one-shot exact timer with:

- A repeating 60-second tick timer (with generous tolerance, added to
  `RunLoop` mode `.common` so it survives menu tracking). Each tick asks:
  is `Date() >= nextScheduledSync`? If yes, run the sync and recompute
  `nextScheduledSync`.
- An observer on `NSWorkspace.shared.notificationCenter` for
  `didWakeNotification` that runs the same check immediately, so a backup
  missed during sleep starts as soon as the Mac wakes (drives permitting).

`nextScheduledSync` remains the single source of truth for display and
firing. `calculateNextSyncTime` logic is unchanged. This removes the
tomorrow-branch timer that was never added to `.common`, and the `timer!`
force-unwrap.

### 2. Last-success vs last-attempt bookkeeping

- `lastSyncDate` (existing UserDefaults key, so upgrades keep their history)
  now means **last successful sync** — set only on success. Everything that
  reads it (`timeSinceLastSync`, `isBackupOverdue`, popover, status icon)
  becomes truthful automatically, and overdue detection survives failures.
- New key `lastSyncAttemptDate`, set on every attempt. Catch-up (launch,
  wake, tick) only fires when the backup is overdue **and** the last attempt
  is more than 1 hour old, so a persistently failing sync retries hourly
  instead of on every wake/tick. The exact scheduled time always fires
  regardless of attempt spacing.
- The `lastSyncSuccess` flag is unchanged.

### 3. Option-gated Reset

The Reset button renders only while the Option key is held (tracked via a
local `flagsChanged` event monitor installed while the popover is visible).
The existing confirmation dialog stays as the second gate. Footer shows a
subtle hint is unnecessary — this matches the code's original intent and the
README's "require you to think about it" philosophy.

## Out of scope

- Test target (data-safety logic is welded to singletons/UserDefaults/the
  real filesystem; testing it is a refactor project of its own).
- Sparkle updates, post-setup settings UI, log rotation, README claims.

## Error handling

No new failure modes: the tick/wake checks reuse `performSync()`, which
already validates drives, takes the sync lock, and refuses concurrent runs.
If drives are unmounted at fire time, the sync fails fast and the overdue
state persists, so the next tick/wake retries (hourly, per attempt spacing).

# Sprout implementation and next checks

Sprout 0.2.1 is a personal, offline time tracker for Android and Windows, with optional Google Drive app-data synchronization.

## Implemented

- Shared tracking, atomic timer switching, running-session editing, descriptions, clients, tags and billable flags.
- Toggl Detailed CSV import, full-session CSV export, verified portable JSON backups, automatic recovery copies, additive restore and a database recovery screen.
- Calendar ranges, search and activity/billable filters, daily/activity/tag reports, averages, busiest day, longest session and start-hour charts.
- Native Android timer/activity and weekly stats widgets, timer notification and document-picker export.
- Windows executable rules, focus/background tracking, idle pausing, lock/sleep handling, tray controls and startup.
- SQLite persistence, per-installation identity, logical-clock journals, deletion propagation and recoverable Drive requests.
- Android and Windows CI build packaging and a reproducible Hyperframes README animation.

## Design choices

Manual timers take priority over Windows rules. Full executable paths distinguish separate installations; filenames work across install locations. Focused matches win over background matches. App rules stay local to the PC.

Drive sync runs on open/resume, on request and every two minutes while Sprout is running. Each device writes only its own journal. Logical clocks and device IDs settle conflicting edits; deletion records prevent stale replicas from reviving records.

Android timers use saved timestamps after the app closes. Widget actions open the app to commit changes. Stats show an update timestamp and refresh while the app is open. There is no permanent background sync service or global timer lock.

## Checks requiring the owner's devices and account

1. Configure Android and Desktop OAuth clients in the same Google Cloud project, sign in with one account, and confirm real offline records, edits and deletions merge in both directions. Check reconnect behavior if test-mode tokens expire.
2. On a physical Android phone, verify launcher widget sizing, notification permission, process termination/recovery and document export. Emulator evidence is in [validation.md](validation.md).
3. On Windows, exercise foreground changes, background apps, app exit, inactivity, lock, sleep, tray controls and startup. A hosted native build confirms compilation, not those runtime behaviors.

## Future improvements

Journal compaction, launcher-specific widget customization and an optional coordinated online timer are possible follow-ups. Android and Windows are the current platform scope.

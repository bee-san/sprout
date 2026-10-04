# Sprout review

Sprout starts from the user's Timebud 0.1.0 Flutter preview. This review led to the 0.2.0 changes below. Android and Windows are the supported targets.

| Finding | Result | Evidence |
| --- | --- | --- |
| Android SQLite startup failed because result-producing PRAGMAs used `execute()` | Use `rawQuery()` for WAL and busy timeout | Android API 35 emulator launches the release build successfully; `lib/store.dart` |
| Timer switching used separate writes and could leave an incomplete switch | Close the previous timer and create the next inside one transaction | A database trigger forces an insertion failure; the original running timer survives rollback in `test/store_test.dart` |
| Editing a running session could finish it accidentally | Keep timer running is enabled by default, with a separate stop action | Controller regression coverage and the session editor |
| Toggl history could not be brought into the app | Validated Detailed CSV import with stable repeat-import IDs and occurrence counts | `test/portability_test.dart`; local private export checked separately |
| Later CSV exports could reset a renamed imported activity | Reuse its stable project ID while keeping local name, client and colour edits | Controller import regression in `test/portability_test.dart` |
| Project client, tags and billable metadata were missing | Add backward-compatible fields, filters, export and backup support | Import, model and controller tests |
| Reports were limited and had no coherent shared filter controls | Add calendar ranges, daily/activity/tag charts, averages, starts by hour and comparable previous periods | `test/reporting_test.dart`; responsive UI checks at 320, 390 and 1360 logical pixels |
| Android had no home-screen controls or stats | Add native RemoteViews timer/activity and weekly stats widgets | Android compilation and emulator checks recorded in `validation.md` |
| Drive requests lacked recovery for expired authorization and temporary API failures | Refresh once after 401 and retry safe GET/PATCH requests after 429/5xx | `test/sync_recovery_test.dart` |
| Sync races, corrupted journals and stale deletions needed stronger evidence | Test interrupted requests, in-flight local edits, pagination, validation, conflict convergence and deletion propagation | Drive simulator tests; both replicas converge without reviving deleted records |
| CSV output could be interpreted as formulas by spreadsheet software | Quote fields and prefix formula-like content | `test/portability_test.dart` |
| Renaming the Windows product changed its data directory | Reuse the legacy database in place and share the original instance lock | Upgrade regression preserves history and device identity in `test/store_test.dart` |
| Windows ZIP omitted Visual C++ runtime DLLs | Bundle release compiler runtimes with CMake and check startup from the extracted archive | Hosted workflow package assertions and Windows persistence check |
| The preview lacked portable local backups | Add JSON snapshots and additive restore; freeze active timers in backups | Backup metadata and repeat-restore tests |

## 0.2.1: backup and recovery review

| Finding | Change | Evidence |
| --- | --- | --- |
| Backups read cached controller data, potentially omitting recent sync writes | Read activities, sessions, preferences and rules from one database transaction | Backup without reloading the controller includes direct database edits; `backup_restore_test.dart` |
| Backup files could be truncated or changed without being detected | Schema 2 includes a canonical SHA-256 checksum; validate before export and read back saved bytes | Tampering/truncation tests; independent checksum verification of Android picker output |
| Android's default writable SQLite corruption handler can erase a damaged database | Probe existing databases through sqflite's non-destructive read-only path and run `quick_check` before opening for writes | Pinned `sqflite_android` 2.4.4 `Database.openReadOnly()`; startup preservation regression and emulator corruption check |
| There was no recovery route when the primary database would not open | Offer local/portable copies, build a separate replacement, check integrity and retain the original database/WAL/SHM | `recovery_test.dart`; recovery confirmation widget test |
| Imports, restores and deletions had no safety copy | Save and verify a snapshot inside the database transaction before writing | An unwritable backup directory aborts changes while tracking remains available |
| Restore previews could go stale during sync | Replan additions against the current transaction snapshot | Newer database edits survive a restore without a controller reload |
| Duplicate IDs, impossible dates and invalid fields were not thoroughly rejected | Validate complete input before writing; cap file size and record counts | Malformed identity/date/type/reference regressions |
| Re-importing history could revive intentional deletions | Respect known tombstones by default; deletion recovery is an explicit restore option | Re-import regression; deletion/restore convergence across two Drive replicas |
| Finished sessions lost their original device attribution during restore | Retain original IDs, labels and timestamps | Metadata round trips, including the private local export |
| Deleted activity names were missing from portable history | Include referenced historical activity metadata; repair older orphaned records with a labelled activity | Fresh backup retains name/client/colour; old schema 1 retains duration |
| Preferences and Windows app rules were omitted | Include them in snapshots with opt-in restore; keep current rules and disable added rules for review | Preferences/rules tests; Google secrets excluded |
| There were no automatic recovery copies or retention checks | Retain seven daily snapshots and eight safety copies; expose restore/export in Settings | Pruning, concurrent saves, backwards clock and damaged-copy tests |
| Cancelling an Android save was indistinguishable from success | Return an explicit cancellation/success result; verify provider output off the UI thread | Actual picker cancellation leaves export status untouched; successful export verifies bytes |
| Windows backup behavior was only covered on Linux | Run backup/restore, filesystem and database recovery tests in the Windows job | `.github/workflows/build.yml`; release build evidence |

The checksum detects accidental damage; it is not a signature or encryption.
Local recovery copies are lost with app data, so the UI explains when to export a
portable copy. [Backup and recovery instructions](backup-recovery.md) describe the
formats, retention, opt-in recovery and remaining sync/account boundaries.

## Remaining boundaries

Drive uses one journal per installation, logical clocks and deterministic conflict resolution. Concurrent offline timers remain distinct and can overlap; this release has no global timer lock, permanent Android sync service or journal compaction. Live Google authorization requires the user's OAuth configuration. Windows native build evidence and runtime limitations are recorded in [validation.md](validation.md).

The report and widget design was informed by [SimpleTimeTracker](https://github.com/Razeeman/Android-SimpleTimeTracker). Its Android source was not copied into Sprout. The Flutter reporting code and Kotlin widgets in this repository were implemented independently.

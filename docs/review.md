# Review of the original preview

Sprout starts from the user's Timebud 0.1.0 Flutter preview. This review led to the 0.2.0 changes below. Android and Windows are the supported targets.

| Finding | Result | Evidence |
| --- | --- | --- |
| Android SQLite startup failed because result-producing PRAGMAs used `execute()` | Use `rawQuery()` for WAL and busy timeout | Android API 35 emulator launches the release build successfully; `lib/store.dart` |
| Timer switching used separate writes and could leave an incomplete switch | Close the previous timer and create the next inside one transaction | A database trigger forces an insertion failure; the original running timer survives rollback in `test/store_test.dart` |
| Editing a running session could finish it accidentally | Keep timer running is enabled by default, with a separate stop action | Controller regression coverage and the session editor |
| Toggl history could not be brought into the app | Validated Detailed CSV import with stable repeat-import IDs and occurrence counts | `test/portability_test.dart`; local private export checked separately |
| Project client, tags and billable metadata were missing | Add backward-compatible fields, filters, export and backup support | Import, model and controller tests |
| Reports were limited and had no coherent shared filter controls | Add calendar ranges, daily/activity/tag charts, averages, starts by hour and comparable previous periods | `test/reporting_test.dart`; responsive UI checks at 320, 390 and 1360 logical pixels |
| Android had no home-screen controls or stats | Add native RemoteViews timer/activity and weekly stats widgets | Android compilation and emulator checks recorded in `validation.md` |
| Drive requests lacked recovery for expired authorization and temporary API failures | Refresh once after 401 and retry safe GET/PATCH requests after 429/5xx | `test/sync_recovery_test.dart` |
| Sync races, corrupted journals and stale deletions needed stronger evidence | Test interrupted requests, in-flight local edits, pagination, validation, conflict convergence and deletion propagation | Drive simulator tests; both replicas converge without reviving deleted records |
| CSV output could be interpreted as formulas by spreadsheet software | Quote fields and prefix formula-like content | `test/portability_test.dart` |
| Windows ZIP omitted Visual C++ runtime DLLs | Bundle release compiler runtimes with CMake and check startup from the extracted archive | Hosted workflow package assertions and Windows persistence check |
| The preview lacked portable local backups | Add JSON snapshots and additive restore; freeze active timers in backups | Backup metadata and repeat-restore tests |

## Remaining boundaries

Drive uses one journal per installation, logical clocks and deterministic conflict resolution. Concurrent offline timers remain distinct and can overlap; this release has no global timer lock, permanent Android sync service or journal compaction. Live Google authorization requires the user's OAuth configuration. Windows native build evidence and runtime limitations are recorded in [validation.md](validation.md).

The report and widget design was informed by [SimpleTimeTracker](https://github.com/Razeeman/Android-SimpleTimeTracker). Its Android source was not copied into Sprout. The Flutter reporting code and Kotlin widgets in this repository were implemented independently.

# Validation record

Checked on 4 October 2026 using Flutter **3.44.4**, Dart **3.12.2**, JDK 17 and Android SDK 36.

| Check | Result |
| --- | --- |
| Flutter analysis | No issues |
| Dart formatting for `lib/` and `test/` | Clean |
| Automated tests, including the private local Toggl check | All 26 passed |
| Toggl export supplied locally by the owner | All 712 rows imported; total duration exactly 2,868,154 seconds; repeating the import adds zero rows |
| Import then sync to a second replica | All 712 entries converge through the Drive protocol simulator with descriptions/tags/client/billable metadata retained |
| Responsive Flutter UI | Track and Reports checked at 320, 390 and 1360 logical pixels, with bundled fonts and Material icons |
| Android release compilation | ARM64 and x86_64 APKs built successfully |
| Android signature and manifest | APK Signature Scheme v2 verified; Sprout label, API 24 minimum and widget providers present |
| Android startup on API 35 emulator | Installed release APK launches; the original Android SQLite PRAGMA failure is fixed |
| Hyperframes composition | Check passes: zero runtime, layout and motion errors; 50/50 text contrast checks pass; one advisory composition-structure warning |
| README GIF | 960×540, 180 frames, 15 fps, 12 seconds, loops continuously; actual app screenshots with synthetic data |
| Hosted Android / Windows builds | First public workflow passed all three jobs; run linked below |
| Android timer widget | Added through Pixel Launcher; activity start and session stop both persist in the app |
| Android process recovery | Editing retains a running timer; killing the process and relaunching retains the same session ID and start timestamp |
| Android backup/restore | JSON exported through the picker; after a fresh signed install, all 4 activities and 14 sessions restore successfully |
| Android weekly stats widget | Added through Pixel Launcher; shows 14 sessions, date-clipped totals and an update timestamp |
| Windows preview upgrade | Reopens the original database in place and preserves installation identity; regression test passes |

## What the tests exercise

Transactional timer switching and rollback, running-session editing, continuation metadata, local persistence, logical clocks, overlap detection, automatic-session heartbeat limits, executable rules and mobile add/start/stop/history behavior.

Imports cover BOMs, quoted and multiline CSV cells, clients, tasks, tags, billable flags, timezone offsets, midnight crossings, invalid input, exact durations and repeated imports. JSON backup/restore freezes active timers and preserves metadata without account credentials. CSV output protects formula-like values.

The Drive simulator exercises pagination, unchanged journal checksums, offline recovery, authorization refresh, temporary API failure retries, local writes during upload, invalid journals, deterministic concurrent edit convergence, stopped timers and deletion propagation without revival. Network failures do not mark unuploaded changes as synced.

Report checks cover clipped date boundaries, sessions across midnight, empty days, billable totals, tags and session starts by local hour. Screenshot tests check phone and desktop widths with actual fonts.

The owner's CSV stays outside the repository. Its extra validation test is opt-in:

```sh
SPROUT_TOGGL_CSV=/path/to/private-export.csv flutter test test/portability_test.dart
```

Normal public CI runs the other 25 tests without that private file.

## Device and account boundaries

The Android emulator is an isolated API 35 Pixel profile. Device checks use synthetic history. Physical-phone launcher behavior, battery restrictions and manufacturer-specific notification behavior still require checking on the owner's phone.

Live Google sign-in and real Drive API synchronization require the owner's OAuth clients and account; these were not available in this environment. The simulator verifies application protocol behavior, not Google's authorization configuration.

This Linux workspace cannot run the Windows GUI. The hosted Windows workflow checks native compilation, portable packaging and basic startup/persistence on its runner. Interactive focus tracking, idle/lock/sleep handling, tray controls and startup at login require checking on the owner’s Windows machine.

Published Android preview APKs use this repository’s stable release key, stored privately and in encrypted Actions secrets. Local builds or forks without that configuration use a development key. Register the installed APK’s fingerprint for Android Google sign-in; see [Android signing](android-signing.md).

## Public build evidence

Public repository: [bee-san/sprout](https://github.com/bee-san/sprout).

The [first hosted workflow](https://github.com/bee-san/sprout/actions/runs/37195228158) passed checks, ARM64/x86_64 Android builds and the native Windows build for `b2bd782f9ce7528ed8124dd3fc3540391a3ee643`. Its Windows ZIP was downloaded and CRC-checked. The [second Windows build](https://github.com/bee-san/sprout/actions/runs/37195910253) bundles the compiler runtime DLLs and passed startup/SQLite integrity checks from the extracted archive. The final workflow also includes the font license in the Android/Windows app assets and retains the original Windows database path for existing installations.

The README status badge follows the current main branch. The build's source SHA and artifacts are available on each workflow run.

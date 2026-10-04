# Validation record

Checked on 4 October 2026 using Flutter **3.44.4**, Dart **3.12.2**, JDK 17 and Android SDK 36.

| Check | Result |
| --- | --- |
| Flutter analysis | No issues |
| Dart formatting for `lib/` and `test/` | Clean |
| Automated tests, including the private local Toggl check | All 25 passed |
| Toggl export supplied locally by the owner | All 712 rows imported; total duration exactly 2,868,154 seconds; repeating the import adds zero rows |
| Import then sync to a second replica | All 712 entries converge through the Drive protocol simulator with descriptions/tags/client/billable metadata retained |
| Responsive Flutter UI | Track and Reports checked at 320, 390 and 1360 logical pixels, with bundled fonts and Material icons |
| Android release compilation | ARM64 and x86_64 APKs built successfully |
| Android signature and manifest | APK Signature Scheme v2 verified; Sprout label, API 24 minimum and widget providers present |
| Android startup on API 35 emulator | Installed release APK launches; the original Android SQLite PRAGMA failure is fixed |
| Hyperframes composition | Check passes: zero runtime, layout and motion errors; 50/50 text contrast checks pass; one advisory composition-structure warning |
| README GIF | 960×540, 180 frames, 15 fps, 12 seconds, loops continuously; actual app screenshots with synthetic data |
| Hosted Android / Windows builds | Recorded after the first public CI run below |

## What the tests exercise

Transactional timer switching and rollback, running-session editing, continuation metadata, local persistence, logical clocks, overlap detection, automatic-session heartbeat limits, executable rules and mobile add/start/stop/history behavior.

Imports cover BOMs, quoted and multiline CSV cells, clients, tasks, tags, billable flags, timezone offsets, midnight crossings, invalid input, exact durations and repeated imports. JSON backup/restore freezes active timers and preserves metadata without account credentials. CSV output protects formula-like values.

The Drive simulator exercises pagination, unchanged journal checksums, offline recovery, authorization refresh, temporary API failure retries, local writes during upload, invalid journals, deterministic concurrent edit convergence, stopped timers and deletion propagation without revival. Network failures do not mark unuploaded changes as synced.

Report checks cover clipped date boundaries, sessions across midnight, empty days, billable totals, tags and session starts by local hour. Screenshot tests check phone and desktop widths with actual fonts.

The owner's CSV stays outside the repository. Its extra validation test is opt-in:

```sh
SPROUT_TOGGL_CSV=/path/to/private-export.csv flutter test test/portability_test.dart
```

Normal public CI runs the other 24 tests without that private file.

## Device and account boundaries

The Android emulator is an isolated API 35 Pixel profile. Device checks use synthetic history. Physical-phone launcher behavior, battery restrictions and manufacturer-specific notification behavior still require checking on the owner's phone.

Live Google sign-in and real Drive API synchronization require the owner's OAuth clients and account; these were not available in this environment. The simulator verifies application protocol behavior, not Google's authorization configuration.

This Linux workspace cannot run the Windows GUI. A successful hosted Windows native build confirms compilation and packaging. Focus tracking, idle/lock/sleep handling, tray controls and startup require a Windows runtime check.

Android preview APKs use a development signing key. Use a stable release key for long-term updates and register its fingerprint for Android Google sign-in; see [Android signing](android-signing.md).

## Public build evidence

The repository and workflow run links are added after publication. The status badge in the README follows the current main branch.

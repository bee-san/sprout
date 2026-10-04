import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;

import 'backups.dart';
import 'brand.dart';
import 'model.dart';
import 'portability.dart';
import 'recovery.dart';

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({
    super.key,
    required this.databasePath,
    required this.error,
    required this.onRecovered,
  });
  final String? databasePath;
  final String error;
  final Future<void> Function() onRecovered;
  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  final navigatorKey = GlobalKey<NavigatorState>();
  List<LocalBackup> copies = [];
  bool busy = false;
  String? message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.databasePath == null) return;
    try {
      final list = await BackupVault(
        Directory(path.join(path.dirname(widget.databasePath!), 'backups')),
      ).list();
      if (mounted) setState(() => copies = list);
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Local recovery copies could not be opened. You can choose a portable backup.',
        );
      }
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => message = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _choose() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Sprout backup', extensions: ['json']),
      ],
    );
    if (file == null) return;
    if (await file.length() > maxPortableBytes) {
      throw const FormatException('Choose a backup smaller than 32 MB.');
    }
    await _recover(await file.readAsString());
  }

  Future<void> _recover(String content) async {
    final data = decodeBackup(content);
    if (!mounted || widget.databasePath == null) return;
    final dialogContext = navigatorKey.currentContext;
    if (dialogContext == null) return;
    final approved =
        await showDialog<bool>(
          context: dialogContext,
          builder: (ctx) => AlertDialog(
            title: const Text('Recover from this backup?'),
            content: SingleChildScrollView(
              child: Text(
                '${data.verified ? 'Checksum verified.' : 'Legacy backup; records validated.'}\n\n'
                '${data.sessions.length} entries · ${formatDuration(data.total, seconds: true)}\n'
                'Saved ${DateFormat.yMMMd().add_jm().format(data.exportedAt)}\n\n'
                'Sprout will create a new local database with this saved time. Your original database and recovery copies are preserved. Google sign-in stays on this device. Preferences and rules can be restored later from Settings.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Recover'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved) return;
    await recoverDatabase(databasePath: widget.databasePath!, content: content);
    await widget.onRecovered();
  }

  Future<void> _export(LocalBackup copy) async {
    final content = await readPortableFile(copy.file);
    decodeBackup(content);
    if (Platform.isAndroid) {
      await const MethodChannel(
        'dev.beesan.timebud/platform',
      ).invokeMethod<bool>('exportDocument', {
        'name': path.basename(copy.file.path),
        'content': content,
        'mimeType': 'application/json',
      });
    } else {
      final location = await getSaveLocation(
        suggestedName: path.basename(copy.file.path),
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Sprout backup', extensions: ['json']),
        ],
      );
      if (location != null) {
        await writeVerifiedDocument(File(location.path), content, backup: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    title: 'Sprout recovery',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Nunito',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF355E49),
        surface: const Color(0xFFFAF8F3),
      ),
    ),
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Center(child: SproutMark(size: 96)),
                const SizedBox(height: 16),
                const Text(
                  'Let’s recover your garden.',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Sprout could not open your local data. Your database has not been reset. You can retry, or recover saved time from a backup.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => _perform(widget.onRecovered),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy || widget.databasePath == null
                          ? null
                          : () => _perform(_choose),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose a backup'),
                    ),
                  ],
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: LinearProgressIndicator(),
                  ),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(message!),
                  ),
                if (copies.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'Your recovery copies',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  ...copies.map(
                    (copy) => Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              copy.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (copy.data != null) ...[
                              Text(
                                '${copy.data!.sessions.length} entries · ${DateFormat.yMMMd().add_jm().format(copy.data!.exportedAt)}',
                              ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => _perform(
                                            () async => _recover(
                                              await readPortableFile(copy.file),
                                            ),
                                          ),
                                    child: const Text('Recover'),
                                  ),
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => _perform(() => _export(copy)),
                                    child: const Text('Export'),
                                  ),
                                ],
                              ),
                            ] else
                              Text(copy.error!),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                ExpansionTile(
                  title: const Text('Error details'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(widget.error),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

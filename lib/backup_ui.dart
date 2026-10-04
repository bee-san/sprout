import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'model.dart';
import 'portability.dart';
import 'store.dart';

class RestorePreviewDialog extends StatefulWidget {
  const RestorePreviewDialog({
    super.key,
    required this.backup,
    required this.snapshot,
    required this.fileName,
  });
  final BackupData backup;
  final StoreSnapshot snapshot;
  final String fileName;
  @override
  State<RestorePreviewDialog> createState() => _RestorePreviewDialogState();
}

class _RestorePreviewDialogState extends State<RestorePreviewDialog> {
  bool includeDeleted = false;
  bool deviceSettings = false;
  @override
  Widget build(BuildContext context) {
    final data = widget.backup;
    final options = RestoreOptions(
      includeDeleted: includeDeleted,
      deviceSettings: deviceSettings,
    );
    final plan = widget.snapshot.restorePlan(data, options);
    final safePlan = widget.snapshot.restorePlan(data, const RestoreOptions());
    return AlertDialog(
      title: const Text('Restore your garden'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.fileName,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    data.verified ? Icons.verified_outlined : Icons.history,
                    color: const Color(0xFF355E49),
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      data.verified
                          ? 'Checksum verified'
                          : 'Legacy backup · records validated',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Saved ${DateFormat.yMMMd().add_jm().format(data.exportedAt)}',
              ),
              Text(
                '${data.sessions.length} entries · ${data.activities.length} activities · ${formatDuration(data.total, seconds: true)}',
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFE9EFE6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${plan.sessions.length} entries and ${plan.activities.length} activities to add',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${plan.skipped} entries and ${plan.keptActivities} activities already present or skipped.',
                    ),
                    if (plan.conflicts > 0)
                      Text(
                        '${plan.conflicts} changed records will keep your current edits.',
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Your current entries and running timer stay intact. A recovery copy is saved before changes are made.',
              ),
              if (data.frozenTimers > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${data.frozenTimers} backed-up timers are restored as finished entries.',
                ),
              ],
              if (data.recoveredActivityNames > 0) ...[
                const SizedBox(height: 8),
                const Text(
                  'This older backup omitted deleted activity names. Their time is kept under “Recovered activity”.',
                ),
              ],
              if (safePlan.deletedSkipped > 0)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Recover intentionally deleted records'),
                  subtitle: Text(
                    '${safePlan.deletedSkipped} records. Restored deletions will also sync to your other devices.',
                  ),
                  value: includeDeleted,
                  onChanged: (v) => setState(() => includeDeleted = v ?? false),
                ),
              if (data.rules.isNotEmpty || data.preferences.isNotEmpty)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Restore device preferences and app rules'),
                  subtitle: const Text(
                    'Existing rules stay. Added Windows rules start disabled for you to review. Google sign-in and start at login stay as they are.',
                  ),
                  value: deviceSettings,
                  onChanged: (v) => setState(() => deviceSettings = v ?? false),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: plan.hasChanges
              ? () => Navigator.pop(context, options)
              : null,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

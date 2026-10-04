import 'package:flutter/material.dart';
import 'brand.dart';
import 'controller.dart';
import 'model.dart';
import 'reporting.dart';

class DashboardView extends StatelessWidget {
  const DashboardView({
    super.key,
    required this.tracker,
    required this.onAdd,
    required this.onEditActivity,
    required this.onDeleteActivity,
    required this.onStart,
    required this.onStop,
    required this.onContinue,
    required this.onEditSession,
    required this.onReports,
  });
  final Tracker tracker;
  final VoidCallback onAdd;
  final void Function(Activity) onEditActivity;
  final void Function(Activity) onDeleteActivity;
  final void Function(Activity) onStart;
  final VoidCallback onStop;
  final void Function(Session) onContinue;
  final void Function(Session) onEditSession;
  final VoidCallback onReports;

  @override
  Widget build(BuildContext context) {
    final t = tracker;
    final current = t.current;
    final day = dateOnly(t.now);
    final today = ReportStats(
      t.sessions,
      day,
      DateTime(day.year, day.month, day.day + 1),
      t.now,
    );
    final week = DateTime(day.year, day.month, day.day - day.weekday + 1);
    final weekly = ReportStats(t.sessions, week, t.now, t.now);
    final recent = t.sessions.where((s) => !s.isRunning).take(3).toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (t.error != null)
          Card(
            color: const Color(0xFFFFEFCF),
            child: ListTile(
              leading: const Icon(Icons.warning_amber),
              title: Text(t.error!),
              trailing: IconButton(
                tooltip: 'Dismiss',
                onPressed: () {
                  t.error = null;
                  t.reload();
                },
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        if (t.sync.error != null)
          Card(
            color: const Color(0xFFFFEFCF),
            child: ListTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: Text(t.sync.error!),
            ),
          ),
        Text(
          'Make room for your day.',
          style: Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text('A little focus. A little growth.'),
        const SizedBox(height: 24),
        Card(
          color: current == null
              ? const Color(0xFFE9EFE6)
              : const Color(0xFFF4E5E0),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current == null
                            ? 'READY WHEN YOU ARE'
                            : 'GROWING YOUR TIME',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                          color: Color(0xFF355E49),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        current == null
                            ? 'Plant a little focus'
                            : t.activityName(current.activityId),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          current == null
                              ? '00:00:00'
                              : formatDuration(
                                  t.now.difference(current.start),
                                  seconds: true,
                                ),
                          style: Theme.of(context).textTheme.displayMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w400,
                                fontFeatures: [
                                  const FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (current == null)
                        const Text('Choose an activity to begin.')
                      else ...[
                        if (current.note.isNotEmpty)
                          Text(
                            current.note,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: onStop,
                              icon: const Icon(Icons.stop_rounded),
                              label: const Text('Stop'),
                            ),
                            TextButton.icon(
                              onPressed: () => onEditSession(current),
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              label: const Text('Details'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (MediaQuery.sizeOf(context).width >= 420)
                  const Padding(
                    padding: EdgeInsets.only(left: 24),
                    child: SproutMark(size: 110),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _miniStat(context, 'Today', formatDuration(today.total)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _miniStat(
                context,
                'This week',
                formatDuration(weekly.total),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                'Your activities',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (t.activities.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                const SproutMark(size: 88),
                const SizedBox(height: 12),
                Text(
                  'What would you like to grow?',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Add an activity such as Japanese, Reading, or Deep work.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 820
                ? 4
                : constraints.maxWidth >= 540
                ? 3
                : constraints.maxWidth >= 310
                ? 2
                : 1;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: t.activities.map((a) {
                final running = current?.activityId == a.id;
                return SizedBox(
                  width: width,
                  child: Card(
                    margin: EdgeInsets.zero,
                    color: Color(
                      a.color,
                    ).withValues(alpha: running ? 0.20 : 0.09),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.circle,
                                color: Color(a.color),
                                size: 15,
                              ),
                              const Spacer(),
                              PopupMenuButton<String>(
                                tooltip: 'Manage ${a.name}',
                                onSelected: (value) => value == 'edit'
                                    ? onEditActivity(a)
                                    : onDeleteActivity(a),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Edit activity'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete activity'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          Text(
                            a.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (a.client.isNotEmpty)
                            Text(
                              a.client,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  formatDuration(
                                    today.byActivity[a.id] ?? Duration.zero,
                                  ),
                                ),
                              ),
                              IconButton.filledTonal(
                                tooltip:
                                    '${running ? 'Stop' : 'Start'} ${a.name}',
                                onPressed: running ? onStop : () => onStart(a),
                                icon: Icon(
                                  running
                                      ? Icons.stop_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 28),
        if (recent.isNotEmpty) ...[
          Text(
            'Pick up where you left off',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          ...recent.map(
            (s) => Card(
              child: ListTile(
                onTap: () => onEditSession(s),
                leading: Icon(
                  Icons.history,
                  color: Color(t.activity(s.activityId)?.color ?? 0xFF567561),
                ),
                title: Text(
                  s.note.isEmpty ? t.activityName(s.activityId) : s.note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${t.activityName(s.activityId)} · ${formatDuration(s.duration(t.now))}',
                ),
                trailing: IconButton(
                  tooltip: 'Continue session',
                  onPressed: t.activity(s.activityId) == null
                      ? null
                      : () => onContinue(s),
                  icon: const Icon(Icons.play_circle_outline),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onReports,
          icon: const Icon(Icons.bar_chart_rounded),
          label: const Text('See your garden of time'),
        ),
      ],
    );
  }

  Widget _miniStat(BuildContext context, String label, String value) =>
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      );
}

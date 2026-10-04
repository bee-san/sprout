import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'controller.dart';
import 'model.dart';
import 'reporting.dart';

class ReportsView extends StatelessWidget {
  const ReportsView({
    super.key,
    required this.tracker,
    required this.sessions,
    required this.comparisonSessions,
    required this.from,
    required this.to,
    required this.controls,
    required this.filters,
    required this.onActivity,
    required this.onExport,
  });
  final Tracker tracker;
  final List<Session> sessions;
  final List<Session> comparisonSessions;
  final DateTime from;
  final DateTime to;
  final Widget controls;
  final Widget filters;
  final void Function(String) onActivity;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final stats = ReportStats(sessions, from, to, tracker.now);
    final length = math.max(1, calendarDays(from, to));
    final previousFrom = DateTime(from.year, from.month, from.day - length);
    // Compare the same elapsed portion when the selected period is still open.
    final elapsedEnd = to.isAfter(tracker.now) ? tracker.now : to;
    final previousTo = DateTime(
      elapsedEnd.year,
      elapsedEnd.month,
      elapsedEnd.day - length,
      elapsedEnd.hour,
      elapsedEnd.minute,
      elapsedEnd.second,
    );
    final previous = ReportStats(
      comparisonSessions,
      previousFrom,
      previousTo,
      tracker.now,
    );
    final difference = stats.total - previous.total;
    final entries = stats.byActivity.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tags = stats.byTag.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final days = stats.chartDays(tracker.now);
    final colors = entries
        .map((e) => Color(tracker.activity(e.key)?.color ?? 0xFF567561))
        .toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'A little perspective',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Export this report',
              onPressed: onExport,
              icon: const Icon(Icons.download_outlined),
            ),
          ],
        ),
        const Text('See where your time grows.'),
        const SizedBox(height: 16),
        controls,
        const SizedBox(height: 12),
        filters,
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final width =
                (constraints.maxWidth -
                    12 * (constraints.maxWidth >= 850 ? 3 : 1)) /
                (constraints.maxWidth >= 850 ? 4 : 2);
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                StatTile(
                  width: width,
                  label: 'Tracked time',
                  value: formatDuration(stats.total),
                  icon: Icons.timelapse,
                ),
                StatTile(
                  width: width,
                  label: 'Daily average',
                  value: formatDuration(stats.averageDay),
                  icon: Icons.wb_sunny_outlined,
                ),
                StatTile(
                  width: width,
                  label: 'Sessions',
                  value: '${stats.count}',
                  icon: Icons.local_florist_outlined,
                ),
                StatTile(
                  width: width,
                  label: 'Billable time',
                  value: formatDuration(stats.billable),
                  icon: Icons.paid_outlined,
                ),
              ],
            );
          },
        ),
        if (stats.count == 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 36),
            child: Text(
              'No time in this selection yet. Try another date range or start an activity.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        if (stats.count > 0) ...[
          const SizedBox(height: 24),
          _panel(
            context,
            'Your days',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  days.length == 14 && stats.dayCount > 14
                      ? 'Last 14 days in this selection'
                      : 'Daily totals',
                ),
                const SizedBox(height: 20),
                Semantics(
                  label: days
                      .map(
                        (d) =>
                            '${DateFormat('d MMM').format(d.key)} ${formatDuration(d.value)}',
                      )
                      .join(', '),
                  child: SizedBox(
                    height: 156,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: days.map((d) {
                        final maxTime = days.fold<int>(
                          1,
                          (v, d) => math.max(v, d.value.inMilliseconds),
                        );
                        return Expanded(
                          child: Tooltip(
                            message:
                                '${DateFormat('EEE d MMM').format(d.key)} · ${formatDuration(d.value)}',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Container(
                                    height: math.max(
                                      4,
                                      d.value.inMilliseconds / maxTime * 112,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          dateOnly(d.key) ==
                                              dateOnly(tracker.now)
                                          ? const Color(0xFF355E49)
                                          : const Color(0xFFA7B89A),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    DateFormat(
                                      days.length <= 7 ? 'E' : 'd',
                                    ).format(d.key),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _panel(
            context,
            'Activity breakdown',
            LayoutBuilder(
              builder: (context, size) {
                final ring = SizedBox.square(
                  dimension: 176,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        size: const Size.square(176),
                        painter: _DonutPainter(
                          entries
                              .map((e) => e.value.inMilliseconds.toDouble())
                              .toList(),
                          colors,
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${stats.activeDays}',
                            style: Theme.of(context).textTheme.headlineLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const Text('active days'),
                        ],
                      ),
                    ],
                  ),
                );
                final legend = Column(
                  children: entries
                      .map(
                        (e) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.circle,
                            size: 14,
                            color: Color(
                              tracker.activity(e.key)?.color ?? 0xFF567561,
                            ),
                          ),
                          title: Text(tracker.activityName(e.key), maxLines: 2),
                          subtitle: Text(
                            '${(e.value.inMilliseconds / math.max(1, stats.total.inMilliseconds) * 100).toStringAsFixed(1)}% of tracked time',
                          ),
                          trailing: Text(formatDuration(e.value)),
                          onTap: () => onActivity(e.key),
                        ),
                      )
                      .toList(),
                );
                return size.maxWidth >= 580
                    ? Row(
                        children: [
                          ring,
                          const SizedBox(width: 32),
                          Expanded(child: legend),
                        ],
                      )
                    : Column(
                        children: [ring, const SizedBox(height: 16), legend],
                      );
              },
            ),
          ),
          const SizedBox(height: 16),
          _panel(
            context,
            'Small insights',
            Column(
              children: [
                _insight(
                  'Average session',
                  formatDuration(stats.averageSession),
                ),
                _insight(
                  'Longest session in selection',
                  formatDuration(stats.longest),
                ),
                if (stats.bestDay != null)
                  _insight(
                    'Busiest day · ${DateFormat('EEE d MMM').format(stats.bestDay!.key)}',
                    formatDuration(stats.bestDay!.value),
                  ),
                _insight(
                  'Compared with previous period',
                  '${difference.isNegative ? '−' : '+'}${formatDuration(difference.abs())}',
                ),
                const SizedBox(height: 4),
                const Text(
                  'Daily averages include untracked days. Comparisons use the same elapsed time.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF596254)),
                ),
              ],
            ),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 16),
            _panel(
              context,
              'Time by tag',
              Column(
                children: [
                  ...tags.map(
                    (e) => _insight('#${e.key}', formatDuration(e.value)),
                  ),
                  const Text(
                    'A session can count toward more than one tag.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          _panel(
            context,
            'When you get started',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Session starts by local hour'),
                const SizedBox(height: 16),
                SizedBox(
                  height: 88,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: List.generate(
                      24,
                      (i) => Expanded(
                        child: Tooltip(
                          message:
                              '${i.toString().padLeft(2, '0')}:00 · ${stats.startsByHour[i]} starts',
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: Container(
                              height: math.max(
                                3,
                                stats.startsByHour[i] /
                                    math.max(
                                      1,
                                      stats.startsByHour.reduce(math.max),
                                    ) *
                                    88,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD6A18A),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('00:00'),
                    Text('06:00'),
                    Text('12:00'),
                    Text('18:00'),
                    Text('23:00'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _panel(BuildContext context, String title, Widget child) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
  Widget _insight(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.width = 210,
  });
  final double width;
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    width: width,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xFFE9EFE6),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: const Color(0xFF355E49)),
        const SizedBox(height: 12),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text(label),
      ],
    ),
  );
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.values, this.colors);
  final List<double> values;
  final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return;
    var angle = -math.pi / 2;
    final rect = Offset.zero & size;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      canvas.drawArc(
        rect.deflate(14),
        angle,
        math.max(0, sweep - 0.035),
        false,
        Paint()
          ..color = colors[i]
          ..strokeWidth = 18
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.values != values || old.colors != colors;
}

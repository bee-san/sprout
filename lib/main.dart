import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'controller.dart';
import 'google_auth.dart';
import 'model.dart';
import 'store.dart';
import 'portability.dart';
import 'brand.dart';
import 'dashboard_view.dart';
import 'reports_view.dart';
import 'backups.dart';
import 'backup_ui.dart';
import 'recovery_screen.dart';

Future<T?> completedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final route = DialogRoute<T>(context: context, builder: builder);
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result;
}

const palette = [
  0xFF567561,
  0xFFAF657D,
  0xFF7165A1,
  0xFFAD763D,
  0xFF477C95,
  0xFF93664F,
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? databasePath;
  Store? store;
  Tracker? tracker;
  try {
    databasePath = await Store.defaultDatabasePath();
    store = await Store.open(databasePath: databasePath);
    tracker = Tracker(store, GoogleAuth());
    await tracker.initialize();
    runApp(Sprout(tracker: tracker));
  } catch (e) {
    tracker?.dispose();
    try {
      await store?.close();
    } catch (_) {}
    runApp(
      RecoveryScreen(
        databasePath: databasePath,
        error: '$e',
        onRecovered: main,
      ),
    );
  }
}

class Sprout extends StatelessWidget {
  const Sprout({super.key, required this.tracker});
  final Tracker tracker;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Sprout',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Nunito',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF355E49),
        surface: const Color(0xFFFAF8F3),
      ),
      scaffoldBackgroundColor: const Color(0xFFFAF8F3),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFAF8F3),
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    ),
    home: Home(tracker: tracker),
  );
}

class Home extends StatefulWidget {
  const Home({super.key, required this.tracker});
  final Tracker tracker;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  int page = 0;
  String period = 'Today';
  String? activityFilter;
  DateTime? anchor;
  DateTimeRange? customRange;
  String query = '';
  bool billableOnly = false;
  String? dataAction;
  final searchController = TextEditingController();
  Tracker get t => widget.tracker;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(t.resume());
    if (state == AppLifecycleState.paused) {
      unawaited(t.createRecoveryCopy(force: true));
    }
  }

  Future<void> dataTask(String label, Future<void> Function() action) async {
    if (dataAction != null) return;
    setState(() => dataAction = label);
    try {
      await action();
    } finally {
      if (mounted) setState(() => dataAction = null);
    }
  }

  Future<void> perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
        );
      }
    }
  }

  (DateTime, DateTime) get range {
    final now = anchor ?? t.now;
    final day = DateTime(now.year, now.month, now.day);
    if (period == 'Custom' && customRange != null) {
      return (
        customRange!.start,
        DateTime(
          customRange!.end.year,
          customRange!.end.month,
          customRange!.end.day + 1,
        ),
      );
    }
    return switch (period) {
      'This week' => (
        DateTime(day.year, day.month, day.day - (day.weekday - 1)),
        DateTime(day.year, day.month, day.day - (day.weekday - 1) + 7),
      ),
      'This month' => (
        DateTime(now.year, now.month),
        DateTime(now.year, now.month + 1),
      ),
      'All time' => (
        t.sessions.isEmpty
            ? day
            : DateTime(
                t.sessions.last.start.toLocal().year,
                t.sessions.last.start.toLocal().month,
                t.sessions.last.start.toLocal().day,
              ),
        t.now,
      ),
      _ => (day, DateTime(day.year, day.month, day.day + 1)),
    };
  }

  List<Session> get visibleSessions {
    final (from, to) = range;
    return filteredSessions
        .where(
          (s) =>
              s.start.isBefore(to) &&
              (s.effectiveEnd(t.now).isAfter(from) ||
                  s.start.isAtSameMomentAs(from)),
        )
        .toList();
  }

  List<Session> get filteredSessions {
    final search = query.trim().toLowerCase();
    return t.sessions
        .where(
          (s) =>
              (activityFilter == null || s.activityId == activityFilter) &&
              (!billableOnly || s.billable) &&
              (search.isEmpty ||
                  '${t.activityName(s.activityId)} ${t.activity(s.activityId)?.client ?? ''} ${s.note} ${s.tags.join(' ')} ${s.deviceName}'
                      .toLowerCase()
                      .contains(search)),
        )
        .toList();
  }

  Duration totalFor(String id) {
    final (from, to) = range;
    return visibleSessions
        .where((s) => s.activityId == id)
        .fold(Duration.zero, (total, s) => total + s.within(from, to, t.now));
  }

  Widget periodPicker() => DropdownButton<String>(
    value: period,
    underline: const SizedBox(),
    items: [
      'Today',
      'This week',
      'This month',
      'All time',
      if (period == 'Custom') 'Custom',
    ].map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
    onChanged: (value) => setState(() {
      period = value!;
      anchor = null;
    }),
  );

  Widget dateControls() {
    final (from, to) = range;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        periodPicker(),
        if (period != 'All time' && period != 'Custom') ...[
          IconButton(
            tooltip: 'Previous period',
            onPressed: () => shiftPeriod(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: 'Next period',
            onPressed: from.isAfter(t.now) ? null : () => shiftPeriod(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
        OutlinedButton.icon(
          onPressed: chooseDates,
          icon: const Icon(Icons.date_range_outlined, size: 18),
          label: Text(
            period == 'All time'
                ? 'Choose dates'
                : '${DateFormat('d MMM').format(from)}${to.difference(from).inDays > 1 ? ' – ${DateFormat('d MMM').format(to.subtract(const Duration(days: 1)))}' : ''}',
          ),
        ),
        if (anchor != null || period == 'Custom')
          TextButton(
            onPressed: () => setState(() {
              anchor = null;
              period = 'Today';
              customRange = null;
            }),
            child: const Text('Today'),
          ),
      ],
    );
  }

  void shiftPeriod(int direction) => setState(() {
    final day = anchor ?? t.now;
    anchor = switch (period) {
      'This month' => DateTime(day.year, day.month + direction),
      'This week' => DateTime(day.year, day.month, day.day + direction * 7),
      _ => DateTime(day.year, day.month, day.day + direction),
    };
  });

  Future<void> chooseDates() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1970),
      lastDate: DateTime.now(),
      initialDateRange: customRange,
    );
    if (picked != null) {
      setState(() {
        customRange = picked;
        period = 'Custom';
        anchor = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: t,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 800;
      final destinations = [
        const NavigationDestination(
          icon: Icon(Icons.timer_outlined),
          selectedIcon: Icon(Icons.timer),
          label: 'Track',
        ),
        const NavigationDestination(
          icon: Icon(Icons.history),
          label: 'History',
        ),
        const NavigationDestination(
          icon: Icon(Icons.bar_chart_rounded),
          label: 'Reports',
        ),
        if (Platform.isWindows)
          const NavigationDestination(
            icon: Icon(Icons.apps),
            label: 'App rules',
          ),
        const NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
      ];
      final titles = [
        'Track',
        'History',
        'Reports',
        if (Platform.isWindows) 'App rules',
        'Settings',
      ];
      final body = switch (titles[page]) {
        'History' => history(),
        'Reports' => reports(),
        'App rules' => appRules(),
        'Settings' => settings(),
        _ => dashboard(),
      };
      return Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const SproutMark(size: 32),
              const SizedBox(width: 10),
              const Text(
                'Sprout',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                ),
              ),
              if (wide) ...[
                const SizedBox(width: 20),
                Text(
                  titles[page],
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ],
          ),
          actions: [
            if (t.auth.connected)
              IconButton(
                tooltip:
                    t.sync.error ??
                    (t.syncing ? 'Syncing' : 'Sync Google Drive'),
                onPressed: t.syncing ? null : () => perform(t.synchronize),
                icon: t.syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        t.sync.error == null
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                      ),
              ),
            const SizedBox(width: 12),
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: page,
                destinations: destinations,
                onDestinationSelected: (value) => setState(() => page = value),
              ),
        body: Row(
          children: [
            if (wide)
              NavigationRail(
                selectedIndex: page,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (value) => setState(() => page = value),
                destinations: destinations
                    .map(
                      (d) => NavigationRailDestination(
                        icon: d.icon,
                        selectedIcon: d.selectedIcon,
                        label: Text(d.label),
                      ),
                    )
                    .toList(),
              ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: body,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  Widget dashboard() => DashboardView(
    tracker: t,
    onAdd: () => editActivity(),
    onEditActivity: editActivity,
    onDeleteActivity: deleteActivity,
    onStart: (a) => perform(() => t.start(a)),
    onStop: () => perform(t.stop),
    onContinue: (s) => perform(() => t.continueSession(s)),
    onEditSession: editSession,
    onReports: () => setState(() {
      page = 2;
      period = 'This week';
      anchor = null;
    }),
  );

  Widget filterControls() => Column(
    children: [
      TextField(
        controller: searchController,
        decoration: const InputDecoration(
          hintText: 'Search descriptions, activities, clients or tags',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (v) => setState(() => query = v),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 220,
            child: DropdownButton<String>(
              value: activityFilter,
              isExpanded: true,
              hint: const Text('All activities'),
              underline: const SizedBox(),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('All activities'),
                ),
                ...{
                  ...t.activities.map((a) => a.id),
                  ...t.sessions.map((s) => s.activityId),
                }.map(
                  (id) => DropdownMenuItem(
                    value: id,
                    child: Text(
                      t.activityName(id),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => activityFilter = v),
            ),
          ),
          FilterChip(
            label: const Text('Billable only'),
            selected: billableOnly,
            onSelected: (v) => setState(() => billableOnly = v),
          ),
        ],
      ),
    ],
  );

  Widget reports() {
    final (from, to) = range;
    return ReportsView(
      tracker: t,
      sessions: visibleSessions,
      comparisonSessions: filteredSessions,
      from: from,
      to: to,
      controls: dateControls(),
      filters: filterControls(),
      onActivity: (id) => setState(() {
        activityFilter = id;
        page = 1;
      }),
      onExport: () => perform(() => exportCsv(filtered: true)),
    );
  }

  Widget history() {
    final visible = visibleSessions;
    final overlaps = overlappingSessions(t.sessions, t.now);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Your timeline',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: 'Export CSV',
              onPressed: () => perform(() => exportCsv(filtered: true)),
              icon: const Icon(Icons.download_outlined),
            ),
            IconButton(
              tooltip: 'Add session',
              onPressed: () => editSession(),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        dateControls(),
        const SizedBox(height: 12),
        filterControls(),
        const SizedBox(height: 12),
        if (visible.any((s) => overlaps.contains(s.id)))
          notice(
            'Some sessions overlap. Both are preserved and included in totals; edit them if they count the same time.',
            Icons.layers_outlined,
          ),
        if (visible.isEmpty)
          empty(
            'Nothing tracked yet',
            'Start a timer or add a session you forgot to track.',
            Icons.history,
          ),
        ...visible.map(
          (s) => Card(
            child: ListTile(
              onTap: () => editSession(s),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 8,
              ),
              leading: CircleAvatar(
                backgroundColor: Color(
                  t.activity(s.activityId)?.color ?? palette.first,
                ).withValues(alpha: 0.14),
                child: Icon(
                  s.source == 'auto' ? Icons.apps : Icons.timer_outlined,
                  color: Color(
                    t.activity(s.activityId)?.color ?? palette.first,
                  ),
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.activityName(s.activityId),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (overlaps.contains(s.id))
                    const Tooltip(
                      message: 'Overlapping session',
                      child: Icon(Icons.layers_outlined, size: 18),
                    ),
                  const SizedBox(width: 8),
                  Text(formatDuration(s.duration(t.now))),
                ],
              ),
              subtitle: Text(
                '${DateFormat('EEE d MMM, HH:mm').format(s.start.toLocal())} – ${s.end == null
                    ? s.deviceId == t.store.deviceId
                          ? 'running'
                          : 'open on ${s.deviceName}'
                    : DateFormat('HH:mm').format(s.end!.toLocal())}\n${s.deviceName} · ${s.source == 'auto'
                    ? 'automatic'
                    : s.source == 'import'
                    ? 'imported'
                    : 'manual'}${s.billable ? ' · billable' : ''}${s.note.isEmpty ? '' : '\n${s.note}'}${s.tags.isEmpty ? '' : '\n${s.tags.map((tag) => '#$tag').join(' ')}'}',
              ),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    editSession(s);
                  } else if (value == 'delete') {
                    deleteSession(s);
                  } else {
                    perform(() => t.continueSession(s));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text('Edit session'),
                  ),
                  if (t.activity(s.activityId) != null)
                    const PopupMenuItem(
                      value: 'start',
                      child: Text('Continue session'),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete session'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget appRules() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        'Let your apps start the timer',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      const Text(
        'Link a Windows executable to an activity. Manual timers always take priority. Rules stay on this PC.',
      ),
      const SizedBox(height: 16),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Automatic tracking'),
        value: t.automatic,
        subtitle: Text(t.automatic ? 'Ready to track linked apps' : 'Paused'),
        onChanged: (v) => perform(() => t.setAutomatic(v)),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: () => editRule(),
          icon: const Icon(Icons.add),
          label: const Text('Link an app'),
        ),
      ),
      const SizedBox(height: 16),
      if (t.rules.isEmpty)
        empty(
          'Add your first app rule',
          'Choose a running game or browse to its .exe file.',
          Icons.apps,
        ),
      ...t.rules.map(
        (r) => Card(
          child: ListTile(
            onTap: () => editRule(r),
            leading: const Icon(Icons.window_outlined),
            title: Text(t.activityName(r.activityId)),
            subtitle: Text(
              '${r.executable.split(r'\').last}\n${r.mode == 'focused' ? 'While focused' : 'While running'} · ${r.pauseWhenIdle ? 'pause after ${r.idleMinutes}m idle' : 'no idle pause'}',
            ),
            isThreeLine: true,
            trailing: IconButton(
              tooltip: 'Remove app rule',
              onPressed: () => perform(() => t.removeRule(r)),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'If several rules match, the focused app wins. Otherwise the first matching running-app rule wins. Tracking pauses when Windows locks or sleeps.',
      ),
    ],
  );
  Widget settings() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('Keep it simple', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 20),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.cloud_outlined),
                title: Text('Google Drive sync'),
                subtitle: Text(
                  'Your data works offline. Drive merges activities and sessions between your devices.',
                ),
              ),
              if (t.sync.lastSync != null)
                Text(
                  'Last synced ${DateFormat('d MMM, HH:mm').format(t.sync.lastSync!.toLocal())}',
                ),
              if (t.sync.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    t.sync.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: t.syncing
                        ? null
                        : () => perform(() async {
                            if (!t.auth.connected) await t.auth.connect();
                            await t.synchronize();
                            setState(() {});
                          }),
                    icon: const Icon(Icons.sync),
                    label: Text(
                      t.syncing
                          ? 'Syncing…'
                          : t.auth.connected
                          ? 'Sync now'
                          : 'Connect Google Drive',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: googleSetup,
                    child: const Text('Google setup'),
                  ),
                  if (t.auth.connected)
                    TextButton(
                      onPressed: () => perform(() async {
                        await t.auth.disconnect();
                        setState(() {});
                      }),
                      child: const Text('Disconnect'),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Use credentials from the same Google Cloud project on both devices. Sync runs while Sprout is open and every two minutes. It does not require access to your other Drive files.',
              ),
            ],
          ),
        ),
      ),
      if (Platform.isWindows)
        Card(
          child: SwitchListTile(
            title: const Text('Start with Windows'),
            subtitle: const Text(
              'Keep automatic tracking available after signing in.',
            ),
            value: t.startup,
            onChanged: (value) => perform(() => t.setStartup(value)),
          ),
        ),
      if (Platform.isAndroid)
        Card(
          child: SwitchListTile(
            title: const Text('Timer notification'),
            subtitle: const Text(
              'Show the running timer with a Stop shortcut.',
            ),
            value: t.notifications,
            onChanged: (value) => perform(() => t.setNotifications(value)),
          ),
        ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Export all sessions as CSV'),
          onTap: dataAction == null
              ? () => perform(() => dataTask('Exporting sessions…', exportCsv))
              : null,
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.move_to_inbox_outlined),
          title: const Text('Import from Toggl Track'),
          subtitle: const Text(
            'Bring your Detailed report CSV. Re-importing skips duplicates.',
          ),
          onTap: dataAction == null
              ? () =>
                    perform(() => dataTask('Importing your time…', importToggl))
              : null,
        ),
      ),
      const SizedBox(height: 16),
      Card(
        color: const Color(0xFFE9EFE6),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'A little peace of mind',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                t.lastPortableBackup == null
                    ? 'Save a portable backup to keep your garden safe outside this app.'
                    : 'Latest exported snapshot: ${DateFormat.yMMMd().add_jm().format(t.lastPortableBackup!)}',
              ),
              const SizedBox(height: 8),
              Text(
                t.lastRecoveryCopy == null
                    ? 'Automatic recovery copies are created while Sprout is open.'
                    : 'Recovery copy: ${DateFormat.yMMMd().add_jm().format(t.lastRecoveryCopy!)}',
              ),
              const SizedBox(height: 8),
              const Text(
                'Keep a portable copy on another device or in cloud storage. Local recovery copies are lost if you uninstall or clear app data.',
              ),
              if (t.backupError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    t.backupError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (dataAction != null) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(dataAction!),
              ],
            ],
          ),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('Save a portable backup'),
          subtitle: const Text(
            'Verified JSON with your time, activity names, preferences and app rules.',
          ),
          onTap: dataAction == null
              ? () => perform(() => dataTask('Saving your backup…', saveBackup))
              : null,
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.restore_outlined),
          title: const Text('Restore a backup'),
          subtitle: const Text(
            'Add missing records while keeping existing entries.',
          ),
          onTap: dataAction == null
              ? () => perform(
                  () => dataTask('Reviewing your backup…', restoreBackup),
                )
              : null,
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Recovery copies'),
          subtitle: const Text(
            'Automatic copies for 7 days, plus 8 copies before imports, restores and deletions.',
          ),
          onTap: dataAction == null
              ? () => perform(
                  () => dataTask('Opening recovery copies…', recoveryCopies),
                )
              : null,
        ),
      ),
      if (Platform.isAndroid)
        const Card(
          child: ListTile(
            leading: Icon(Icons.widgets_outlined),
            title: Text('Your home-screen garden'),
            subtitle: Text(
              'Long-press your home screen → Widgets → Sprout. Add Timer & activities or Weekly stats.',
            ),
          ),
        ),
      const SizedBox(height: 24),
      Text(
        'This device: ${t.store.deviceName}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 6),
      const Text(
        'Sprout 0.2.1 · Local storage · No subscription',
        style: TextStyle(color: Color(0xFF696D67)),
      ),
    ],
  );
  Widget empty(String title, String subtitle, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: Column(
      children: [
        Icon(icon, size: 44, color: const Color(0xFF567561)),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(subtitle, textAlign: TextAlign.center),
      ],
    ),
  );
  Widget notice(String text, IconData icon, {VoidCallback? onDismiss}) => Card(
    color: const Color(0xFFFFEFCF),
    child: ListTile(
      leading: Icon(icon),
      title: Text(text),
      trailing: onDismiss == null
          ? null
          : IconButton(onPressed: onDismiss, icon: const Icon(Icons.close)),
    ),
  );

  Future<bool> confirm(String title, String message) async =>
      await completedDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> deleteActivity(Activity a) async {
    if (await confirm(
      'Delete ${a.name}?',
      'Its recorded sessions will remain in your history. App rules for this activity will be removed.',
    )) {
      await perform(() => t.deleteActivity(a));
    }
  }

  Future<void> deleteSession(Session s) async {
    if (await confirm(
      'Delete this session?',
      'This deletion will also sync to your other devices.',
    )) {
      await perform(() => t.deleteSession(s));
    }
  }

  Future<void> editActivity([Activity? a]) async {
    final name = TextEditingController(text: a?.name ?? '');
    final client = TextEditingController(text: a?.client ?? '');
    var color = a?.color ?? palette[t.activities.length % palette.length];
    final save = await completedDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(a == null ? 'New activity' : 'Edit activity'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'e.g. Japanese',
                  ),
                  onSubmitted: (text) {
                    if (text.trim().isNotEmpty) Navigator.pop(ctx, true);
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: client,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Client (optional)',
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: palette
                      .map(
                        (c) => IconButton.filledTonal(
                          onPressed: () => setDialog(() => color = c),
                          style: IconButton.styleFrom(
                            backgroundColor: Color(c).withValues(alpha: 0.15),
                          ),
                          icon: Icon(
                            color == c ? Icons.check_circle : Icons.circle,
                            color: Color(c),
                          ),
                          tooltip: 'Activity colour',
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isNotEmpty) Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      await perform(
        () => t.addActivity(name.text, color, id: a?.id, client: client.text),
      );
    }
    name.dispose();
    client.dispose();
  }

  Future<DateTime?> pickDateTime(BuildContext ctx, DateTime initial) async {
    final date = await showDatePicker(
      context: ctx,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !ctx.mounted) return null;
    final time = await showTimePicker(
      context: ctx,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    return time == null
        ? null
        : DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> editSession([Session? s]) async {
    if (t.activities.isEmpty && s == null) {
      await editActivity();
      if (t.activities.isEmpty) return;
    }
    if (!mounted) return;
    var activityId = s?.activityId ?? t.activities.first.id;
    var start =
        s?.start.toLocal() ?? DateTime.now().subtract(const Duration(hours: 1));
    var end = s?.end?.toLocal() ?? DateTime.now();
    final note = TextEditingController(text: s?.note ?? '');
    final tags = TextEditingController(text: s?.tags.join(', ') ?? '');
    var billable = s?.billable ?? false;
    var keepRunning = s?.isRunning ?? false;
    String? validation;
    final ids = {...t.activities.map((a) => a.id), activityId};
    final saved = await completedDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(s == null ? 'Add session' : 'Edit session'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: activityId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Activity'),
                    items: ids
                        .map(
                          (id) => DropdownMenuItem(
                            value: id,
                            child: Text(t.activityName(id)),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => activityId = v!,
                  ),
                  const SizedBox(height: 16),
                  if (s?.isRunning == true)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Keep timer running'),
                      value: keepRunning,
                      onChanged: (v) => setDialog(() => keepRunning = v),
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start'),
                    subtitle: Text(
                      DateFormat('d MMM yyyy, HH:mm').format(start),
                    ),
                    trailing: const Icon(Icons.edit_calendar_outlined),
                    onTap: () async {
                      final value = await pickDateTime(ctx, start);
                      if (value != null) setDialog(() => start = value);
                    },
                  ),
                  if (!keepRunning)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(s?.isRunning == true ? 'Stop at' : 'End'),
                      subtitle: Text(
                        DateFormat('d MMM yyyy, HH:mm').format(end),
                      ),
                      trailing: const Icon(Icons.edit_calendar_outlined),
                      onTap: () async {
                        final value = await pickDateTime(ctx, end);
                        if (value != null) setDialog(() => end = value);
                      },
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: tags,
                    decoration: const InputDecoration(
                      labelText: 'Tags',
                      hintText: 'focus, study',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Billable'),
                    value: billable,
                    onChanged: (v) => setDialog(() => billable = v),
                  ),
                  if (validation != null)
                    Text(
                      validation!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final invalidEnd =
                    !keepRunning &&
                    (end.isBefore(start) ||
                        end.isAfter(
                          DateTime.now().add(const Duration(minutes: 1)),
                        ));
                if (start.isAfter(DateTime.now()) || invalidEnd) {
                  setDialog(
                    () => validation =
                        'Choose an end after the start and no later than now.',
                  );
                } else {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await perform(
        () => t.saveSession(
          Session(
            id: s?.id ?? const Uuid().v4(),
            activityId: activityId,
            deviceId: s?.deviceId ?? t.store.deviceId,
            deviceName: s?.deviceName ?? t.store.deviceName,
            start: start,
            end: keepRunning ? null : end,
            lastSeen: keepRunning ? DateTime.now() : end,
            note: note.text.trim(),
            tags: parseTags(tags.text),
            billable: billable,
            source: s?.source ?? 'manual',
            executable: s?.executable ?? '',
          ),
        ),
      );
    }
    note.dispose();
    tags.dispose();
  }

  Future<void> editRule([AppRule? r]) async {
    if (t.activities.isEmpty) {
      await editActivity();
      if (t.activities.isEmpty) return;
    }
    await perform(t.refreshProcesses);
    if (!mounted) return;
    var activityId = r?.activityId ?? t.activities.first.id;
    final executable = TextEditingController(text: r?.executable ?? '');
    var mode = r?.mode ?? 'focused';
    var idle = r?.pauseWhenIdle ?? false;
    var idleMinutes = r?.idleMinutes ?? 5;
    var enabled = r?.enabled ?? true;
    final saved = await completedDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(r == null ? 'Link an app' : 'Edit app rule'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: activityId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Activity'),
                    items: t.activities
                        .map(
                          (a) => DropdownMenuItem(
                            value: a.id,
                            child: Text(a.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => activityId = v!,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: executable,
                    decoration: const InputDecoration(
                      labelText: 'Executable path or name',
                      hintText: 'e.g. bg3.exe',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final file = await openFile(
                            acceptedTypeGroups: [
                              const XTypeGroup(
                                label: 'Windows application',
                                extensions: ['exe'],
                              ),
                            ],
                          );
                          if (file != null && ctx.mounted) {
                            setDialog(() => executable.text = file.path);
                          }
                        },
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('Browse'),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final options =
                              {
                                for (final p in t.processes)
                                  p['path'] as String: p,
                              }.values.toList()..sort(
                                (a, b) => (a['name'] as String)
                                    .toLowerCase()
                                    .compareTo(
                                      (b['name'] as String).toLowerCase(),
                                    ),
                              );
                          final picked = await showDialog<String>(
                            context: ctx,
                            builder: (pickCtx) => AlertDialog(
                              title: const Text('Running apps'),
                              content: SizedBox(
                                width: 480,
                                height: 360,
                                child: ListView(
                                  children: options
                                      .map(
                                        (p) => ListTile(
                                          title: Text(p['name'] as String),
                                          subtitle: Text(p['path'] as String),
                                          onTap: () => Navigator.pop(
                                            pickCtx,
                                            p['path'] as String,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ),
                            ),
                          );
                          if (picked != null && ctx.mounted) {
                            setDialog(() => executable.text = picked);
                          }
                        },
                        icon: const Icon(Icons.apps),
                        label: const Text('Choose running app'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: 'Track'),
                    items: const [
                      DropdownMenuItem(
                        value: 'focused',
                        child: Text('While focused'),
                      ),
                      DropdownMenuItem(
                        value: 'running',
                        child: Text('While running'),
                      ),
                    ],
                    onChanged: (v) => setDialog(() => mode = v!),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Pause when idle'),
                    subtitle: const Text(
                      'Keep off for games, reading, or watching video.',
                    ),
                    value: idle,
                    onChanged: (v) => setDialog(() => idle = v),
                  ),
                  if (idle)
                    DropdownButtonFormField<int>(
                      initialValue: idleMinutes,
                      decoration: const InputDecoration(
                        labelText: 'Idle threshold',
                      ),
                      items: [1, 2, 5, 10, 15, 30]
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text('$v minutes'),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => idleMinutes = v!,
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enabled'),
                    value: enabled,
                    onChanged: (v) => setDialog(() => enabled = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (executable.text.trim().isNotEmpty) Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await perform(
        () => t.saveRule(
          AppRule(
            id: r?.id ?? const Uuid().v4(),
            activityId: activityId,
            executable: executable.text.trim(),
            mode: mode,
            pauseWhenIdle: idle,
            idleMinutes: idleMinutes,
            enabled: enabled,
          ),
        ),
      );
    }
    executable.dispose();
  }

  Future<bool> saveDocument(
    String name,
    String content,
    String mime,
    String extension,
  ) async {
    if (Platform.isAndroid) {
      return await const MethodChannel(
            'dev.beesan.timebud/platform',
          ).invokeMethod<bool>('exportDocument', {
            'name': name,
            'content': content,
            'mimeType': mime,
          }) ??
          false;
    } else {
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [
          XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
        ],
      );
      if (location != null) {
        await writeVerifiedDocument(
          File(location.path),
          content,
          backup: extension == 'json',
        );
        return true;
      }
      return false;
    }
  }

  Future<void> exportCsv({bool filtered = false}) async {
    final saved = await saveDocument(
      'sprout-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv',
      exportSessionsCsv(
        filtered ? visibleSessions : t.sessions,
        t.activityName,
        t.now,
      ),
      'text/csv',
      'csv',
    );
    if (saved && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('CSV saved and verified.')));
    }
  }

  Future<void> saveBackup() async {
    await exportBackup(await t.backup());
  }

  Future<void> exportBackup(String content) async {
    final data = decodeBackup(content);
    final saved = await saveDocument(
      'sprout-backup-${DateFormat('yyyy-MM-dd-HHmmss').format(data.exportedAt)}.json',
      content,
      'application/json',
      'json',
    );
    if (!saved) return;
    await t.recordPortableBackup(data.exportedAt);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Backup saved and verified: ${data.sessions.length} entries, ${data.activities.length} activities.',
          ),
        ),
      );
    }
  }

  Future<String> readImportFile(XFile file) async {
    if (await file.length() > maxPortableBytes) {
      throw const FormatException('Choose a file smaller than 32 MB.');
    }
    return file.readAsString();
  }

  Future<bool> approveImport(String title, String message, String verb) async =>
      await completedDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(verb),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> importToggl() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Toggl CSV', extensions: ['csv']),
      ],
    );
    if (file == null) return;
    final content = await readImportFile(file);
    final plan = planTogglImport(
      content,
      activities: t.activities,
      sessions: t.sessions,
      deviceId: t.store.deviceId,
      deviceName: t.store.deviceName,
    );
    if (!mounted ||
        !await approveImport(
          'Bring your time into Sprout',
          '${plan.sessions.length} entries and ${plan.activities.length} activities to add. '
              '${plan.skipped} duplicate entries will be skipped.\n\n'
              'Dates use this device’s timezone. Match it to your Toggl profile before importing. Existing entries stay as they are.',
          'Import',
        )) {
      return;
    }
    final result = await t.importToggl(content);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${result.imported} entries; skipped ${result.skipped} duplicates.',
          ),
        ),
      );
    }
  }

  Future<void> restoreBackup() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Sprout backup', extensions: ['json']),
      ],
    );
    if (file == null) return;
    await restoreContent(await readImportFile(file), file.name);
  }

  Future<void> restoreContent(String content, String fileName) async {
    final data = decodeBackup(content);
    final snapshot = await t.store.snapshot();
    if (!mounted) return;
    final options = await completedDialog<RestoreOptions>(
      context: context,
      builder: (_) => RestorePreviewDialog(
        backup: data,
        snapshot: snapshot,
        fileName: fileName,
      ),
    );
    if (options == null || !mounted) return;
    final result = await t.restore(content, options: options);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restored ${result.imported} entries and ${result.activities} activities; kept ${result.skipped} existing or deleted entries.',
          ),
        ),
      );
    }
  }

  Future<void> recoveryCopies() async {
    final vault = t.backups;
    if (vault == null) return;
    final copies = await vault.list();
    if (!mounted) return;
    final selected = await completedDialog<(String, LocalBackup)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recovery copies'),
        content: SizedBox(
          width: 500,
          height: 420,
          child: copies.isEmpty
              ? const Center(
                  child: Text(
                    'Your first recovery copy will appear here while Sprout is open.',
                  ),
                )
              : ListView(
                  children: copies
                      .map(
                        (copy) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
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
                                  DateFormat.yMMMd().add_jm().format(
                                    copy.data!.exportedAt,
                                  ),
                                ),
                                Text(
                                  '${copy.data!.sessions.length} entries · ${copy.data!.activities.length} activities',
                                ),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () =>
                                          Navigator.pop(ctx, ('restore', copy)),
                                      icon: const Icon(Icons.restore, size: 18),
                                      label: const Text('Restore'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          Navigator.pop(ctx, ('export', copy)),
                                      icon: const Icon(
                                        Icons.save_alt,
                                        size: 18,
                                      ),
                                      label: const Text('Export'),
                                    ),
                                  ],
                                ),
                              ] else
                                Text(copy.error!),
                              const Divider(),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final content = await readPortableFile(selected.$2.file);
    if (selected.$1 == 'export') {
      await exportBackup(content);
    } else {
      await restoreContent(content, selected.$2.label);
    }
  }

  Future<void> googleSetup() async {
    if (Platform.isWindows) {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Google desktop OAuth credentials',
            extensions: ['json'],
          ),
        ],
      );
      if (file != null) {
        await perform(() async {
          await t.auth.configureDesktop(
            jsonDecode(await file.readAsString()) as Json,
          );
          await t.store.setSetting('synced', '-1');
          setState(() {});
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Google credentials imported. Connect Google Drive to sync.',
                ),
              ),
            );
          }
        });
      }
      return;
    }
    final fingerprint = await t.bridge.signingFingerprint();
    if (!mounted) return;
    final client = TextEditingController();
    final save = await completedDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Google setup'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'In the same Google Cloud project used on Windows, enable the Drive API. Create an Android OAuth client with this package and signing fingerprint, then a Web client.',
                ),
                const SizedBox(height: 16),
                const SelectableText('Package: dev.beesan.timebud'),
                const SizedBox(height: 8),
                SelectableText('SHA-1: $fingerprint'),
                const SizedBox(height: 16),
                TextField(
                  controller: client,
                  decoration: const InputDecoration(
                    labelText: 'Web client ID',
                    hintText: '…apps.googleusercontent.com',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Full instructions are in the repository README. Restart after changing previously initialized credentials.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (save == true) {
      await perform(() async {
        await t.auth.configureAndroid(client.text);
        setState(() {});
      });
    }
    client.dispose();
  }
}

package dev.beesan.timebud

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

class TimerWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { SproutWidgets.timer(context, manager, it) }
    }
}

class StatsWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { SproutWidgets.stats(context, manager, it) }
    }
}

object SproutWidgets {
    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        manager.getAppWidgetIds(ComponentName(context, TimerWidget::class.java))
            .forEach { timer(context, manager, it) }
        manager.getAppWidgetIds(ComponentName(context, StatsWidget::class.java))
            .forEach { stats(context, manager, it) }
    }

    private fun action(context: Context, code: Int, action: String? = null,
        activityId: String = "", sessionId: String = ""): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            this.action = action ?: Intent.ACTION_MAIN
            data = Uri.parse("sprout://widget/$code/$activityId/$sessionId")
            putExtra("activityId", activityId)
            putExtra("sessionId", sessionId)
        }
        return PendingIntent.getActivity(context, code, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun timer(context: Context, manager: AppWidgetManager, id: Int) {
        val prefs = context.getSharedPreferences("sprout_widgets", Context.MODE_PRIVATE)
        val running = prefs.getBoolean("running", false)
        val views = RemoteViews(context.packageName, R.layout.widget_timer)
        views.setTextViewText(R.id.widget_activity, if (running) prefs.getString("name", "Tracking") else "Ready to grow")
        views.setOnClickPendingIntent(R.id.widget_root, action(context, id * 10))
        val base = SystemClock.elapsedRealtime() - (System.currentTimeMillis() - prefs.getLong("start", System.currentTimeMillis()))
        views.setChronometer(R.id.widget_clock, if (running) base else SystemClock.elapsedRealtime(), "%s", running)
        views.setViewVisibility(R.id.widget_stop, if (running) View.VISIBLE else View.GONE)
        views.setOnClickPendingIntent(R.id.widget_stop, action(context, id * 10 + 1,
            MainActivity.STOP_ACTION, sessionId = prefs.getString("sessionId", "") ?: ""))
        val activities = runCatching { JSONArray(prefs.getString("activities", "[]")) }.getOrDefault(JSONArray())
        val buttons = intArrayOf(R.id.widget_a1, R.id.widget_a2, R.id.widget_a3, R.id.widget_a4)
        buttons.forEachIndexed { index, button ->
            val activity = activities.optJSONObject(index)
            views.setViewVisibility(button, if (activity == null) View.GONE else View.VISIBLE)
            if (activity != null) {
                views.setTextViewText(button, activity.optString("name", "Activity"))
                views.setOnClickPendingIntent(button, action(context, id * 10 + 2 + index,
                    MainActivity.START_ACTION, activity.optString("id")))
            }
        }
        views.setViewVisibility(R.id.widget_hint, if (activities.length() == 0) View.VISIBLE else View.GONE)
        manager.updateAppWidget(id, views)
    }

    fun stats(context: Context, manager: AppWidgetManager, id: Int) {
        val prefs = context.getSharedPreferences("sprout_widgets", Context.MODE_PRIVATE)
        val stats = runCatching { JSONObject(prefs.getString("stats", "{}")) }.getOrDefault(JSONObject())
        val views = RemoteViews(context.packageName, R.layout.widget_stats)
        views.setTextViewText(R.id.stats_today, stats.optString("today", "0h 00m"))
        views.setTextViewText(R.id.stats_week, stats.optString("week", "0h 00m"))
        views.setTextViewText(R.id.stats_sessions, "${stats.optInt("sessions")} sessions this week")
        val updated = stats.optLong("updatedAt", 0)
        views.setTextViewText(R.id.stats_updated, if (updated == 0L) "Open Sprout to get started" else
            "Updated ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(updated))}")
        views.setOnClickPendingIntent(R.id.widget_root, action(context, id * 10 + 8))
        manager.updateAppWidget(id, views)
    }
}

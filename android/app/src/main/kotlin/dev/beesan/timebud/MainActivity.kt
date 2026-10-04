package dev.beesan.timebud

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingAction: Map<String, Any?>? = null
    private var pendingExport: String? = null
    private var exportResult: MethodChannel.Result? = null
    private var timerName = ""
    private var timerStart = 0L
    private var timerRunning = false
    private var timerSessionId = ""
    private var timerNotifications = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        captureAction(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.beesan.timebud/platform")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateTimer" -> {
                    timerName = call.argument<String>("name") ?: ""
                    timerStart = call.argument<Number>("start")?.toLong() ?: 0L
                    timerRunning = call.argument<Boolean>("running") ?: false
                    timerSessionId = call.argument<String>("sessionId") ?: ""
                    val stats = call.argument<Map<String, Any>>("stats") ?: emptyMap()
                    timerNotifications = stats["notifications"] != false
                    val activities = call.argument<List<Map<String, Any>>>("activities") ?: emptyList()
                    getSharedPreferences("sprout_widgets", MODE_PRIVATE).edit()
                        .putString("name", timerName).putLong("start", timerStart)
                        .putBoolean("running", timerRunning).putString("sessionId", timerSessionId)
                        .putString("activities", org.json.JSONArray(activities).toString())
                        .putString("stats", org.json.JSONObject(stats).toString()).apply()
                    SproutWidgets.updateAll(this)
                    updateNotification()
                    result.success(null)
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
                    }
                    result.success(null)
                }
                "takePendingAction" -> {
                    val action = pendingAction
                    pendingAction = null
                    intent?.action = Intent.ACTION_MAIN
                    result.success(action)
                }
                "signingFingerprint" -> {
                    try {
                        val signatures = if (Build.VERSION.SDK_INT >= 28) {
                            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo?.apkContentsSigners
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures
                        }
                        val certificate = signatures?.firstOrNull()?.toByteArray()
                        val fingerprint = certificate?.let { MessageDigest.getInstance("SHA-1").digest(it).joinToString(":") { byte -> "%02X".format(byte.toInt() and 0xff) } } ?: "Unavailable"
                        result.success(fingerprint)
                    } catch (error: Exception) {
                        result.error("fingerprint", "Could not read signing fingerprint", null)
                    }
                }
                "exportCsv", "exportDocument" -> {
                    if (exportResult != null) {
                        result.error("export", "An export is already open", null)
                    } else {
                        pendingExport = call.argument<String>("content") ?: ""
                        exportResult = result
                        val picker = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = call.argument<String>("mimeType") ?: "text/csv"
                            putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "sprout.csv")
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(picker, EXPORT_REQUEST)
                        } catch (error: Exception) {
                            pendingExport = null
                            exportResult = null
                            result.error("export", "Could not open the save dialog", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureAction(intent)
        if (pendingAction != null) channel?.invokeMethod("pendingAction", null)
    }

    private fun captureAction(actionIntent: Intent?) {
        val target = actionIntent ?: return
        val action = when (target.action) {
            STOP_ACTION -> "stop"
            START_ACTION -> "start"
            else -> return
        }
        pendingAction = mapOf("action" to action,
            "activityId" to target.getStringExtra("activityId"),
            "sessionId" to target.getStringExtra("sessionId"),
            "at" to System.currentTimeMillis())
    }

    private fun updateNotification() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (!timerRunning || !timerNotifications) {
            manager.cancel(TIMER_NOTIFICATION)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel("timer", "Running timer", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Your active Sprout timer"
                setSound(null, null)
            })
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java).apply {
            action = STOP_ACTION
            putExtra("sessionId", timerSessionId)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "timer") else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_timer)
            .setContentTitle(timerName)
            .setContentText("Sprout timer is running")
            .setWhen(timerStart)
            .setUsesChronometer(true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
        manager.notify(TIMER_NOTIFICATION, notification)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_REQUEST) updateNotification()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT_REQUEST) return
        val result = exportResult ?: return
        if (resultCode != RESULT_OK) {
            pendingExport = null
            exportResult = null
            result.success(false)
            return
        }
        val uri = data?.data
        val content = pendingExport
        if (uri == null || content == null) {
            pendingExport = null
            exportResult = null
            result.error("export", "No save destination was selected", null)
            return
        }
        pendingExport = null
        // Provider I/O can be slow (especially cloud documents). Keep it off
        // the UI thread, and report success only after reading the bytes back.
        Thread {
            try {
                val bytes = content.toByteArray(Charsets.UTF_8)
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("Could not open destination")
                stream.use { it.write(bytes); it.flush() }
                val expected = MessageDigest.getInstance("SHA-256").digest(bytes)
                val actual = MessageDigest.getInstance("SHA-256")
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("Could not verify the saved document")
                var total = 0L
                input.use {
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = it.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > bytes.size) throw IllegalStateException("Saved document verification failed")
                        actual.update(buffer, 0, count)
                    }
                }
                if (total != bytes.size.toLong() || !MessageDigest.isEqual(expected, actual.digest())) {
                    throw IllegalStateException("Saved document verification failed")
                }
                runOnUiThread { exportResult = null; result.success(true) }
            } catch (error: Exception) {
                runOnUiThread {
                    exportResult = null
                    result.error("export", "Could not save and verify the document. Choose another location. ${error.message}", null)
                }
            }
        }.start()
    }

    companion object {
        const val STOP_ACTION = "dev.beesan.timebud.STOP"
        const val START_ACTION = "dev.beesan.timebud.START"
        private const val TIMER_NOTIFICATION = 1001
        private const val NOTIFICATION_REQUEST = 1002
        private const val EXPORT_REQUEST = 1003
    }
}

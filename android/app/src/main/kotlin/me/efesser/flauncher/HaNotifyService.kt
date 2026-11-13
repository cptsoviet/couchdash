/*
 * CouchDash: notifications from Home Assistant, drawn over any app.
 *
 * Registers once as an HA mobile_app device (same API as the Companion app) -> HA gets notify.mobile_app_<name>.
 * Keeps its own WebSocket and subscribes to mobile_app/push_notification_channel, so delivery works while
 * another app is in front. Runs as a foreground service, independent of the Flutter UI.
 *
 * Config: the same ha.json the launcher uses (getExternalFilesDir/ha.json). Notifications are OFF unless it has
 * "notifications": true; optional "device_name" (default "Living Room TV"), "offline_max_age_minutes" (default 10).
 * Registration is cached in filesDir/ha_registration.json (delete it to re-register).
 * Credentials: "token" (long-lived), or "client_id" + "refresh_token" from the QR setup flow; the 30-minute access
 * token is then refreshed here in memory every 20 minutes (the Flutter side refreshes its own; nothing is written back).
 */
package me.efesser.flauncher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit

private const val TAG = "HaNotify"
private const val REFRESH_MS = 20 * 60_000L
private const val CHANNEL_ID = "ha_notify_service"

class HaNotifyService : Service() {
    companion object {
        const val ACTION_TEST = "app.couchdash.launcher.TEST_NOTIFY"

        fun start(context: Context) {
            val intent = Intent(context, HaNotifyService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder().pingInterval(30, TimeUnit.SECONDS).build()
    private val json = "application/json".toMediaType()

    private var baseUrl: String? = null
    @Volatile private var token: String? = null
    private var clientId: String? = null
    private var refreshToken: String? = null
    private var webhookId: String? = null
    private var maxAgeMs = 10 * 60_000L
    private var socket: WebSocket? = null
    private var nextId = 1
    private var backoffMs = 2_000L
    private var stopped = false

    lateinit var overlay: HaOverlay
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val pending = ArrayList<Pair<Long, JSONObject>>() // arrived while the screen was off

    private val screenOn = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val now = System.currentTimeMillis()
            val recent = pending.filter { now - it.first <= maxAgeMs }.map { it.second }
            pending.clear()
            recent.forEach { show(it) }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startAsForeground()
        overlay = HaOverlay(this) { action, message -> sendAction(action, message) }
        tts = TextToSpeech(this) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) tts?.language = Locale.US
        }
        registerReceiver(screenOn, IntentFilter(Intent.ACTION_SCREEN_ON))
        Thread { setUp() }.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_TEST) {
            intent.getStringExtra("json")?.let { runCatching { JSONObject(it) }.getOrNull() }?.let { main.post { handle(it) } }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopped = true
        main.removeCallbacksAndMessages(null)
        socket?.close(1000, null)
        unregisterReceiver(screenOn)
        tts?.shutdown()
        overlay.clearAll()
        super.onDestroy()
    }

    private fun startAsForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Home Assistant link", NotificationManager.IMPORTANCE_MIN))
        }
        val n = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this))
            .setContentTitle("Home Assistant notifications")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(1, n)
    }

    // ---------- setup: config, registration ----------
    private fun setUp() {
        val config = runCatching { JSONObject(File(getExternalFilesDir(null), "ha.json").readText()) }.getOrNull()
        if (config == null || !config.optBoolean("notifications", false)) {
            Log.i(TAG, "notifications disabled (no ha.json or \"notifications\": true missing)")
            return
        }
        baseUrl = config.getString("url").trimEnd('/')
        refreshToken = config.optString("refresh_token").ifEmpty { null }
        clientId = config.optString("client_id").ifEmpty { null }
        if (refreshToken != null && clientId != null) {
            if (!refreshAccessToken()) {
                main.postDelayed({ Thread { setUp() }.start() }, 60_000)
                return
            }
            main.postDelayed(refreshLoop, REFRESH_MS)
        } else {
            token = config.getString("token")
        }
        maxAgeMs = config.optLong("offline_max_age_minutes", 10) * 60_000L
        val regFile = File(filesDir, "ha_registration.json")
        webhookId = runCatching { JSONObject(regFile.readText()).getString("webhook_id") }.getOrNull()
        if (webhookId == null) {
            webhookId = register(config.optString("device_name", "Living Room TV"))?.also {
                regFile.writeText(JSONObject().put("webhook_id", it).toString())
            }
        }
        if (webhookId == null) {
            Log.w(TAG, "registration failed; retrying in 60 s")
            main.postDelayed({ Thread { setUp() }.start() }, 60_000)
            return
        }
        main.post { connect() }
    }

    private val refreshLoop: Runnable = object : Runnable {
        override fun run() {
            if (stopped) return
            Thread { refreshAccessToken() }.start() // on failure the old token still works until it expires; retry next round
            main.postDelayed(this, REFRESH_MS)
        }
    }

    /** OAuth refresh_token grant; HA access tokens last 30 minutes. */
    private fun refreshAccessToken(): Boolean = runCatching {
        val form = FormBody.Builder()
            .add("grant_type", "refresh_token")
            .add("refresh_token", refreshToken!!)
            .add("client_id", clientId!!)
            .build()
        http.newCall(Request.Builder().url("$baseUrl/auth/token").post(form).build()).execute().use { r ->
            if (!r.isSuccessful) error("HTTP ${r.code}${if (r.code == 400) " (login revoked? set up again)" else ""}")
            token = JSONObject(r.body!!.string()).getString("access_token")
        }
        true
    }.onFailure { Log.w(TAG, "token refresh: $it") }.getOrDefault(false)

    private fun register(deviceName: String): String? {
        val deviceId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: UUID.randomUUID().toString()
        val body = JSONObject()
            .put("device_id", "couchdash-$deviceId")
            .put("app_id", "app.couchdash.launcher")
            .put("app_name", "CouchDash")
            .put("app_version", packageManager.getPackageInfo(packageName, 0).versionName ?: "1")
            .put("device_name", deviceName)
            .put("manufacturer", Build.MANUFACTURER)
            .put("model", Build.MODEL)
            .put("os_name", "Android")
            .put("os_version", Build.VERSION.RELEASE)
            .put("supports_encryption", false)
            .put("app_data", JSONObject().put("push_websocket_channel", true))
        return runCatching {
            http.newCall(
                Request.Builder().url("$baseUrl/api/mobile_app/registrations")
                    .header("Authorization", "Bearer $token")
                    .post(body.toString().toRequestBody(json)).build()
            ).execute().use { r ->
                if (!r.isSuccessful) error("HTTP ${r.code}")
                JSONObject(r.body!!.string()).getString("webhook_id")
            }
        }.onFailure { Log.w(TAG, "register: $it") }.getOrNull()
    }

    // ---------- WebSocket push channel ----------
    private fun connect() {
        if (stopped) return
        val wsUrl = baseUrl!!.replaceFirst("http", "ws") + "/api/websocket"
        socket = http.newWebSocket(Request.Builder().url(wsUrl).build(), object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                val m = JSONObject(text)
                when (m.optString("type")) {
                    "auth_required" -> webSocket.send(JSONObject().put("type", "auth").put("access_token", token).toString())
                    "auth_ok" -> {
                        backoffMs = 2_000L
                        webSocket.send(JSONObject().put("id", nextId++).put("type", "mobile_app/push_notification_channel")
                            .put("webhook_id", webhookId).put("support_confirm", true).toString())
                    }
                    "event" -> {
                        val n = m.optJSONObject("event") ?: return
                        n.optString("hass_confirm_id").takeIf { it.isNotEmpty() }?.let {
                            webSocket.send(JSONObject().put("id", nextId++).put("type", "mobile_app/push_notification_confirm")
                                .put("webhook_id", webhookId).put("confirm_id", it).toString())
                        }
                        main.post { handle(n) }
                    }
                    "result" -> if (!m.optBoolean("success", true)) Log.w(TAG, "HA error: ${m.opt("error")}")
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = retry()
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = retry()
        })
    }

    private fun retry() {
        if (stopped) return
        main.postDelayed({ connect() }, backoffMs)
        backoffMs = (backoffMs * 2).coerceAtMost(60_000L)
    }

    // ---------- incoming notifications ----------
    private fun handle(n: JSONObject) {
        val data = n.optJSONObject("data") ?: JSONObject()
        if (n.optString("message") == "clear_notification") {
            overlay.remove(data.optString("tag"))
            return
        }
        val power = getSystemService(PowerManager::class.java)
        if (!power.isInteractive) {
            pending.add(System.currentTimeMillis() to n)
            return
        }
        show(n)
    }

    private fun show(n: JSONObject) {
        val data = n.optJSONObject("data") ?: JSONObject()
        overlay.show(n, baseUrl, token)
        val text = data.optString("tts_text").ifEmpty {
            if (data.optBoolean("tts", false)) listOf(n.optString("title"), n.optString("message")).filter { it.isNotBlank() }.joinToString(". ") else ""
        }
        if (text.isNotBlank()) {
            speak(text)
            if (data.optString("priority") == "critical") repeatCritical(data.optString("tag"), text)
        }
    }

    private fun repeatCritical(tag: String, text: String) {
        main.postDelayed({
            if (overlay.isShowing(tag)) {
                speak(text)
                repeatCritical(tag, text)
            }
        }, 30_000)
    }

    // ---------- speech, ducking whatever is playing ----------
    private fun speak(text: String) {
        if (!ttsReady) return
        val audio = getSystemService(AudioManager::class.java)
        val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        val focus = if (Build.VERSION.SDK_INT >= 26)
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attrs).build() else null
        if (focus != null) audio.requestAudioFocus(focus)
        tts?.setAudioAttributes(attrs)
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onDone(id: String?) { if (focus != null) audio.abandonAudioFocusRequest(focus) }
            @Deprecated("") override fun onError(id: String?) { if (focus != null) audio.abandonAudioFocusRequest(focus) }
        })
        tts?.speak(text, TextToSpeech.QUEUE_ADD, null, UUID.randomUUID().toString())
    }

    // ---------- button presses back to HA (same event as phone notifications) ----------
    private fun sendAction(action: String, n: JSONObject) {
        val id = webhookId ?: return
        val eventData = JSONObject().put("action", action)
        n.optJSONObject("data")?.optString("tag")?.takeIf { it.isNotEmpty() }?.let { eventData.put("tag", it) }
        n.optString("message").takeIf { it.isNotEmpty() }?.let { eventData.put("message", it) }
        n.optString("title").takeIf { it.isNotEmpty() }?.let { eventData.put("title", it) }
        val body = JSONObject().put("type", "fire_event")
            .put("data", JSONObject().put("event_type", "mobile_app_notification_action").put("event_data", eventData))
        Thread {
            runCatching {
                http.newCall(Request.Builder().url("$baseUrl/api/webhook/$id").post(body.toString().toRequestBody(json)).build())
                    .execute().close()
            }.onFailure { Log.w(TAG, "action: $it") }
        }.start()
    }
}

/** Starts the notification service after boot (the launcher also starts it whenever it opens). */
class HaBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) HaNotifyService.start(context)
    }
}

/**
 * Local test hook, protected by android.permission.DUMP so only adb shell/system can use it:
 * adb shell am broadcast -a app.couchdash.launcher.TEST_NOTIFY -n app.couchdash.launcher/me.efesser.flauncher.HaTestReceiver --es json '{"title":"Hi","message":"Test"}'
 */
class HaTestReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val i = Intent(context, HaNotifyService::class.java).setAction(HaNotifyService.ACTION_TEST)
            .putExtra("json", intent.getStringExtra("json"))
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
    }
}

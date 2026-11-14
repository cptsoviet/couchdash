/*
 * CouchDash: the native side's link to Home Assistant, shared by the notification service and the remote-button
 * service: ha.json, the access token, and the mobile_app registration (webhook).
 *
 * Credentials: "token" (long-lived), or "client_id" + "refresh_token" from the QR setup flow; the 30-minute access
 * token is refreshed in memory when it has less than 12 minutes left (the Flutter side refreshes its own; nothing is
 * written back). Registration is cached in filesDir/ha_registration.json (delete it to re-register).
 */
package me.efesser.flauncher

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.util.UUID

private const val TAG = "HaLink"
private const val DEFAULT_DEVICE_NAME = "Living Room TV"

class HaLink private constructor(private val context: Context, val config: JSONObject, private val http: OkHttpClient) {
    companion object {
        private val json = "application/json".toMediaType()
        private val registrationLock = Any() // both services may register at once on a fresh install

        fun readConfig(context: Context): JSONObject? =
            runCatching { JSONObject(File(context.getExternalFilesDir(null), "ha.json").readText()) }.getOrNull()

        /** null when the launcher isn't set up (no ha.json or no url). */
        fun load(context: Context, http: OkHttpClient): HaLink? {
            val config = readConfig(context) ?: return null
            if (config.optString("url").isEmpty()) return null
            return HaLink(context.applicationContext, config, http)
        }
    }

    val baseUrl: String = config.getString("url").trimEnd('/')
    val deviceName: String = config.optString("device_name").ifBlank { DEFAULT_DEVICE_NAME }
    private val refreshToken = config.optString("refresh_token").ifEmpty { null }
    private val clientId = config.optString("client_id").ifEmpty { null }
    private val longLived = if (refreshToken != null && clientId != null) null else config.optString("token").ifEmpty { null }

    @Volatile private var accessToken: String? = null
    @Volatile private var expiresAt = 0L

    /** The last token we have, for code that can't block (overlay image headers). */
    val cachedToken: String? get() = longLived ?: accessToken

    /** A valid access token (blocking network call when it needs a refresh); null if HA can't be reached. */
    fun token(): String? {
        if (longLived != null) return longLived
        if (accessToken != null && System.currentTimeMillis() < expiresAt - 12 * 60_000L) return accessToken
        synchronized(this) {
            if (accessToken != null && System.currentTimeMillis() < expiresAt - 12 * 60_000L) return accessToken
            return runCatching {
                val form = FormBody.Builder()
                    .add("grant_type", "refresh_token")
                    .add("refresh_token", refreshToken!!)
                    .add("client_id", clientId!!)
                    .build()
                http.newCall(Request.Builder().url("$baseUrl/auth/token").post(form).build()).execute().use { r ->
                    if (!r.isSuccessful) error("HTTP ${r.code}${if (r.code == 400) " (login revoked? set up again)" else ""}")
                    val body = JSONObject(r.body!!.string())
                    accessToken = body.getString("access_token")
                    expiresAt = System.currentTimeMillis() + body.optLong("expires_in", 1800) * 1000
                    accessToken
                }
            }.onFailure { Log.w(TAG, "token refresh: $it") }.getOrNull()
        }
    }

    /** POST with the access token; true on HTTP 2xx. */
    fun postAuthorized(path: String, body: JSONObject): Boolean = runCatching {
        val t = token() ?: error("no token")
        http.newCall(Request.Builder().url("$baseUrl$path").header("Authorization", "Bearer $t")
            .post(body.toString().toRequestBody(json)).build()).execute().use { r ->
            if (!r.isSuccessful) error("HTTP ${r.code}")
        }
        true
    }.onFailure { Log.w(TAG, "POST $path: $it") }.getOrDefault(false)

    /** POST to the mobile_app webhook (no auth header: the webhook id is the secret). */
    fun postWebhook(webhookId: String, body: JSONObject): Boolean = runCatching {
        http.newCall(Request.Builder().url("$baseUrl/api/webhook/$webhookId").post(body.toString().toRequestBody(json)).build())
            .execute().use { r -> if (!r.isSuccessful) error("HTTP ${r.code}") }
        true
    }.onFailure { Log.w(TAG, "webhook: $it") }.getOrDefault(false)

    // ---------- mobile_app registration ----------

    /**
     * The webhook id of this TV's mobile_app registration. Registers when there is none yet (same API as the Companion
     * app; HA then gets notify.mobile_app_<name>) and renames the HA device when device_name changed on the TV.
     */
    fun webhookId(): String? = synchronized(registrationLock) {
        val regFile = File(context.filesDir, "ha_registration.json")
        val registration = runCatching { JSONObject(regFile.readText()) }.getOrNull()
        val existing = registration?.optString("webhook_id")?.ifEmpty { null }
        if (existing == null) {
            return register()?.also { regFile.writeText(JSONObject().put("webhook_id", it).put("device_name", deviceName).toString()) }
        }
        if (registration.optString("device_name") != deviceName && updateDeviceName(existing)) {
            regFile.writeText(JSONObject().put("webhook_id", existing).put("device_name", deviceName).toString())
        }
        existing
    }

    private fun appVersion() = context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "1"

    private fun register(): String? {
        val deviceId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: UUID.randomUUID().toString()
        val body = JSONObject()
            .put("device_id", "couchdash-$deviceId")
            .put("app_id", "app.couchdash.launcher")
            .put("app_name", "CouchDash")
            .put("app_version", appVersion())
            .put("device_name", deviceName)
            .put("manufacturer", Build.MANUFACTURER)
            .put("model", Build.MODEL)
            .put("os_name", "Android")
            .put("os_version", Build.VERSION.RELEASE)
            .put("supports_encryption", false)
            .put("app_data", JSONObject().put("push_websocket_channel", true))
        return runCatching {
            val t = token() ?: error("no token")
            http.newCall(
                Request.Builder().url("$baseUrl/api/mobile_app/registrations")
                    .header("Authorization", "Bearer $t")
                    .post(body.toString().toRequestBody(json)).build()
            ).execute().use { r ->
                if (!r.isSuccessful) error("HTTP ${r.code}")
                JSONObject(r.body!!.string()).getString("webhook_id")
            }
        }.onFailure { Log.w(TAG, "register: $it") }.getOrNull()
    }

    /** Renamed on the TV: update the existing HA device instead of registering a second one. */
    private fun updateDeviceName(webhookId: String): Boolean {
        val data = JSONObject()
            .put("device_name", deviceName)
            .put("app_version", appVersion())
            .put("manufacturer", Build.MANUFACTURER)
            .put("model", Build.MODEL)
            .put("os_version", Build.VERSION.RELEASE)
        return postWebhook(webhookId, JSONObject().put("type", "update_registration").put("data", data))
    }
}

/*
 * CouchDash: remote-button shortcuts, configured on the TV (Settings -> Home Assistant -> Remote shortcuts) and
 * stored in ha.json:
 *   "shortcuts": {"menu_long": {"type": "script", "entity_id": "script.goodnight", "name": "Goodnight"}}
 *   type "script" / "scene": <domain>.turn_on for entity_id;  type "event": fires couchdash_button through the
 *   mobile_app webhook ({button, press, device_name}), so HA automations decide. No entry = the button does nothing.
 * Run from the accessibility service (any app in front) or from the launcher itself when that service is off.
 */
package me.efesser.flauncher

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityManager
import android.widget.Toast
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object HaShortcuts {
    private const val TAG = "HaShortcuts"
    private val http by lazy { OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build() }

    /** The configured action for [key] (e.g. "menu_long"), or null when the button is unassigned. */
    fun shortcut(context: Context, key: String): JSONObject? =
        HaLink.readConfig(context)?.optJSONObject("shortcuts")?.optJSONObject(key)?.takeIf { it.optString("type").isNotEmpty() }

    /** Runs the shortcut on a background thread and shows a short toast with the outcome. */
    fun run(context: Context, key: String, button: String, press: String) {
        val app = context.applicationContext
        val shortcut = shortcut(app, key) ?: return
        Thread {
            val link = HaLink.load(app, http)
            val type = shortcut.optString("type")
            val label = shortcut.optString("name").ifEmpty { shortcut.optString("entity_id").ifEmpty { "Home Assistant" } }
            val ok = when {
                link == null -> false
                type == "script" || type == "scene" -> {
                    val entity = shortcut.optString("entity_id")
                    entity.isNotEmpty() && link.postAuthorized("/api/services/$type/turn_on", JSONObject().put("entity_id", entity))
                }
                type == "event" -> link.webhookId()?.let { id ->
                    val data = JSONObject().put("button", button).put("press", press).put("device_name", link.deviceName)
                    link.postWebhook(id, JSONObject().put("type", "fire_event")
                        .put("data", JSONObject().put("event_type", "couchdash_button").put("event_data", data)))
                } ?: false
                else -> false
            }
            if (!ok) Log.w(TAG, "$key ($type) failed")
            val text = if (ok) (if (type == "event") "Sent to Home Assistant ✓" else "$label ✓") else "Home Assistant: $label failed"
            Handler(Looper.getMainLooper()).post { Toast.makeText(app, text, Toast.LENGTH_SHORT).show() }
        }.start()
    }

    /**
     * CouchDash's accessibility service (remote buttons in every app): "on" (switched on and running), "off", or
     * "stuck": switched on but not running. Android 11 does that after the app's process died while bound (an app
     * update) and only starts it again once the user turns it off and on.
     */
    fun buttonServiceState(context: Context): String {
        val am = context.getSystemService(AccessibilityManager::class.java)
        val ours = ComponentName(context, HaButtonService::class.java)
        // the manager lists only services it has actually bound
        if (am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
                .any { it.resolveInfo.serviceInfo.let { s -> ComponentName(s.packageName, s.name) } == ours }) return "on"
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
        return if (enabled.split(':').any { ComponentName.unflattenFromString(it) == ours }) "stuck" else "off"
    }
}

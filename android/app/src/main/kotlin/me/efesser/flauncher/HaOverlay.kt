/*
 * FLauncher HA: the overlay windows for HA notifications (drawn over any app; needs "display over other apps",
 * granted once with: adb shell appops set net.kronie.flauncher_ha SYSTEM_ALERT_WINDOW allow).
 *   corner card  - top right; image/camera, title, message, action buttons, auto-dismiss
 *   critical     - centred, screen dimmed, red border; stays until a button or Back
 *   chip         - small persistent pill top left (data.chip: true), optional live countdown (data.countdown_until)
 * Windows without buttons never take focus, so the remote keeps controlling the app underneath.
 */
package me.efesser.flauncher

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.time.OffsetDateTime
import java.util.UUID

class HaOverlay(private val context: Context, private val onAction: (String, JSONObject) -> Unit) {
    private val wm = context.getSystemService(WindowManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient()

    private class Item(val tag: String, val view: View, val focusable: Boolean, val kind: String) {
        var dismiss: Runnable? = null
        var ticker: Runnable? = null
    }

    private val corner = ArrayList<Item>()
    private val chips = ArrayList<Item>()
    private var critical: Item? = null
    private var cornerRoot: LinearLayout? = null
    private var chipRoot: LinearLayout? = null

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, context.resources.displayMetrics).toInt()

    fun isShowing(tag: String) = corner.any { it.tag == tag } || chips.any { it.tag == tag } || critical?.tag == tag

    fun show(n: JSONObject, baseUrl: String?, token: String?) {
        if (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(context)) {
            Log.w("HaNotify", "no overlay permission: adb shell appops set ${context.packageName} SYSTEM_ALERT_WINDOW allow")
            return
        }
        val data = n.optJSONObject("data") ?: JSONObject()
        val tag = data.optString("tag").ifEmpty { UUID.randomUUID().toString() }
        remove(tag) // same tag replaces
        when {
            data.optBoolean("chip", false) -> showChip(tag, n, data)
            data.optString("priority") == "critical" || data.optString("position") == "center" -> showCritical(tag, n, data, baseUrl, token)
            else -> showCard(tag, n, data, baseUrl, token)
        }
    }

    fun remove(tag: String) {
        if (tag.isEmpty()) return
        corner.firstOrNull { it.tag == tag }?.let { removeCard(it) }
        chips.firstOrNull { it.tag == tag }?.let { removeChip(it) }
        critical?.takeIf { it.tag == tag }?.let { removeCritical() }
    }

    fun clearAll() {
        corner.toList().forEach { removeCard(it) }
        chips.toList().forEach { removeChip(it) }
        removeCritical()
    }

    // ---------- building blocks ----------
    private fun panel(radius: Float, fill: Int, stroke: Int, strokeDp: Float = 1f) = GradientDrawable().apply {
        cornerRadius = dp(radius).toFloat(); setColor(fill); setStroke(dp(strokeDp), stroke)
    }

    private fun text(s: String, sizeSp: Float, color: Int, bold: Boolean = false) = TextView(context).apply {
        text = s; setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp); setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun button(label: String, accent: Int, onPress: () -> Unit, onBack: () -> Unit) = TextView(context).apply {
        text = label; setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f); isFocusable = true; isFocusableInTouchMode = true
        setPadding(dp(18f), dp(10f), dp(18f), dp(10f))
        fun paint(focused: Boolean) {
            background = panel(10f, if (focused) accent else Color.argb(26, 255, 255, 255), Color.TRANSPARENT, 0f)
            setTextColor(if (focused && accent == Color.WHITE) Color.BLACK else Color.WHITE)
            scaleX = if (focused) 1.06f else 1f; scaleY = scaleX
        }
        paint(false)
        setOnFocusChangeListener { _, f -> paint(f) }
        setOnClickListener { onPress() }
        setOnKeyListener { _, code, e ->
            if (e.action == KeyEvent.ACTION_UP && code == KeyEvent.KEYCODE_BACK) { onBack(); true } else false
        }
    }

    private fun image(url: String, baseUrl: String?, token: String?, heightDp: Float): ImageView {
        val v = ImageView(context).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(heightDp))
            setBackgroundColor(Color.rgb(40, 46, 54))
        }
        load(v, url, baseUrl, token)
        return v
    }

    private fun load(v: ImageView, url: String, baseUrl: String?, token: String?) {
        val full = if (url.startsWith("/") && baseUrl != null) baseUrl + url else url
        Thread {
            val bmp: Bitmap? = runCatching {
                val req = Request.Builder().url(full)
                if (baseUrl != null && full.startsWith(baseUrl)) req.header("Authorization", "Bearer $token")
                http.newCall(req.build()).execute().use { r -> r.body?.bytes()?.let { BitmapFactory.decodeByteArray(it, 0, it.size) } }
            }.getOrNull()
            if (bmp != null) main.post { v.setImageBitmap(bmp) }
        }.start()
    }

    private fun params(focusable: Boolean, fullScreen: Boolean, gravity: Int) = WindowManager.LayoutParams(
        if (fullScreen) WindowManager.LayoutParams.MATCH_PARENT else WindowManager.LayoutParams.WRAP_CONTENT,
        if (fullScreen) WindowManager.LayoutParams.MATCH_PARENT else WindowManager.LayoutParams.WRAP_CONTENT,
        if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            (if (focusable) 0 else WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE),
        PixelFormat.TRANSLUCENT,
    ).apply { this.gravity = gravity; x = dp(28f); y = dp(24f) }

    private fun durationMs(data: JSONObject, hasActions: Boolean): Long? {
        val d = if (data.has("duration")) data.optLong("duration") else if (hasActions) 30 else 10
        return if (d <= 0) null else d * 1000
    }

    private fun content(n: JSONObject, data: JSONObject, baseUrl: String?, token: String?, item: () -> Item?,
                        accent: Int, big: Boolean, onDone: () -> Unit): LinearLayout {
        val box = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val camera = data.optString("camera")
        val imageUrl = data.optString("image").ifEmpty { if (camera.isNotEmpty()) "/api/camera_proxy/$camera" else "" }
        if (imageUrl.isNotEmpty()) {
            val img = image(imageUrl, baseUrl, token, if (big) 260f else 170f)
            box.addView(img)
            if (camera.isNotEmpty()) { // refresh the snapshot every 2 s while visible
                val tick = object : Runnable {
                    override fun run() {
                        if (item() == null) return
                        load(img, "/api/camera_proxy/$camera?t=${System.currentTimeMillis()}", baseUrl, token)
                        main.postDelayed(this, 2000)
                    }
                }
                main.postDelayed(tick, 2000)
            }
        }
        val body = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20f), dp(14f), dp(20f), dp(16f))
            if (big) gravity = Gravity.CENTER_HORIZONTAL
        }
        body.addView(text("HOME ASSISTANT", 11f, Color.argb(140, 255, 255, 255)))
        n.optString("title").takeIf { it.isNotBlank() }?.let { body.addView(text(it, if (big) 28f else 20f, Color.WHITE, true)) }
        n.optString("message").takeIf { it.isNotBlank() }?.let { body.addView(text(it, if (big) 18f else 15f, Color.argb(200, 255, 255, 255))) }
        val actions = data.optJSONArray("actions")
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(14f), 0, 0)
            if (big) gravity = Gravity.CENTER_HORIZONTAL
        }
        var first: View? = null
        if (actions != null) for (i in 0 until actions.length()) {
            val a = actions.optJSONObject(i) ?: continue
            val b = button(a.optString("title", a.optString("action")), accent, {
                onAction(a.optString("action"), n); onDone()
            }, onDone)
            row.addView(b, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                .apply { marginEnd = dp(10f) })
            if (first == null) first = b
        }
        if (row.childCount > 0) body.addView(row)
        body.addView(text(if (row.childCount > 0) "Back = dismiss" else "", 11f, Color.argb(110, 255, 255, 255)))
        box.addView(body)
        first?.post { first.requestFocus() }
        return box
    }

    // ---------- corner cards ----------
    private fun showCard(tag: String, n: JSONObject, data: JSONObject, baseUrl: String?, token: String?) {
        val hasActions = (data.optJSONArray("actions")?.length() ?: 0) > 0
        lateinit var item: Item
        val card = FrameLayout(context).apply {
            background = panel(22f, Color.argb(240, 18, 21, 27), Color.argb(46, 255, 255, 255))
            clipToOutline = true
        }
        card.addView(content(n, data, baseUrl, token, { corner.firstOrNull { it === item } }, Color.WHITE, false) { removeCard(item) })
        item = Item(tag, card, hasActions, "card")
        val root = cornerRoot ?: LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }.also {
            cornerRoot = it
            wm.addView(it, params(hasActions, false, Gravity.TOP or Gravity.END))
        }
        root.addView(card, LinearLayout.LayoutParams(dp(360f), ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(12f) })
        corner.add(item)
        refreshCornerFocus()
        durationMs(data, hasActions)?.let { ms -> item.dismiss = Runnable { removeCard(item) }.also { main.postDelayed(it, ms) } }
    }

    private fun removeCard(item: Item) {
        if (!corner.remove(item)) return
        item.dismiss?.let { main.removeCallbacks(it) }
        cornerRoot?.removeView(item.view)
        if (corner.isEmpty()) {
            cornerRoot?.let { runCatching { wm.removeView(it) } }
            cornerRoot = null
        } else refreshCornerFocus()
    }

    // the corner window only takes remote focus while a card with buttons is showing
    private fun refreshCornerFocus() {
        val root = cornerRoot ?: return
        val lp = root.layoutParams as WindowManager.LayoutParams
        val want = corner.any { it.focusable }
        val flags = if (want) lp.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        else lp.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        if (flags != lp.flags) { lp.flags = flags; wm.updateViewLayout(root, lp) }
    }

    // ---------- critical ----------
    private fun showCritical(tag: String, n: JSONObject, data: JSONObject, baseUrl: String?, token: String?) {
        removeCritical()
        lateinit var item: Item
        val dim = FrameLayout(context).apply { setBackgroundColor(Color.argb(160, 0, 0, 0)) }
        val card = FrameLayout(context).apply {
            background = panel(26f, Color.argb(246, 40, 12, 12), Color.rgb(255, 90, 79), 2f)
            clipToOutline = true
        }
        val red = Color.rgb(255, 90, 79)
        card.addView(content(n, data, baseUrl, token, { critical?.takeIf { it === item } }, red, true) { removeCritical() })
        dim.addView(card, FrameLayout.LayoutParams(dp(560f), ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        // no buttons: Back on the dimmed screen still dismisses
        dim.isFocusable = true
        dim.setOnKeyListener { _, code, e -> if (e.action == KeyEvent.ACTION_UP && code == KeyEvent.KEYCODE_BACK) { removeCritical(); true } else false }
        item = Item(tag, dim, true, "critical")
        critical = item
        wm.addView(dim, params(true, true, Gravity.CENTER).apply { x = 0; y = 0 })
        if ((data.optJSONArray("actions")?.length() ?: 0) == 0) dim.post { dim.requestFocus() }
        if (data.has("duration") && data.optLong("duration") > 0) {
            item.dismiss = Runnable { removeCritical() }.also { main.postDelayed(it, data.optLong("duration") * 1000) }
        }
    }

    private fun removeCritical() {
        val item = critical ?: return
        critical = null
        item.dismiss?.let { main.removeCallbacks(it) }
        runCatching { wm.removeView(item.view) }
    }

    // ---------- chips ----------
    private fun showChip(tag: String, n: JSONObject, data: JSONObject) {
        val label = listOf(n.optString("title"), n.optString("message")).filter { it.isNotBlank() }
        val chip = TextView(context).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f); setTextColor(Color.WHITE)
            setPadding(dp(14f), dp(7f), dp(14f), dp(7f))
            background = panel(20f, Color.argb(205, 14, 16, 20), Color.argb(36, 255, 255, 255))
        }
        val until = data.optString("countdown_until").takeIf { it.isNotEmpty() }
            ?.let { runCatching { OffsetDateTime.parse(it).toInstant().toEpochMilli() }.getOrNull() }
        val item = Item(tag, chip, false, "chip")
        fun render() {
            val base = label.firstOrNull() ?: ""
            if (until == null) {
                chip.text = label.joinToString("  ")
                return
            }
            val left = ((until - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
            val rest = if (left >= 3600) "%d:%02d:%02d".format(left / 3600, left / 60 % 60, left % 60) else "%d:%02d".format(left / 60, left % 60)
            chip.text = if (left == 0L) "$base  done" else "$base  $rest"
        }
        render()
        if (until != null) {
            item.ticker = object : Runnable {
                override fun run() {
                    if (!chips.contains(item)) return
                    render(); main.postDelayed(this, 1000)
                }
            }.also { main.postDelayed(it, 1000) }
        }
        val root = chipRoot ?: LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }.also {
            chipRoot = it
            wm.addView(it, params(false, false, Gravity.TOP or Gravity.START))
        }
        root.addView(chip, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(10f) })
        chips.add(item)
        if (data.has("duration") && data.optLong("duration") > 0) {
            item.dismiss = Runnable { removeChip(item) }.also { main.postDelayed(it, data.optLong("duration") * 1000) }
        }
    }

    private fun removeChip(item: Item) {
        if (!chips.remove(item)) return
        item.dismiss?.let { main.removeCallbacks(it) }
        item.ticker?.let { main.removeCallbacks(it) }
        chipRoot?.removeView(item.view)
        if (chips.isEmpty()) {
            chipRoot?.let { runCatching { wm.removeView(it) } }
            chipRoot = null
        }
    }
}

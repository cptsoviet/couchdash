/*
 * CouchDash: sees the remote's buttons in every app (an accessibility service the user switches on), so a long press
 * of Menu (≡) can run a Home Assistant shortcut while Plex or Netflix is in front.
 *
 * Accessibility services see a key before Android generates its auto-repeats, so a held key arrives here as just
 * DOWN ... UP: the long press is timed. Nothing is consumed: an accessibility service can't re-inject keys, and a
 * swallowed DOWN or UP would leave the app in front with a lost or stuck Menu key. So the app in front still gets
 * Menu (short press as usual; a held one it sees as a long press too), and the shortcut runs once the key has been
 * held for HOLD_MS. Two short presses within DOUBLE_MS run the "menu_double" shortcut (the app in front gets both).
 *
 * The Shield remote's Netflix button (KEYCODE_BUTTON_12) is different: when a "netflix_short" or "netflix_long"
 * shortcut is assigned, CouchDash owns that key and consumes the whole press, so short (on release) and long (held
 * HOLD_MS) are clean. The Shield itself still opens Netflix (or its Play Store page) on the press, before any
 * accessibility service sees the key, so when one of those comes to the front within NETFLIX_CLOSE_MS of the press,
 * the service presses Back. Unassigned, the key passes through untouched.
 * Every other key is ignored, which keeps it out of the way of other key services (Launcher Manager).
 */
package me.efesser.flauncher

import android.accessibilityservice.AccessibilityService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

private const val TAG = "HaButton"
private const val HOLD_MS = 500L
private const val DOUBLE_MS = 400L
private const val NETFLIX_CLOSE_MS = 3_000L

class HaButtonService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private var lastShortUp = 0L // eventTime of the last short Menu press, for double presses
    private val longPress = Runnable {
        Log.i(TAG, "menu held ${HOLD_MS} ms: running shortcut")
        HaShortcuts.run(this, "menu_long", "menu", "long")
    }

    private var netflixHeld = false // the long-press shortcut already ran for this press
    private var netflixPressedAt = 0L // uptime of the last assigned Netflix-button press
    private var lastBack = 0L
    private val netflixLong = Runnable {
        netflixHeld = true
        Log.i(TAG, "netflix held ${HOLD_MS} ms: running shortcut")
        HaShortcuts.run(this, "netflix_long", "netflix", "long")
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BUTTON_12) return onNetflix(event)
        if (event.keyCode != KeyEvent.KEYCODE_MENU) return false
        Log.i(TAG, "menu ${if (event.action == KeyEvent.ACTION_DOWN) "down" else "up"} (repeat ${event.repeatCount})")
        when (event.action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) {
                main.removeCallbacks(longPress)
                if (HaShortcuts.shortcut(this, "menu_long") != null) main.postDelayed(longPress, HOLD_MS)
            }
            KeyEvent.ACTION_UP -> {
                main.removeCallbacks(longPress)
                if (event.eventTime - event.downTime >= HOLD_MS) return false // that was the long press
                if (event.eventTime - lastShortUp <= DOUBLE_MS && HaShortcuts.shortcut(this, "menu_double") != null) {
                    lastShortUp = 0L
                    Log.i(TAG, "menu double press: running shortcut")
                    HaShortcuts.run(this, "menu_double", "menu", "double")
                } else {
                    lastShortUp = event.eventTime
                }
            }
        }
        return false
    }

    private fun onNetflix(event: KeyEvent): Boolean {
        val short = HaShortcuts.shortcut(this, "netflix_short")
        val long = HaShortcuts.shortcut(this, "netflix_long")
        if (short == null && long == null) return false // unassigned: the Netflix button works as before
        when (event.action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) {
                netflixHeld = false
                netflixPressedAt = SystemClock.uptimeMillis()
                main.removeCallbacks(netflixLong)
                if (long != null) main.postDelayed(netflixLong, HOLD_MS)
            }
            KeyEvent.ACTION_UP -> {
                main.removeCallbacks(netflixLong)
                if (!netflixHeld && short != null) {
                    Log.i(TAG, "netflix press: running shortcut")
                    HaShortcuts.run(this, "netflix_short", "netflix", "short")
                }
                netflixHeld = false
            }
        }
        return true
    }

    // the Shield's own Netflix launch (only these packages' window changes reach us, see couchdash_buttons.xml)
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val now = SystemClock.uptimeMillis()
        if (now - netflixPressedAt > NETFLIX_CLOSE_MS) return
        // one Back per window: the Play Store reports the same page more than once, and a second Back would land
        // in the app underneath
        if (now - lastBack < 700) return
        lastBack = now
        Log.i(TAG, "${event.packageName} opened by the Netflix button: closing it")
        performGlobalAction(GLOBAL_ACTION_BACK)
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        main.removeCallbacks(longPress)
        main.removeCallbacks(netflixLong)
        super.onDestroy()
    }
}

/*
 * CouchDash: sees the remote's buttons in every app (an accessibility service the user switches on), so a long press
 * of Menu (≡) can run a Home Assistant shortcut while Plex or Netflix is in front.
 *
 * Accessibility services see a key before Android generates its auto-repeats, so a held key arrives here as just
 * DOWN ... UP: the long press is timed. Nothing is consumed: an accessibility service can't re-inject keys, and a
 * swallowed DOWN or UP would leave the app in front with a lost or stuck Menu key. So the app in front still gets
 * Menu (short press as usual; a held one it sees as a long press too), and the shortcut runs once the key has been
 * held for HOLD_MS. Every other key is ignored, which keeps it out of the way of other key services (Launcher Manager).
 */
package me.efesser.flauncher

import android.accessibilityservice.AccessibilityService
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

private const val TAG = "HaButton"
private const val HOLD_MS = 500L

class HaButtonService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private val longPress = Runnable {
        Log.i(TAG, "menu held ${HOLD_MS} ms: running shortcut")
        HaShortcuts.run(this, "menu_long", "menu", "long")
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode != KeyEvent.KEYCODE_MENU) return false
        Log.i(TAG, "menu ${if (event.action == KeyEvent.ACTION_DOWN) "down" else "up"} (repeat ${event.repeatCount})")
        when (event.action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) {
                main.removeCallbacks(longPress)
                if (HaShortcuts.shortcut(this, "menu_long") != null) main.postDelayed(longPress, HOLD_MS)
            }
            KeyEvent.ACTION_UP -> main.removeCallbacks(longPress) // released early: a short press, nothing to run
        }
        return false
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onDestroy() {
        main.removeCallbacks(longPress)
        super.onDestroy()
    }
}

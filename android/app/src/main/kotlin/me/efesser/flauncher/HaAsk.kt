/*
 * CouchDash: "Ask Home Assistant" by voice, started from a remote shortcut (HaShortcuts, type "ask").
 *
 * Speech: Android's SpeechRecognizer (on the Shield: Google's TV recognizer, which also uses the remote's mic); needs
 * the RECORD_AUDIO permission, asked for in Settings -> Home Assistant. The text then runs through an HA Assist
 * pipeline from the intent stage to TTS (WebSocket assist_pipeline/run), so the pipeline's own agent answers and its
 * own TTS voice speaks (played here from the tts_proxy URL; Android's TTS only if the pipeline has none).
 * Which pipeline: the pipeline_id of the dashboard's assist action when it names one, else the state of the HA helper
 * PIPELINE_ENTITY (a pipeline name, as listed by assist_pipeline/pipeline/list); missing, "preferred" or unknown ->
 * HA's preferred pipeline. Swapping pipelines is done in HA. Asking again within 5 minutes continues the same conversation.
 *
 * UI: one small card at the bottom of the screen, over any app. From the accessibility service it is an accessibility
 * overlay (no extra permission); from the launcher an app overlay when allowed, else toasts.
 */
package me.efesser.flauncher

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object HaAsk {
    private const val TAG = "HaAsk"
    private const val CONVERSATION_MS = 5 * 60_000L
    private const val PIPELINE_ENTITY = "input_select.couchdash_assist_pipeline"

    private val main = Handler(Looper.getMainLooper())
    private val http by lazy { OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build() }
    private val ws by lazy { OkHttpClient.Builder().pingInterval(15, TimeUnit.SECONDS).build() }
    private var player: MediaPlayer? = null

    private var recognizer: SpeechRecognizer? = null
    private var card: View? = null
    private var cardWm: WindowManager? = null
    private var title: TextView? = null
    private var body: TextView? = null
    private var tts: TextToSpeech? = null
    private var conversationId: String? = null
    private var conversationAt = 0L
    private val hide = Runnable { hideCard() }

    fun micAllowed(context: Context) =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** Starts listening; a second trigger while listening cancels. Main thread. */
    private var pipelineId: String? = null // from the dashboard's assist action, for this question

    fun start(context: Context, pipeline: String? = null) {
        if (recognizer != null) {
            cancel()
            return
        }
        if (!micAllowed(context)) {
            toast(context, "Allow the microphone in CouchDash: Settings > Home Assistant")
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            toast(context, "No speech recognition on this TV")
            return
        }
        // "last_used" / "preferred" (HA's own placeholders) mean: no specific pipeline
        pipelineId = pipeline?.takeIf { it != "last_used" && it != "preferred" }
        main.removeCallbacks(hide)
        showCard(context, "Listening…", "")
        val r = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onPartialResults(partial: Bundle?) {
                partial?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    ?.takeIf { it.isNotBlank() }?.let { update("Listening…", it) }
            }

            override fun onResults(results: Bundle?) {
                release()
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                if (text.isNullOrBlank()) finish(context, "Didn't catch that", "", null, speak = false) else ask(context, text)
            }

            override fun onError(error: Int) {
                release()
                Log.w(TAG, "recognizer error $error")
                val msg = when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Didn't catch that"
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone not allowed"
                    SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition is offline"
                    else -> "Speech recognition failed ($error)"
                }
                finish(context, msg, "", null, speak = false)
            }

            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() = update("Thinking…", body?.text?.toString() ?: "")
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName))
    }

    private fun cancel() {
        recognizer?.cancel()
        release()
        hideCard()
    }

    private fun release() {
        recognizer?.destroy()
        recognizer = null
    }

    // text -> HA Assist pipeline (intent -> tts) -> reply card + the pipeline's voice
    private fun ask(context: Context, text: String) {
        update("Thinking…", "“$text”")
        val app = context.applicationContext
        Thread {
            val link = HaLink.load(app, http)
            val reply = link?.let { runPipeline(it, text) }
            Log.i(TAG, "pipeline reply: ${reply?.speech?.take(80)} (tts ${reply?.ttsUrl != null}, error ${reply?.error})")
            main.post {
                when {
                    reply == null -> finish(context, "Home Assistant didn't answer", "“$text”", null, speak = false)
                    reply.error != null -> finish(context, "Home Assistant: ${reply.error}", "“$text”", null, speak = false)
                    else -> finish(context, reply.speech ?: "Done", "“$text”", reply.ttsUrl?.let { url -> link?.absolute(url) },
                        speak = reply.speech != null)
                }
            }
        }.start()
    }

    private class Reply(val speech: String?, val ttsUrl: String?, val error: String?)

    /** One assist_pipeline/run over HA's WebSocket API; blocks up to 30 s. */
    private fun runPipeline(link: HaLink, text: String): Reply? {
        val fixedId = pipelineId
        val pipelineName = if (fixedId != null) null else link.getJson("/api/states/$PIPELINE_ENTITY")?.optString("state")
            ?.takeIf { it.isNotEmpty() && it != "preferred" && it != "unknown" && it != "unavailable" }
        val token = link.token() ?: return null
        val done = CountDownLatch(1)
        var speech: String? = null
        var ttsUrl: String? = null
        var error: String? = null
        val wsUrl = link.baseUrl.replaceFirst("http", "ws") + "/api/websocket"
        val socket = ws.newWebSocket(Request.Builder().url(wsUrl).build(), object : WebSocketListener() {
            fun run(webSocket: WebSocket, pipelineId: String?) {
                val run = JSONObject().put("id", 2).put("type", "assist_pipeline/run")
                    .put("start_stage", "intent").put("end_stage", "tts")
                    .put("input", JSONObject().put("text", text))
                pipelineId?.let { run.put("pipeline", it) }
                conversationId?.takeIf { System.currentTimeMillis() - conversationAt < CONVERSATION_MS }
                    ?.let { run.put("conversation_id", it) }
                webSocket.send(run.toString())
            }

            override fun onMessage(webSocket: WebSocket, msg: String) {
                val m = JSONObject(msg)
                when (m.optString("type")) {
                    "auth_required" -> webSocket.send(JSONObject().put("type", "auth").put("access_token", token).toString())
                    "auth_ok" -> if (pipelineName == null) run(webSocket, fixedId)
                        else webSocket.send(JSONObject().put("id", 1).put("type", "assist_pipeline/pipeline/list").toString())
                    "auth_invalid" -> { error = "login rejected"; done.countDown() }
                    "result" -> when {
                        m.optInt("id") == 1 -> {
                            // pipeline name from the HA helper -> id; not found (or no permission) -> preferred
                            val list = m.optJSONObject("result")?.optJSONArray("pipelines")
                            val id = (0 until (list?.length() ?: 0)).map { list!!.getJSONObject(it) }
                                .firstOrNull { it.optString("name").equals(pipelineName, ignoreCase = true) }?.optString("id")
                            if (id == null) Log.w(TAG, "pipeline \"$pipelineName\" not found; using the preferred one")
                            run(webSocket, id)
                        }
                        !m.optBoolean("success", true) -> {
                            error = m.optJSONObject("error")?.optString("message") ?: "pipeline failed"
                            done.countDown()
                        }
                    }
                    "event" -> {
                        val event = m.optJSONObject("event") ?: return
                        val data = event.optJSONObject("data")
                        when (event.optString("type")) {
                            "intent-end" -> {
                                val output = data?.optJSONObject("intent_output")
                                speech = output?.optJSONObject("response")?.optJSONObject("speech")?.optJSONObject("plain")
                                    ?.optString("speech")?.takeIf { it.isNotBlank() }
                                output?.optString("conversation_id")?.takeIf { it.isNotEmpty() }?.let {
                                    conversationId = it
                                    conversationAt = System.currentTimeMillis()
                                }
                            }
                            "tts-end" -> ttsUrl = data?.optJSONObject("tts_output")?.optString("url")?.takeIf { it.isNotEmpty() }
                            "error" -> { error = data?.optString("message") ?: "pipeline error"; done.countDown() }
                            "run-end" -> done.countDown()
                        }
                    }
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "websocket: $t")
                done.countDown()
            }
        })
        val finished = done.await(30, TimeUnit.SECONDS)
        socket.close(1000, null)
        if (!finished && speech == null) return null
        return Reply(speech, ttsUrl, if (speech == null) error else null)
    }

    private fun finish(context: Context, answer: String, question: String, ttsUrl: String?, speak: Boolean) {
        if (card == null) toast(context, answer) else update(answer, question)
        if (ttsUrl != null) play(context, ttsUrl, answer) else if (speak) say(context, answer)
        main.removeCallbacks(hide)
        main.postDelayed(hide, (4_000L + answer.length * 60L).coerceAtMost(15_000L))
    }

    // the pipeline's own TTS audio (e.g. ElevenLabs), streamed from HA's tts_proxy URL; Android's voice if that fails
    private fun play(context: Context, url: String, fallback: String) {
        player?.release()
        player = MediaPlayer().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            setOnPreparedListener { it.start() }
            setOnCompletionListener { it.release(); if (player === it) player = null }
            setOnErrorListener { mp, what, extra ->
                Log.w(TAG, "tts playback error $what/$extra")
                mp.release()
                if (player === mp) player = null
                say(context, fallback)
                true
            }
            runCatching {
                setDataSource(url)
                prepareAsync()
            }.onFailure {
                Log.w(TAG, "tts playback: $it")
                say(context, fallback)
            }
        }
    }

    private fun say(context: Context, text: String) {
        val t = tts
        if (t != null) {
            t.speak(text, TextToSpeech.QUEUE_FLUSH, null, "ha-ask")
            return
        }
        tts = TextToSpeech(context.applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "ha-ask")
        }
    }

    // ---------- the card ----------

    private fun dp(context: Context, v: Float) =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, context.resources.displayMetrics).toInt()

    private fun showCard(context: Context, heading: String, text: String) {
        if (card != null) {
            update(heading, text)
            return
        }
        val type = when {
            context is AccessibilityService -> WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
            Settings.canDrawOverlays(context) ->
                if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
            else -> null
        }
        Log.i(TAG, "card: ${if (context is AccessibilityService) "accessibility overlay" else if (type != null) "app overlay" else "no overlay, toasts"}")
        if (type == null) {
            toast(context, heading) // no overlay allowed: the answer comes as a toast too
            return
        }
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(context, 22f), dp(context, 14f), dp(context, 22f), dp(context, 16f))
            background = GradientDrawable().apply {
                cornerRadius = dp(context, 22f).toFloat()
                setColor(Color.argb(240, 18, 21, 27))
                setStroke(dp(context, 1f), Color.argb(46, 255, 255, 255))
            }
        }
        box.addView(TextView(context).apply {
            this.text = "HOME ASSISTANT"
            textSize = 11f
            setTextColor(Color.argb(140, 255, 255, 255))
        })
        title = TextView(context).apply {
            textSize = 20f
            setTextColor(Color.WHITE)
            paint.isFakeBoldText = true
        }.also { box.addView(it) }
        body = TextView(context).apply {
            textSize = 15f
            setTextColor(Color.argb(200, 255, 255, 255))
        }.also { box.addView(it) }
        val wm = context.getSystemService(WindowManager::class.java)
        val lp = WindowManager.LayoutParams(
            dp(context, 560f), WindowManager.LayoutParams.WRAP_CONTENT, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = dp(context, 48f)
        }
        runCatching { wm.addView(box, lp) }.onFailure {
            Log.w(TAG, "overlay: $it")
            toast(context, heading)
            return
        }
        card = box
        cardWm = wm
        Log.i(TAG, "card shown")
        update(heading, text)
    }

    private fun update(heading: String, text: String) {
        title?.text = heading
        body?.text = text
        body?.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun hideCard() {
        card?.let { v -> runCatching { cardWm?.removeView(v) } }
        card = null
        cardWm = null
        title = null
        body = null
    }

    private fun toast(context: Context, text: String) =
        Toast.makeText(context.applicationContext, text, Toast.LENGTH_SHORT).show()
}

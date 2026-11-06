package com.b1101.tark.diagnostics

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Notices when the app freezes, and leaves a note behind if the freeze is how
 * the run ended.
 *
 * Android only keeps an ANR's trace from API 30 (see
 * [DiagnosticsHandler.lastExit]). On anything older a run that froze and was
 * then closed — "it got stuck and then crashed" — leaves a log that simply
 * stops, with nothing to say whether it froze, which thread froze, or where
 * (2026-11-03: a Galaxy S8 on Android 9 went silent behind a Bluetooth invite
 * and restarted 80 seconds later with no record at all). A Dart isolate stuck
 * in a loop is invisible even on newer Android: the platform thread keeps
 * answering, so no ANR is ever raised.
 *
 * Two clocks are watched, once a second, from a thread of their own:
 *  - **main**: a tick posted to the main looper has to run within
 *    [STALL_AFTER_MS];
 *  - **dart**: while Dart says the app is in the foreground it calls
 *    `heartbeat` every second, over a background queue so a busy main thread
 *    cannot be mistaken for a stuck isolate.
 *
 * A freeze past the threshold is written to [STALL_FILE] at once — the
 * process may not live to write anything later — and removed again when the
 * thread recovers. A file still there at the next start is therefore a run
 * that died frozen, and [DiagnosticsHandler.lastExit] reports it. A freeze
 * that recovered is handed back on the next heartbeat so the live log says
 * so too. Only class and method names are kept, never data.
 */
class FreezeWatchdog private constructor(context: Context) : MethodChannel.MethodCallHandler {

    private val stallFile = File(context.applicationContext.filesDir, STALL_FILE)
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var mainTickAt = SystemClock.uptimeMillis()
    @Volatile private var dartBeatAt = 0L
    @Volatile private var dartWatched = false

    private val lock = Any()
    private var recorded: String? = null
    private var recordedSince = 0L
    private val recovered = mutableListOf<String>()

    private val tick = Runnable { mainTickAt = SystemClock.uptimeMillis() }
    private var checkedAt = SystemClock.uptimeMillis()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "heartbeat" -> {
                dartBeatAt = SystemClock.uptimeMillis()
                dartWatched = true
                result.success(drainRecovered())
            }
            "pause" -> {
                dartWatched = false
                result.success(drainRecovered())
            }
            else -> result.notImplemented()
        }
    }

    private fun drainRecovered(): List<String> = synchronized(lock) {
        val out = recovered.toList()
        recovered.clear()
        out
    }

    private fun start() {
        Thread({
            while (true) {
                try {
                    Thread.sleep(POLL_MS)
                    check()
                } catch (_: InterruptedException) {
                    return@Thread
                } catch (e: Throwable) {
                    // Diagnostics must never be what takes a session down.
                    Log.w(TAG, "watchdog check failed: ${e.javaClass.simpleName}")
                }
            }
        }, "tark-freeze-watchdog").apply {
            isDaemon = true
            priority = Thread.MIN_PRIORITY
            start()
        }
    }

    private fun check() {
        val now = SystemClock.uptimeMillis()
        val slept = now - checkedAt
        checkedAt = now
        if (slept >= POLL_MS + STALL_AFTER_MS) {
            // This thread overslept as badly as the others: the whole process
            // was suspended (the system's background freezer, a debugger), not
            // one thread stuck. Start the clocks again rather than report it.
            mainTickAt = now
            if (dartWatched) dartBeatAt = now
            synchronized(lock) {
                recorded = null
                runCatching { stallFile.delete() }
            }
            main.post(tick)
            return
        }
        main.post(tick)
        val mainLate = now - mainTickAt
        val dartLate = if (dartWatched && dartBeatAt > 0) now - dartBeatAt else 0L
        val frozen = when {
            mainLate >= STALL_AFTER_MS -> "main"
            dartLate >= STALL_AFTER_MS -> "dart"
            else -> null
        }
        synchronized(lock) {
            val current = recorded
            if (frozen == null) {
                if (current != null) {
                    val lasted = now - recordedSince
                    recovered += "$current thread froze for ${lasted / 1000}s and recovered"
                    if (recovered.size > MAX_RECOVERED) recovered.removeAt(0)
                    recorded = null
                    runCatching { stallFile.delete() }
                }
                return
            }
            if (current == frozen) {
                // Keep the note's duration current: if the run dies now, the
                // next start can say how long it had been frozen.
                write(frozen, if (frozen == "main") mainLate else dartLate)
                return
            }
            recorded = frozen
            recordedSince = now - (if (frozen == "main") mainLate else dartLate)
            write(frozen, now - recordedSince)
            Log.w(TAG, "$frozen thread frozen for ${(now - recordedSince) / 1000}s")
        }
    }

    private fun write(which: String, lateMs: Long) {
        val lines = mutableListOf("thread=$which frozenForMs=$lateMs")
        // The main thread's stack says where it is stuck. A frozen Dart
        // isolate has no Java stack to show; the main thread's is still worth
        // a few frames, to show it was idle rather than waiting on Dart.
        val frames = if (which == "main") MAIN_FRAMES else IDLE_FRAMES
        Looper.getMainLooper().thread.stackTrace.take(frames).forEach {
            lines += "  at ${it.className}.${it.methodName}"
        }
        runCatching { stallFile.writeText(lines.joinToString("\n")) }
    }

    companion object {
        private const val TAG = "TarkFreezeWatchdog"
        const val STALL_FILE = "last-stall.txt"
        const val METHOD_CHANNEL = "tark/diagnostics/watchdog"

        private const val POLL_MS = 1000L

        /// Android's own input-ANR threshold.
        private const val STALL_AFTER_MS = 5000L
        private const val MAIN_FRAMES = 25
        private const val IDLE_FRAMES = 6
        private const val MAX_RECOVERED = 8

        @Volatile
        private var instance: FreezeWatchdog? = null

        @Volatile
        private var leftover: String? = null

        /**
         * One watchdog per process, whatever recreates the activity. The note
         * a run that died frozen left behind is taken first, before this
         * run's watchdog starts owning the file.
         */
        fun install(context: Context): FreezeWatchdog =
            instance ?: synchronized(this) {
                instance ?: run {
                    val file = File(context.applicationContext.filesDir, STALL_FILE)
                    if (file.exists()) {
                        leftover = runCatching { file.readText().take(4000) }
                            .getOrNull()?.ifBlank { null }
                        runCatching { file.delete() }
                    }
                    FreezeWatchdog(context).also {
                        instance = it
                        it.start()
                    }
                }
            }

        /** How the previous run was frozen when it died, reported once. */
        fun takeLeftover(): String? = synchronized(this) {
            val out = leftover
            leftover = null
            out
        }
    }
}

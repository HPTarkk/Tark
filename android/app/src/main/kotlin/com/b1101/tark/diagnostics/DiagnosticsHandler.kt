package com.b1101.tark.diagnostics

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The two platform favours the on-device diagnostic log needs (see
 * lib/core/diagnostics/diagnostic_log.dart): somewhere private to keep the log,
 * and the system share sheet to get it off the phone.
 *
 * Methods (channel "tark/diagnostics"):
 *   logsDirectory() -> String   app-private directory the log lives in
 *   shareFile(path, mimeType, subject) -> Bool   true if a share sheet opened
 *   lastExit() -> Map?   how the previous run ended, once, or null
 *
 * ## Why FileProvider
 *
 * From API 24 a `file://` URI in an Intent throws FileUriExposedException, so
 * the log has to be handed over as a `content://` URI backed by a provider.
 * The provider is declared in AndroidManifest.xml against res/xml/tark_file_paths.xml,
 * which exposes exactly one subdirectory — `diagnostics/` under filesDir — and
 * nothing else the app stores.
 */
class DiagnosticsHandler(
    private val context: Context,
    private val activityProvider: () -> Activity?,
) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "logsDirectory" -> result.success(context.filesDir.absolutePath)
            "shareFile" -> result.success(
                share(
                    path = call.argument<String>("path").orEmpty(),
                    mimeType = call.argument<String>("mimeType").orEmpty(),
                    subject = call.argument<String>("subject").orEmpty(),
                ),
            )
            "lastExit" -> result.success(lastExit())
            else -> result.notImplemented()
        }
    }

    /**
     * How the previous run of the app ended, reported once.
     *
     * A run that died mid-call left a log that simply stopped, with nothing
     * to say whether it crashed, froze or was killed for memory (2026-10-16:
     * the hosting phone's log ended seconds after the other phone joined).
     * Android keeps the reason (API 30+); a crash in our own Kotlin also
     * leaves its stack in [CRASH_FILE]. Only class and frame names are kept:
     * an exception's message can carry a network name.
     */
    private fun lastExit(): Map<String, Any?>? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val out = mutableMapOf<String, Any?>()
        val crash = File(context.filesDir, CRASH_FILE)
        if (crash.exists()) {
            out["crash"] = runCatching { crash.readText().take(4000) }.getOrNull()
            crash.delete()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = context.getSystemService(ActivityManager::class.java)
            val info = runCatching {
                manager?.getHistoricalProcessExitReasons(context.packageName, 0, 1)
                    ?.firstOrNull()
            }.getOrNull()
            if (info != null && info.timestamp > prefs.getLong(KEY_REPORTED, 0L)) {
                prefs.edit().putLong(KEY_REPORTED, info.timestamp).apply()
                out["reason"] = reasonName(info.reason)
                out["at"] = info.timestamp
                out["status"] = info.status
                out["importance"] = info.importance
                out["pssKb"] = info.pss
                if (info.reason == ApplicationExitInfo.REASON_ANR) {
                    anrThreads(info)?.let { out["anr"] = it }
                }
            }
        }
        return if (out.isEmpty()) null else out
    }

    /**
     * The frozen run's main thread and Flutter's UI thread, from the trace
     * Android kept for the ANR: which of the two was stuck, and where. Only
     * the frame lines are kept (`at …`, `- waiting …`, `native: #NN …`); they
     * name classes and methods, never data.
     */
    private fun anrThreads(info: ApplicationExitInfo): String? = runCatching {
        val text = info.traceInputStream?.bufferedReader()?.use { it.readText() }
            ?: return null
        val wanted = listOf("\"main\"", "\"1.ui\"")
        val kept = StringBuilder()
        var current: String? = null
        var frames = 0
        for (line in text.lineSequence()) {
            if (line.startsWith("\"")) {
                current = wanted.firstOrNull { line.startsWith(it) }
                frames = 0
                if (current != null) kept.append("thread ").append(current).append('\n')
                continue
            }
            if (current == null || frames >= ANR_FRAMES) continue
            val trimmed = line.trim()
            if (trimmed.startsWith("at ") ||
                trimmed.startsWith("- waiting") ||
                trimmed.startsWith("- locked") ||
                trimmed.startsWith("native: #")
            ) {
                kept.append("  ").append(trimmed.take(160)).append('\n')
                frames++
            }
        }
        kept.toString().ifEmpty { null }
    }.getOrNull()

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash_native"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
        ApplicationExitInfo.REASON_EXIT_SELF -> "exit_self"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization_failure"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_OTHER -> "other"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
        ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
        else -> "unknown($reason)"
    }

    private fun share(path: String, mimeType: String, subject: String): Boolean {
        if (path.isEmpty()) return false
        val file = File(path)
        if (!file.exists()) {
            Log.w(TAG, "shareFile: $path does not exist")
            return false
        }

        val uri = try {
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        } catch (e: IllegalArgumentException) {
            // The file is outside every <files-path> the provider declares.
            // Worth a loud line: it means the log moved and the paths XML
            // didn't follow, which is otherwise a silently dead button.
            Log.e(TAG, "shareFile: $path is not covered by the FileProvider paths", e)
            return false
        }

        val send = Intent(Intent.ACTION_SEND).apply {
            type = mimeType.ifEmpty { "application/octet-stream" }
            putExtra(Intent.EXTRA_STREAM, uri)
            if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, subject.ifEmpty { null })

        // Prefer the Activity: a chooser started from the application context
        // needs NEW_TASK and then lands outside the app's own task, which on
        // some OEM builds shows up behind the app instead of over it. The
        // context path is the fallback for a share raised while the Activity is
        // being recreated.
        val activity = activityProvider()
        return try {
            if (activity != null) {
                activity.startActivity(chooser)
            } else {
                context.startActivity(chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "shareFile: no app accepted the share", e)
            false
        }
    }

    companion object {
        private const val TAG = "TarkDiagnostics"
        private const val PREFS = "tark_diagnostics"
        private const val KEY_REPORTED = "last_exit_reported"
        private const val CRASH_FILE = "last-crash.txt"
        private const val ANR_FRAMES = 25

        @Volatile
        private var installed = false

        /**
         * Keeps the stack of a Kotlin crash for the next run's log, then lets
         * the crash go on as before.
         */
        fun installCrashRecorder(context: Context) {
            if (installed) return
            installed = true
            val app = context.applicationContext
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                runCatching {
                    File(app.filesDir, CRASH_FILE).writeText(describe(thread, error))
                }
                previous?.uncaughtException(thread, error)
            }
        }

        private fun describe(thread: Thread, error: Throwable): String {
            val lines = mutableListOf("thread=${thread.name}")
            var cause: Throwable? = error
            var depth = 0
            while (cause != null && depth < 4) {
                lines += (if (depth == 0) "" else "caused by ") + cause.javaClass.name
                cause.stackTrace.take(12).forEach { lines += "  at $it" }
                cause = cause.cause
                depth++
            }
            return lines.joinToString("\n")
        }
    }
}

package com.b1101.tark.diagnostics

import android.app.Activity
import android.content.Context
import android.content.Intent
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
            else -> result.notImplemented()
        }
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
    }
}

package com.b1101.tark.bluetooth

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue

/**
 * Minimal Bluetooth Classic "host" (server) support, filling the gap left by
 * the flutter_blue_classic plugin, which only exposes outgoing connect() —
 * no listenUsingRfcommWithServiceRecord()/accept(). Scoped to exactly one
 * active hosted connection at a time, matching this app's 1-to-1 Bluetooth
 * mode (no need for per-connection dynamic channel registration).
 *
 * Methods (channel "tark/bluetooth_server/methods"):
 *   isDiscoverable()                     -> bool (adapter currently answering inquiries)
 *   requestDiscoverable(durationSeconds) -> bool (whether discoverability is now ON;
 *                                           resolves only once the user answers)
 *   startHosting(name)                   -> starts listening under [name]; "connected"/"error" events follow on the connection channel
 *   connectToPeer(address)               -> dials [address] as a client; same events/read channel as hosting
 *   stopHosting()                        -> stops listening / closes any accepted socket
 *   write(bytes)                         -> writes to the currently accepted socket
 *   closeConnection()                    -> closes the currently accepted socket only
 *
 * Events (channel "tark/bluetooth_server/connection"):
 *   {event: "connected", address: String}
 *   {event: "closed"}
 *   {event: "error", message: String}
 *
 * Events (channel "tark/bluetooth_server/read"):
 *   raw ByteArray chunks read from the accepted socket
 */
class BluetoothServerHandler(
    private val context: Context,
    messenger: BinaryMessenger,
    private val activityProvider: () -> Activity?,
) : MethodChannel.MethodCallHandler {

    companion object {
        // Logged at INFO so a release build on a real pair of phones still
        // says which side dropped an RFCOMM session and why — the Dart
        // Logger is debug-only, and this failure only shows up on hardware.
        // `adb logcat -s TarkBT`.
        private const val TAG = "TarkBT"

        // Standard Serial Port Profile UUID — matches the default used by
        // flutter_blue_classic's connect() when no explicit UUID is passed,
        // so client and host agree on the same RFCOMM service without
        // either side needing to hardcode the other's UUID.
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private const val REQUEST_DISCOVERABLE_CODE = 4242

        // Audio arrives at a fixed cadence (one packet per ~20ms) regardless of
        // what the RFCOMM link can carry. Matches the BLE engine's pending-write
        // cap: once the writer thread is this far behind, newest packets are
        // DROPPED instead of queued — stale audio is worse than lost audio.
        private const val WRITE_QUEUE_CAPACITY = 8

        // Where the adapter name is parked while hosting renames it. Survives
        // process death on purpose: a kill mid-session is exactly the case
        // where nothing else would ever put the user's own name back.
        private const val PREFS_NAME = "tark_bluetooth"
        private const val KEY_ORIGINAL_ADAPTER_NAME = "original_adapter_name"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val connectionEvents = EventChannel(messenger, "tark/bluetooth_server/connection")
    private val readEvents = EventChannel(messenger, "tark/bluetooth_server/read")

    private var connectionSink: EventChannel.EventSink? = null
    private var readSink: EventChannel.EventSink? = null

    private var serverSocket: BluetoothServerSocket? = null
    private var acceptThread: Thread? = null

    // Written from the accept/connect threads and read from the platform
    // thread, hence @Volatile. Holds the live session's socket whichever way
    // it was established — hosting and dialing share all the plumbing below.
    @Volatile
    private var acceptedSocket: BluetoothSocket? = null

    // The socket of a dial still in progress. Kept so the dial can be
    // cancelled: closing a connecting BluetoothSocket from another thread is
    // the only way to unblock connect(), which otherwise runs for ~30s.
    @Volatile
    private var pendingClientSocket: BluetoothSocket? = null
    private var readThread: Thread? = null
    private var writerThread: Thread? = null
    private val writeQueue = ArrayBlockingQueue<ByteArray>(WRITE_QUEUE_CAPACITY)

    /// The in-flight requestDiscoverable() call, answered from
    /// [handleActivityResult] once the user accepts or declines the dialog.
    private var pendingDiscoverable: MethodChannel.Result? = null

    init {
        connectionEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                connectionSink = events
            }
            override fun onCancel(arguments: Any?) {
                connectionSink = null
            }
        })
        readEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                readSink = events
            }
            override fun onCancel(arguments: Any?) {
                readSink = null
            }
        })
        // A previous run may have been killed while hosting, leaving the
        // adapter under the hosting name. Put it back before doing anything.
        restoreAdapterName()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isDiscoverable" -> result.success(isDiscoverable())
            "requestDiscoverable" -> {
                val seconds = (call.argument<Int>("durationSeconds")) ?: 120
                requestDiscoverable(seconds, result)
            }
            "startHosting" -> {
                val name = call.argument<String>("name") ?: "tark"
                startHosting(name, result)
            }
            "connectToPeer" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("invalid_args", "address is required", null)
                    return
                }
                connectToPeer(address, result)
            }
            "stopHosting" -> {
                stopHosting()
                result.success(null)
            }
            "write" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("invalid_args", "bytes is required", null)
                    return
                }
                enqueueWrite(bytes, result)
            }
            "closeConnection" -> {
                if (acceptedSocket != null) Log.i(TAG, "closeConnection requested by app")
                closeAcceptedSocketOnly()
                result.success(null)
            }
            // Dart needs the API level to decide whether classic discovery
            // requires the legacy fine-location permission (Android <= 11).
            "sdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
            else -> result.notImplemented()
        }
    }

    // A classic inquiry only ever reports adapters in DISCOVERABLE scan mode.
    // Merely listening on RFCOMM (or being bonded) is invisible to a scanning
    // device — which is why hosting has to check this rather than assume the
    // server socket is enough to be found.
    private fun isDiscoverable(): Boolean {
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return false
        return try {
            adapter.isEnabled &&
                adapter.scanMode == BluetoothAdapter.SCAN_MODE_CONNECTABLE_DISCOVERABLE
        } catch (e: SecurityException) {
            // BLUETOOTH_SCAN missing on 12+: report "not discoverable" so the
            // caller offers the dialog instead of silently trusting a guess.
            false
        }
    }

    // Resolves only once the user answers the system dialog: the caller starts
    // the RFCOMM server right afterwards, and doing that before the dialog is
    // dismissed used to race the adapter being powered on by that very dialog.
    // The result is the ANSWER (true = discoverable now), not "a dialog was
    // shown" — the host screen needs to know whether it is actually findable.
    private fun requestDiscoverable(seconds: Int, result: MethodChannel.Result) {
        if (isDiscoverable()) {
            // Still inside a previously granted window — asking again would
            // pop a dialog for something already true.
            result.success(true)
            return
        }
        val activity = activityProvider()
        if (activity == null) {
            result.success(false)
            return
        }
        // Only one dialog can be up at a time; a superseded request answers
        // false rather than leaking a never-completed Dart future.
        pendingDiscoverable?.success(false)
        pendingDiscoverable = null
        try {
            val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, seconds)
            }
            pendingDiscoverable = result
            activity.startActivityForResult(intent, REQUEST_DISCOVERABLE_CODE)
        } catch (e: Exception) {
            pendingDiscoverable = null
            result.success(false)
        }
    }

    /** Routed from MainActivity.onActivityResult; true when handled here. */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_DISCOVERABLE_CODE) return false
        val pending = pendingDiscoverable ?: return true
        pendingDiscoverable = null
        // The system returns the granted duration as the result code, and
        // RESULT_CANCELED (0) when the user declined.
        pending.success(resultCode != Activity.RESULT_CANCELED)
        return true
    }

    // Dials [address] with an INSECURE RFCOMM socket, matching the insecure
    // server socket in startHosting().
    //
    // This exists because flutter_blue_classic dials with the SECURE variant
    // (createRfcommSocketToServiceRecord), and secure-client-against-insecure-
    // server is what made a session look half-alive: the host's accept()
    // returns as soon as the RFCOMM channel opens — an insecure server demands
    // no authentication — so the host declared itself connected and walked
    // into the channel, while the client was still negotiating authentication
    // that an unbonded pair never completes. The joiner never registered the
    // socket, kept re-dialing, and the host flapped connected/disconnected
    // once per retry. Insecure on both ends also keeps the product promise:
    // two phones talk without completing a system pairing prompt first.
    //
    // A landed dial reuses the hosting plumbing wholesale (same connection
    // events, same read loop, same bounded writer), so the Dart side sees one
    // session shape regardless of which end opened it.
    private fun connectToPeer(address: String, result: MethodChannel.Result) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            result.error("unsupported", "Bluetooth is not supported on this device", null)
            return
        }
        if (acceptedSocket != null) {
            result.error("busy", "A Bluetooth session is already connected", null)
            return
        }
        if (pendingClientSocket != null) {
            result.error("busy", "A dial is already in flight", null)
            return
        }
        val device = try {
            adapter.getRemoteDevice(address)
        } catch (e: IllegalArgumentException) {
            result.error("invalid_address", e.message, null)
            return
        }
        // An inquiry in progress starves the connect and is the classic cause
        // of "read failed, socket might closed" on the first dial.
        try {
            adapter.cancelDiscovery()
        } catch (_: SecurityException) {
        }
        val socket = try {
            device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
        } catch (e: Exception) {
            result.error("socket_failed", e.message, null)
            return
        }
        pendingClientSocket = socket
        Log.i(TAG, "dialing $address (insecure RFCOMM)")

        Thread {
            try {
                // Blocks until connected, refused, or closed by a cancel.
                socket.connect()
            } catch (e: Exception) {
                Log.w(TAG, "dial to $address failed: ${e.message}")
                try {
                    socket.close()
                } catch (_: IOException) {
                }
                mainHandler.post {
                    if (pendingClientSocket === socket) pendingClientSocket = null
                    result.error("connect_failed", e.message ?: "connect failed", null)
                }
                return@Thread
            }
            mainHandler.post {
                if (pendingClientSocket !== socket) {
                    // Cancelled mid-dial. Closing it here is what stops the
                    // remote from holding a session this side has walked away
                    // from — the exact phantom the host watchdog cleans up.
                    Log.i(TAG, "dial landed after being cancelled — closing it")
                    try {
                        socket.close()
                    } catch (_: IOException) {
                    }
                    result.success(false)
                    return@post
                }
                pendingClientSocket = null
                acceptedSocket = socket
                Log.i(TAG, "dial connected to $address")
                result.success(true)
                emitConnectionEvent(mapOf("event" to "connected", "address" to address))
                startReadLoop(socket)
                startWriterLoop(socket)
            }
        }.also { it.start() }
    }

    private fun startHosting(name: String, result: MethodChannel.Result) {
        // A re-host racing an incoming connection must not kill it. stopHosting()
        // below closes the accepted socket too, so without this guard the repo's
        // auto-reconnect loop (which re-hosts the moment a link looks closed)
        // could tear down the very session that just landed — the joiner would
        // see its brand-new connection die and dial again, forever.
        if (acceptedSocket != null) {
            Log.i(TAG, "startHosting ignored: a session is already connected")
            result.success(null)
            return
        }
        Log.i(TAG, "startHosting as \"$name\" (discoverable=${isDiscoverable()})")
        stopHosting()
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            result.error("unsupported", "Bluetooth is not supported on this device", null)
            return
        }
        // A classic inquiry reports the remote ADAPTER name and nothing else —
        // the service-record name below never reaches a scanning device. So
        // the adapter itself carries the hosting name for the duration of the
        // session; stopHosting()/onDestroy/next launch put the original back.
        applyAdapterName(adapter, name)

        try {
            serverSocket = adapter.listenUsingInsecureRfcommWithServiceRecord(name, SPP_UUID)
        } catch (e: IOException) {
            restoreAdapterName()
            result.error("listen_failed", e.message, null)
            return
        } catch (e: SecurityException) {
            restoreAdapterName()
            result.error("permission_denied", e.message, null)
            return
        }

        result.success(null)

        acceptThread = Thread {
            try {
                // accept() blocks until a client connects or the socket is closed
                // (stopHosting()/dispose() calls serverSocket.close() to unblock it).
                val socket = serverSocket?.accept() ?: return@Thread
                acceptedSocket = socket
                Log.i(TAG, "accepted ${socket.remoteDevice?.address}")
                // Stop listening for further connections once one peer is in —
                // this app is strictly 1-to-1.
                try {
                    serverSocket?.close()
                } catch (_: IOException) {
                }
                emitConnectionEvent(
                    mapOf("event" to "connected", "address" to (socket.remoteDevice?.address ?: ""))
                )
                startReadLoop(socket)
                startWriterLoop(socket)
            } catch (e: IOException) {
                Log.w(TAG, "accept failed: ${e.message}")
                emitConnectionEvent(mapOf("event" to "error", "message" to (e.message ?: "accept failed")))
            }
        }.also { it.start() }
    }

    private fun startReadLoop(socket: BluetoothSocket) {
        readThread = Thread {
            val buffer = ByteArray(4096)
            val input = try {
                socket.inputStream
            } catch (e: IOException) {
                endSession("input stream failed: ${e.message}")
                emitConnectionEvent(mapOf("event" to "error", "message" to (e.message ?: "input stream failed")))
                return@Thread
            }
            var reason = "EOF"
            while (true) {
                val readCount = try {
                    input.read(buffer)
                } catch (e: IOException) {
                    reason = "read failed: ${e.message}"
                    break
                }
                if (readCount <= 0) break
                val chunk = buffer.copyOf(readCount)
                mainHandler.post { readSink?.success(chunk) }
            }
            endSession(reason)
            emitConnectionEvent(mapOf("event" to "closed"))
        }.also { it.start() }
    }

    // A link that ended on its own still leaves [acceptedSocket] pointing at a
    // dead socket. Releasing it here is what lets the Dart side's re-host
    // actually re-listen: startHosting() refuses to run while a session looks
    // live, so a stale reference here would strand the host offline for good.
    private fun endSession(reason: String) {
        Log.i(TAG, "session closed ($reason)")
        closeAcceptedSocketOnly()
    }

    // The blocking socket write happens on [writerThread], never on the
    // platform/main thread — invokeMethod("write") used to write synchronously
    // right here, which stalled the whole method channel (and, transitively,
    // the read loop's `mainHandler.post` events) whenever the RFCOMM link
    // couldn't drain as fast as audio was produced. Enqueueing is non-blocking
    // and drops the newest packet if the writer is backlogged, matching
    // [WRITE_QUEUE_CAPACITY]'s stale-audio-is-worse-than-lost-audio policy.
    private fun enqueueWrite(bytes: ByteArray, result: MethodChannel.Result) {
        if (acceptedSocket == null) {
            result.error("not_connected", "No accepted Bluetooth connection", null)
            return
        }
        writeQueue.offer(bytes)
        result.success(null)
    }

    private fun startWriterLoop(socket: BluetoothSocket) {
        writeQueue.clear()
        writerThread = Thread {
            val output = try {
                socket.outputStream
            } catch (e: IOException) {
                return@Thread
            }
            try {
                while (true) {
                    val bytes = writeQueue.take()
                    output.write(bytes)
                }
            } catch (_: InterruptedException) {
                // Normal shutdown path (closeAcceptedSocketOnly interrupts this thread).
            } catch (_: IOException) {
                // Socket closed/broken; the read loop's onDone path handles the
                // "closed" event, nothing further to do here.
            }
        }.also { it.start() }
    }

    private fun closeAcceptedSocketOnly() {
        // Closing the socket is what unblocks a connect() still in progress;
        // its thread then takes the failure path and cleans up after itself.
        val pending = pendingClientSocket
        pendingClientSocket = null
        if (pending != null) {
            Log.i(TAG, "cancelling in-flight dial")
            try {
                pending.close()
            } catch (_: IOException) {
            }
        }
        try {
            acceptedSocket?.close()
        } catch (_: IOException) {
        }
        acceptedSocket = null
        readThread = null
        writerThread?.interrupt()
        writerThread = null
        writeQueue.clear()
    }

    fun stopHosting() {
        try {
            serverSocket?.close()
        } catch (_: IOException) {
        }
        serverSocket = null
        acceptThread = null
        closeAcceptedSocketOnly()
        restoreAdapterName()
    }

    // Renames the adapter to [hostName], remembering what it was called
    // first. A failure is not fatal: hosting still works, the joiner just
    // sees the OEM name and can't tell this device apart from a headset.
    private fun applyAdapterName(adapter: BluetoothAdapter, hostName: String) {
        try {
            val current = adapter.name ?: return
            if (current == hostName) return
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            // Only the FIRST rename records an original — re-hosting (or an
            // auto-reconnect) must not save the hosting name over it.
            if (!prefs.contains(KEY_ORIGINAL_ADAPTER_NAME)) {
                prefs.edit().putString(KEY_ORIGINAL_ADAPTER_NAME, current).apply()
            }
            adapter.name = hostName
        } catch (e: SecurityException) {
            // BLUETOOTH_CONNECT revoked, or an OEM that locks the name down.
        }
    }

    // Puts the user's own device name back. Keeps the stored name when the
    // adapter is off (nothing to write to yet) so a later call still can.
    private fun restoreAdapterName() {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val original = prefs.getString(KEY_ORIGINAL_ADAPTER_NAME, null) ?: return
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return
        try {
            if (!adapter.isEnabled) return
            adapter.name = original
            prefs.edit().remove(KEY_ORIGINAL_ADAPTER_NAME).apply()
        } catch (e: SecurityException) {
        }
    }

    private fun emitConnectionEvent(event: Map<String, Any?>) {
        mainHandler.post { connectionSink?.success(event) }
    }
}

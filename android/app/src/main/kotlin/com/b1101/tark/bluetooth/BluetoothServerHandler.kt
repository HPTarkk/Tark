package com.b1101.tark.bluetooth

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.os.Handler
import android.os.Looper
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
 *   requestDiscoverable(durationSeconds) -> bool (whether the system dialog was shown)
 *   startHosting(name)                   -> starts listening; "connected"/"error" events follow on the connection channel
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
    messenger: BinaryMessenger,
    private val activityProvider: () -> Activity?,
) : MethodChannel.MethodCallHandler {

    companion object {
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
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val connectionEvents = EventChannel(messenger, "tark/bluetooth_server/connection")
    private val readEvents = EventChannel(messenger, "tark/bluetooth_server/read")

    private var connectionSink: EventChannel.EventSink? = null
    private var readSink: EventChannel.EventSink? = null

    private var serverSocket: BluetoothServerSocket? = null
    private var acceptThread: Thread? = null
    private var acceptedSocket: BluetoothSocket? = null
    private var readThread: Thread? = null
    private var writerThread: Thread? = null
    private val writeQueue = ArrayBlockingQueue<ByteArray>(WRITE_QUEUE_CAPACITY)

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
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestDiscoverable" -> {
                val seconds = (call.argument<Int>("durationSeconds")) ?: 120
                requestDiscoverable(seconds, result)
            }
            "startHosting" -> {
                val name = call.argument<String>("name") ?: "tark"
                startHosting(name, result)
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
                closeAcceptedSocketOnly()
                result.success(null)
            }
            // Dart needs the API level to decide whether classic discovery
            // requires the legacy fine-location permission (Android <= 11).
            "sdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
            else -> result.notImplemented()
        }
    }

    private fun requestDiscoverable(seconds: Int, result: MethodChannel.Result) {
        val activity = activityProvider()
        if (activity == null) {
            result.success(false)
            return
        }
        try {
            val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, seconds)
            }
            activity.startActivityForResult(intent, REQUEST_DISCOVERABLE_CODE)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun startHosting(name: String, result: MethodChannel.Result) {
        stopHosting()
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            result.error("unsupported", "Bluetooth is not supported on this device", null)
            return
        }
        try {
            serverSocket = adapter.listenUsingInsecureRfcommWithServiceRecord(name, SPP_UUID)
        } catch (e: IOException) {
            result.error("listen_failed", e.message, null)
            return
        } catch (e: SecurityException) {
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
                emitConnectionEvent(mapOf("event" to "error", "message" to (e.message ?: "input stream failed")))
                return@Thread
            }
            while (true) {
                val readCount = try {
                    input.read(buffer)
                } catch (e: IOException) {
                    break
                }
                if (readCount <= 0) break
                val chunk = buffer.copyOf(readCount)
                mainHandler.post { readSink?.success(chunk) }
            }
            emitConnectionEvent(mapOf("event" to "closed"))
        }.also { it.start() }
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
    }

    private fun emitConnectionEvent(event: Map<String, Any?>) {
        mainHandler.post { connectionSink?.success(event) }
    }
}

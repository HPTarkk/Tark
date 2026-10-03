package com.wearemobilefirst.audio_io

/**
 * The audio devices the native library holds for the whole process, past the
 * Flutter engine that opened them.
 */
object AudioIoDevices {
    init {
        System.loadLibrary("audio_io")
    }

    /**
     * Closes every device still open and returns how many were running. For
     * the app's screen going away for good: the Dart side that owned them is
     * shutting down with it, and if the process lives on (a foreground
     * service, a quick reopen) those devices would keep the microphone, so
     * the next session could not open its own.
     */
    @JvmStatic
    external fun releaseAll(): Int
}

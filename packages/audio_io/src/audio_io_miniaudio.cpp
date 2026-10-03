#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <cstring>
#include <cstdlib>
#include <atomic>
#include <mutex>
#include <unordered_set>

#include "double_ring_buffer.h"
#include "voice_playout.h"

#ifdef __ANDROID__
#include <android/log.h>
#include <dlfcn.h>
#include <cstdint>
#include <jni.h>
#endif

const size_t RING_BUFFER_SIZE = 8192;  // power of two — see DoubleRingBuffer
const int SAMPLE_RATE = 48000;
const int CHANNELS = 1;

// Received voice queue: 65536 samples is 1.36 s at 48 kHz, far past anything
// the jump back to live lets it reach.
const size_t VOICE_QUEUE_SIZE = 65536;  // power of two — see VoicePlayout

struct AudioContext {
    ma_device device;
    DoubleRingBuffer* inputRingBuffer;
    // Media (Shared Music) and anything else written through
    // audio_io_write. Received voice has its own queue below; the callback
    // mixes the two.
    DoubleRingBuffer* outputRingBuffer;
    VoicePlayout* voice;
    std::atomic<bool> isRunning;
    std::atomic<bool> isDeviceInitialized;
    double frameDuration;  // Store requested frame duration
    // Held across every open, start, stop and close of [device], so
    // audio_io_release_all can close a device while its owner is shutting
    // down without the two tearing it down at once.
    std::mutex lifecycle;

    AudioContext()
        : inputRingBuffer(new DoubleRingBuffer(RING_BUFFER_SIZE)),
          outputRingBuffer(new DoubleRingBuffer(RING_BUFFER_SIZE)),
          voice(new VoicePlayout(VOICE_QUEUE_SIZE, SAMPLE_RATE)),
          isRunning(false),
          isDeviceInitialized(false),
          frameDuration(0.003) {}  // Default 3ms (Balanced)

    ~AudioContext() {
        delete inputRingBuffer;
        delete outputRingBuffer;
        delete voice;
    }
};

// Realtime audio thread. Nothing in here may allocate, lock, or block —
// every frame has a hard deadline of one period (down to ~2 ms in the
// low-latency profile) and missing it is an audible dropout. The ring
// buffers convert between the device's f32 frames and the doubles the Dart
// side expects during the copy itself, so no staging buffer is needed.
void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    AudioContext* context = (AudioContext*)pDevice->pUserData;

    // Handle input
    if (pInput) {
        context->inputRingBuffer->writeFromFloat((const float*)pInput, frameCount);
    }

    // Handle output: received voice straight from its queue, with whatever
    // the output ring holds (media) mixed on top.
    if (pOutput) {
        float* floatOutput = (float*)pOutput;
        context->voice->render(floatOutput, frameCount);
        context->outputRingBuffer->readAddToFloatClamped(floatOutput, frameCount);
    }
}

// Every context this process has created and not destroyed. The library
// outlives the Flutter engine that loaded it: when Android destroys the app's
// screen but keeps the process (the app swiped away during a call), the Dart
// side that owned a device is gone while its streams keep running and keep
// the microphone. The next engine in the same process then cannot open its
// own device (seen on a Galaxy S8, Android 9: "Failed to start audio device"
// on every retry after reopening the app). This list is how those devices
// get closed. See audio_io_release_all.
static std::mutex g_contextsLock;
static std::unordered_set<AudioContext*> g_contexts;

static AudioContext* track(AudioContext* context) {
    std::lock_guard<std::mutex> guard(g_contextsLock);
    g_contexts.insert(context);
    return context;
}

// Stops and closes the device; the context itself stays valid, so a read,
// write or stop that still arrives for it is harmless.
static void close_device_locked(AudioContext* context) {
    if (context->isRunning) {
        ma_device_stop(&context->device);
        context->isRunning = false;
    }
    if (context->isDeviceInitialized) {
        ma_device_uninit(&context->device);
        context->isDeviceInitialized = false;
    }
}

static int init_device_locked(AudioContext* context);

extern "C" {

void* audio_io_create() {
    // Don't initialize device yet, wait for set_frame_duration
    return track(new AudioContext());
}

void* audio_io_create_with_latency(double frameDuration) {
    AudioContext* context = new AudioContext();
    context->frameDuration = frameDuration;
    return track(context);
}

int audio_io_init_device(void* handle) {
    if (!handle) return -1;
    AudioContext* context = (AudioContext*)handle;
    std::lock_guard<std::mutex> guard(context->lifecycle);
    return init_device_locked(context);
}

// Closes every device this process still has open, and returns how many
// were running. For a new owner of the audio (a fresh Flutter engine) before
// it opens its first device, and for the app's screen going away for good.
// Contexts are not freed: whoever still holds a handle can keep calling into
// it, and gets silence and failed starts rather than a crash.
int audio_io_release_all() {
    std::lock_guard<std::mutex> guard(g_contextsLock);
    int closed = 0;
    for (AudioContext* context : g_contexts) {
        // One its owner is opening or closing right now is still owned, and
        // that call can hang (see device_call_limit.dart): skipped rather
        // than waited on.
        std::unique_lock<std::mutex> device(context->lifecycle, std::try_to_lock);
        if (!device.owns_lock()) continue;
        if (context->isRunning) closed++;
        close_device_locked(context);
    }
    return closed;
}

} // extern "C"

static int init_device_locked(AudioContext* context) {
    
    // Calculate period size in frames based on frame duration
    ma_uint32 periodSizeInFrames = (ma_uint32)(context->frameDuration * SAMPLE_RATE);
    
    // Clamp to reasonable values (64 to 4096 frames)
    if (periodSizeInFrames < 64) periodSizeInFrames = 64;
    if (periodSizeInFrames > 4096) periodSizeInFrames = 4096;
    

    
    ma_device_config config = ma_device_config_init(ma_device_type_duplex);
    config.capture.pDeviceID = NULL;
    config.capture.format = ma_format_f32;
    config.capture.channels = CHANNELS;
    config.capture.shareMode = ma_share_mode_shared;
    config.playback.pDeviceID = NULL;
    config.playback.format = ma_format_f32;
    config.playback.channels = CHANNELS;
    config.playback.shareMode = ma_share_mode_shared;
    config.sampleRate = SAMPLE_RATE;
    config.dataCallback = data_callback;
    config.pUserData = context;
    config.periodSizeInFrames = periodSizeInFrames;
    
    #ifdef __ANDROID__
    // Set performance profile based on latency
    if (context->frameDuration <= 0.002) {
        config.performanceProfile = ma_performance_profile_low_latency;
    } else if (context->frameDuration <= 0.004) {
        config.performanceProfile = ma_performance_profile_conservative;
    } else {
        config.performanceProfile = ma_performance_profile_low_latency;  // Still prefer low latency
    }
    // Voice-communication class streams (VoIP), NOT media. Android's
    // routing engine only carries communication streams over Bluetooth
    // SCO/handsfree — media streams keep playing on the phone speaker when
    // the app enters call mode (and A2DP gets suspended there), which made
    // headset use impossible. This also enables the platform's hardware
    // echo cancellation / AGC on the capture path.
    config.aaudio.usage = ma_aaudio_usage_voice_communication;
    config.aaudio.contentType = ma_aaudio_content_type_speech;
    config.aaudio.inputPreset = ma_aaudio_input_preset_voice_communication;
    config.opensl.streamType = ma_opensl_stream_type_voice;
    config.opensl.recordingPreset = ma_opensl_recording_preset_voice_communication;
    config.periods = 2;  // Use double buffering
    #endif
    
    if (ma_device_init(NULL, &config, &context->device) != MA_SUCCESS) {
        return -1;
    }
    // Before start, while the callback cannot be running.
    context->voice->configure((int)context->device.sampleRate);
    
    context->isDeviceInitialized = true;
    

    
    return 0;
}

extern "C" {

void audio_io_destroy(void* handle) {
    if (!handle) return;
    
    AudioContext* context = (AudioContext*)handle;
    {
        // Out of the list first, so audio_io_release_all can't reach it
        // while it is being freed.
        std::lock_guard<std::mutex> guard(g_contextsLock);
        g_contexts.erase(context);
    }
    {
        std::lock_guard<std::mutex> guard(context->lifecycle);
        close_device_locked(context);
    }
    delete context;
}

int audio_io_start(void* handle) {
    if (!handle) return -1;
    
    AudioContext* context = (AudioContext*)handle;
    std::lock_guard<std::mutex> guard(context->lifecycle);
    
    if (context->isRunning) return 0;
    
    // Initialize device if not already done
    if (!context->isDeviceInitialized) {
        if (init_device_locked(context) != 0) {
            return -1;
        }
    }
    
    if (ma_device_start(&context->device) != MA_SUCCESS) {
        return -1;
    }

    context->isRunning = true;
    return 0;
}

int audio_io_stop(void* handle) {
    if (!handle) return -1;
    
    AudioContext* context = (AudioContext*)handle;
    std::lock_guard<std::mutex> guard(context->lifecycle);
    
    if (!context->isRunning) return 0;
    
    if (ma_device_stop(&context->device) != MA_SUCCESS) {
        return -1;
    }
    
    context->isRunning = false;
    return 0;
}

int audio_io_read(void* handle, double* buffer, int frameCount) {
    if (!handle || !buffer || frameCount <= 0) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->inputRingBuffer->read(buffer, frameCount);
}

int audio_io_write(void* handle, const double* buffer, int frameCount) {
    if (!handle || !buffer || frameCount <= 0) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->outputRingBuffer->write(buffer, frameCount);
}

// Cumulative frames of received voice the playback callback had to replace
// with silence because the voice queue ran dry mid-pull. Each one is heard as
// a gap, so a value that climbs while someone is talking means the jitter
// target is too shallow for the link.
long long audio_io_get_output_underrun_frames(void* handle) {
    if (!handle) return 0;
    AudioContext* context = (AudioContext*)handle;
    return context->voice->starvedFrames();
}

// ── Received voice queue (see voice_playout.h) ──────────────────────────────

int audio_io_voice_write(void* handle, const double* buffer, int frameCount) {
    if (!handle || !buffer || frameCount <= 0) return 0;
    return (int)((AudioContext*)handle)->voice->write(buffer, (size_t)frameCount);
}

int audio_io_voice_write_zeros(void* handle, int frameCount) {
    if (!handle || frameCount <= 0) return 0;
    return (int)((AudioContext*)handle)->voice->writeZeros((size_t)frameCount);
}

void audio_io_voice_set_target(void* handle, int frames) {
    if (!handle) return;
    ((AudioContext*)handle)->voice->setTarget(frames);
}

void audio_io_voice_reset(void* handle) {
    if (!handle) return;
    ((AudioContext*)handle)->voice->requestReset();
}

// One getter for every counter, so the binding surface stays small. -1 for an
// unknown selector or no device.
long long audio_io_voice_stat(void* handle, int which) {
    if (!handle) return -1;
    VoicePlayout* v = ((AudioContext*)handle)->voice;
    switch (which) {
        case 0: return (long long)v->queued();
        case 1: return v->playing() ? 1 : 0;
        case 2: return v->underruns();
        case 3: return v->starvedFrames();
        case 4: return v->playedFrames();
        case 5: return v->trims();
        case 6: return v->jumps();
        case 7: return (long long)v->burstFrames();
        default: return -1;
    }
}

// Frames written to the output ring that the device has not played yet. The
// Dart drain reads this every tick and tops the ring back up to its cushion,
// so what it writes follows the device's own clock instead of a UI-isolate
// timer that skips ticks whenever a frame runs long.
int audio_io_get_output_queued_frames(void* handle) {
    if (!handle) return -1;
    AudioContext* context = (AudioContext*)handle;
    return (int)context->outputRingBuffer->available_read();
}

int audio_io_get_sample_rate(void* handle) {
    if (!handle) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->device.sampleRate;
}

int audio_io_get_channels(void* handle) {
    return CHANNELS;
}

// Returns the AAudio capture stream's audio session id (>= 0) so the Java
// layer can attach AcousticEchoCanceler / NoiseSuppressor /
// AutomaticGainControl to the mic. Returns -1 when unavailable (not the AAudio
// backend, Android < 8/9, or any non-Android platform) — callers then rely on
// the VOICE_COMMUNICATION preset alone.
int audio_io_get_input_session_id(void* handle) {
#if defined(__ANDROID__) && defined(MA_SUPPORT_AAUDIO)
    if (!handle) return -1;
    AudioContext* context = (AudioContext*)handle;
    std::lock_guard<std::mutex> guard(context->lifecycle);
    if (!context->isDeviceInitialized) return -1;
    if (context->device.pContext == NULL ||
        context->device.pContext->backend != ma_backend_aaudio) {
        return -1;  // OpenSL ES / other backend: no session id to expose.
    }
    typedef int32_t (*PFN_AAudioStream_getSessionId)(void*);
    static PFN_AAudioStream_getSessionId pGetSessionId = NULL;
    static bool resolved = false;
    if (!resolved) {
        resolved = true;
        void* lib = dlopen("libaaudio.so", RTLD_NOW | RTLD_NOLOAD);
        if (lib == NULL) lib = dlopen("libaaudio.so", RTLD_NOW);
        if (lib != NULL) {
            pGetSessionId = (PFN_AAudioStream_getSessionId)dlsym(lib, "AAudioStream_getSessionId");
        }
    }
    if (pGetSessionId == NULL) return -1;

    // Under the reroute lock: the AAudio job thread closes and frees the
    // capture stream when the route changes (Bluetooth SCO coming up right as
    // the session starts), and this is called immediately after start, i.e.
    // squarely inside that window. Reading the pointer unlocked would hand a
    // freed AAudioStream to getSessionId.
    ma_bool32 acquired = ma_reroute_lock__aaudio(&context->device);
    void* captureStream = (void*)context->device.aaudio.pStreamCapture;
    const int sessionId = (captureStream != NULL) ? (int)pGetSessionId(captureStream) : -1;
    ma_reroute_unlock__aaudio(&context->device, acquired);

    return sessionId;
#else
    (void)handle;
    return -1;
#endif
}

int audio_io_get_available_read_frames(void* handle) {
    if (!handle) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->inputRingBuffer->available_read();
}

int audio_io_get_available_write_space(void* handle) {
    if (!handle) return 0;
    
    AudioContext* context = (AudioContext*)handle;
    return context->outputRingBuffer->available_write();
}

int audio_io_set_frame_duration(void* handle, double duration) {
    if (!handle) return -1;
    
    AudioContext* context = (AudioContext*)handle;
    std::lock_guard<std::mutex> guard(context->lifecycle);
    
    // Store the new frame duration
    context->frameDuration = duration;
    
    // If device is running, we need to restart it with new buffer size
    if (context->isRunning) {
        // Stop the device
        ma_device_stop(&context->device);
        context->isRunning = false;
        
        // Uninitialize the device
        if (context->isDeviceInitialized) {
            ma_device_uninit(&context->device);
            context->isDeviceInitialized = false;
        }
        
        // Re-initialize with new settings
        if (init_device_locked(context) != 0) {
            return -1;
        }
        
        // Restart the device
        if (ma_device_start(&context->device) != MA_SUCCESS) {
            return -1;
        }
        context->isRunning = true;
    } else {
        // If device is already initialized but not running, uninitialize it
        if (context->isDeviceInitialized) {
            ma_device_uninit(&context->device);
            context->isDeviceInitialized = false;
        }
    }
    
    return 0;
}

double audio_io_get_frame_duration(void* handle) {
    if (!handle) return 0.003;  // Return default if handle is null
    
    AudioContext* context = (AudioContext*)handle;
    
    // If device is initialized, return actual period size
    if (context->isDeviceInitialized && context->isRunning) {
        // Get actual buffer size from device
        ma_uint32 actualBufferSize = context->device.playback.internalPeriodSizeInFrames;
        if (actualBufferSize > 0) {
            return (double)actualBufferSize / (double)context->device.sampleRate;
        }
    }
    
    // Return configured value
    return context->frameDuration;
}

} // extern "C"

#ifdef __ANDROID__
// For MainActivity.onDestroy, through AudioIoDevices.releaseAll: the screen
// is gone for good, so is the Dart side that owned these devices, and the
// microphone should not stay on in a process nobody can see.
extern "C" JNIEXPORT jint JNICALL
Java_com_wearemobilefirst_audio_1io_AudioIoDevices_releaseAll(JNIEnv*, jclass) {
    return (jint)audio_io_release_all();
}
#endif

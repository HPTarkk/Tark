#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <cstring>
#include <cstdlib>
#include <atomic>

#include "double_ring_buffer.h"

#ifdef __ANDROID__
#include <android/log.h>
#include <dlfcn.h>
#include <cstdint>
#endif

const size_t RING_BUFFER_SIZE = 8192;  // power of two — see DoubleRingBuffer
const int SAMPLE_RATE = 48000;
const int CHANNELS = 1;

struct AudioContext {
    ma_device device;
    DoubleRingBuffer* inputRingBuffer;
    DoubleRingBuffer* outputRingBuffer;
    std::atomic<bool> isRunning;
    std::atomic<bool> isDeviceInitialized;
    double frameDuration;  // Store requested frame duration

    // Frames the playback callback had to invent because the output ring was
    // empty. Every one of them is a step to silence in the middle of a
    // waveform — i.e. an audible tick — so this is the number that says
    // whether the Dart side is feeding the device fast enough. Exposed via
    // audio_io_get_output_underrun_frames() and logged with the jitter
    // buffer's stats; it is a diagnostic, not something the audio path reads.
    std::atomic<long long> outputUnderrunFrames;

    AudioContext()
        : inputRingBuffer(new DoubleRingBuffer(RING_BUFFER_SIZE)),
          outputRingBuffer(new DoubleRingBuffer(RING_BUFFER_SIZE)),
          isRunning(false),
          isDeviceInitialized(false),
          frameDuration(0.003),  // Default 3ms (Balanced)
          outputUnderrunFrames(0) {}
    
    ~AudioContext() {
        delete inputRingBuffer;
        delete outputRingBuffer;
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

    // Handle output
    if (pOutput) {
        float* floatOutput = (float*)pOutput;
        const size_t framesRead =
            context->outputRingBuffer->readToFloatClamped(floatOutput, frameCount);
        // Underrun: silence whatever the ring could not supply.
        if (framesRead < frameCount) {
            std::memset(floatOutput + framesRead, 0,
                        (frameCount - framesRead) * sizeof(float));
            context->outputUnderrunFrames.fetch_add(
                (long long)(frameCount - framesRead), std::memory_order_relaxed);
        }
    }
}

extern "C" {

void* audio_io_create() {

    AudioContext* context = new AudioContext();
    return context;  // Don't initialize device yet, wait for set_frame_duration
}

void* audio_io_create_with_latency(double frameDuration) {
    AudioContext* context = new AudioContext();
    context->frameDuration = frameDuration;
    return context;
}

int audio_io_init_device(void* handle) {
    if (!handle) return -1;
    
    AudioContext* context = (AudioContext*)handle;
    
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
    
    context->isDeviceInitialized = true;
    

    
    return 0;
}

void audio_io_destroy(void* handle) {
    if (!handle) return;
    
    AudioContext* context = (AudioContext*)handle;
    
    if (context->isRunning) {
        ma_device_stop(&context->device);
    }
    
    if (context->isDeviceInitialized) {
        ma_device_uninit(&context->device);
    }
    delete context;
}

int audio_io_start(void* handle) {
    if (!handle) return -1;
    
    AudioContext* context = (AudioContext*)handle;
    
    if (context->isRunning) return 0;
    
    // Initialize device if not already done
    if (!context->isDeviceInitialized) {
        if (audio_io_init_device(handle) != 0) {
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

// Cumulative frames the playback callback had to fill with silence because the
// output ring was empty. A steadily climbing value means the Dart drain is not
// staying ahead of the device — each underrun is an audible tick.
long long audio_io_get_output_underrun_frames(void* handle) {
    if (!handle) return 0;
    AudioContext* context = (AudioContext*)handle;
    return context->outputUnderrunFrames.load(std::memory_order_relaxed);
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
        if (audio_io_init_device(handle) != 0) {
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
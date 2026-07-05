#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <atomic>
#include <vector>

#ifdef __ANDROID__
#include <android/log.h>
#include <dlfcn.h>
#include <cstdint>
#endif

const int RING_BUFFER_SIZE = 8192;
const int SAMPLE_RATE = 48000;
const int CHANNELS = 1;

// Simple ring buffer implementation for doubles
class DoubleRingBuffer {
private:
    std::vector<double> buffer;
    size_t writePos;
    size_t readPos;
    size_t size;
    std::mutex mutex;
    
public:
    DoubleRingBuffer(size_t bufferSize) 
        : buffer(bufferSize), writePos(0), readPos(0), size(bufferSize) {}
    
    size_t write(const double* data, size_t count) {
        std::lock_guard<std::mutex> lock(mutex);
        size_t written = 0;
        for (size_t i = 0; i < count && available_write() > 0; i++) {
            buffer[writePos] = data[i];
            writePos = (writePos + 1) % size;
            written++;
        }
        return written;
    }
    
    size_t read(double* data, size_t count) {
        std::lock_guard<std::mutex> lock(mutex);
        size_t readCount = 0;
        for (size_t i = 0; i < count && available_read() > 0; i++) {
            data[i] = buffer[readPos];
            readPos = (readPos + 1) % size;
            readCount++;
        }
        return readCount;
    }
    
    size_t available_read() const {
        if (writePos >= readPos) {
            return writePos - readPos;
        }
        return size - readPos + writePos;
    }
    
    size_t available_write() const {
        return size - available_read() - 1;
    }
};

struct AudioContext {
    ma_device device;
    DoubleRingBuffer* inputRingBuffer;
    DoubleRingBuffer* outputRingBuffer;
    std::atomic<bool> isRunning;
    std::atomic<bool> isDeviceInitialized;
    double frameDuration;  // Store requested frame duration
    
    AudioContext() 
        : inputRingBuffer(new DoubleRingBuffer(RING_BUFFER_SIZE)),
          outputRingBuffer(new DoubleRingBuffer(RING_BUFFER_SIZE)),
          isRunning(false),
          isDeviceInitialized(false),
          frameDuration(0.003) {}  // Default 3ms (Balanced)
    
    ~AudioContext() {
        delete inputRingBuffer;
        delete outputRingBuffer;
    }
};

void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    AudioContext* context = (AudioContext*)pDevice->pUserData;
    
    // Handle input
    if (pInput) {
        float* floatInput = (float*)pInput;
        std::vector<double> tempBuffer(frameCount);
        for (ma_uint32 i = 0; i < frameCount; i++) {
            tempBuffer[i] = (double)floatInput[i];
        }
        context->inputRingBuffer->write(tempBuffer.data(), frameCount);
    }
    
    // Handle output
    if (pOutput) {
        float* floatOutput = (float*)pOutput;
        std::vector<double> tempBuffer(frameCount);
        size_t framesRead = context->outputRingBuffer->read(tempBuffer.data(), frameCount);
        
        for (ma_uint32 i = 0; i < frameCount; i++) {
            if (i < framesRead) {
                double sample = tempBuffer[i];
                // Clamp to [-1.0, 1.0] to prevent clipping
                if (sample > 1.0) sample = 1.0;
                else if (sample < -1.0) sample = -1.0;
                floatOutput[i] = (float)sample;
            } else {
                floatOutput[i] = 0.0f;
            }
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
    void* captureStream = (void*)context->device.aaudio.pStreamCapture;
    if (captureStream == NULL) return -1;

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
    return (int)pGetSessionId(captureStream);
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
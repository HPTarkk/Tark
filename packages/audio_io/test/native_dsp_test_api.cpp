#include <cstdint>
#include <cstdlib>
#include <new>

// Test one real allocation failure inside the exported production DSP call,
// without requesting a huge buffer or changing the production allocator.
static bool fail_next_allocation = false;
void* operator new(std::size_t size) {
  if (fail_next_allocation) {
    fail_next_allocation = false;
    throw std::bad_alloc();
  }
  if (void* value = std::malloc(size == 0 ? 1 : size)) return value;
  throw std::bad_alloc();
}
void operator delete(void* value) noexcept { std::free(value); }
void operator delete(void* value, std::size_t) noexcept { std::free(value); }

#ifdef _WIN32
#define AUDIO_IO_DSP_EXPORT __declspec(dllexport)
#else
#define AUDIO_IO_DSP_EXPORT __attribute__((visibility("default")))
#endif

static int live_handles = 0;
static int create_counts[3] = {};
static int destroy_counts[3] = {};
#define AUDIO_IO_DSP_HANDLE_CREATED(kind) (++live_handles, ++create_counts[kind])
#define AUDIO_IO_DSP_HANDLE_DESTROYED(kind) (--live_handles, ++destroy_counts[kind])
#include "../src/realtime_dsp_api.h"

extern "C" AUDIO_IO_DSP_EXPORT int32_t audio_io_test_live_handles() {
  return live_handles;
}
extern "C" AUDIO_IO_DSP_EXPORT void audio_io_test_fail_next_allocation() {
  fail_next_allocation = true;
}
extern "C" AUDIO_IO_DSP_EXPORT int32_t audio_io_test_create_count(int32_t kind) {
  return kind >= 0 && kind < 3 ? create_counts[kind] : 0;
}
extern "C" AUDIO_IO_DSP_EXPORT int32_t audio_io_test_destroy_count(int32_t kind) {
  return kind >= 0 && kind < 3 ? destroy_counts[kind] : 0;
}

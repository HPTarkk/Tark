#ifndef RNNOISE_STREAM_H
#define RNNOISE_STREAM_H

#include "rnnoise.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque, single-stream owner of RNNoise and its sample-rate conversion state.
 * Samples at this boundary are normalized doubles. These functions are optional
 * additions to the frame API; older binaries continue to support that API. */
RNNOISE_EXPORT void *rnnoise_stream_create(int sample_rate);
RNNOISE_EXPORT void rnnoise_stream_destroy(void *stream);
/* Returns count on success, -1 for an invalid call/allocation failure. Exactly
 * count output samples are written on success, including during startup. */
RNNOISE_EXPORT int rnnoise_stream_process(void *stream, const double *input,
                                        double *output, int count,
                                        double strength);
/* Returns 0 on success and -1 on allocation failure. Clears both streaming and
 * recurrent model history, equivalent to destroying and recreating a stream. */
RNNOISE_EXPORT int rnnoise_stream_reset(void *stream);

#ifdef __cplusplus
}
#endif

#endif

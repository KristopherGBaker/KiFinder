#ifndef KION_ORT_SHIM_H
#define KION_ORT_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *KionORTSessionHandle;

int KionORTCreate(
    const char *runtime_path,
    const char *model_path,
    KionORTSessionHandle *handle,
    char *error_buffer,
    size_t error_buffer_length
);

int KionORTRun(
    KionORTSessionHandle handle,
    const float *input,
    size_t input_count,
    float *output,
    size_t output_count,
    char *error_buffer,
    size_t error_buffer_length
);

void KionORTDestroy(KionORTSessionHandle handle);

#ifdef __cplusplus
}
#endif

#endif

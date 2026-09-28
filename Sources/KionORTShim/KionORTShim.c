#include "KionORTShim.h"

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct OrtApi OrtApi;
typedef struct OrtApiBase OrtApiBase;
typedef struct OrtEnv OrtEnv;
typedef struct OrtMemoryInfo OrtMemoryInfo;
typedef struct OrtSession OrtSession;
typedef struct OrtSessionOptions OrtSessionOptions;
typedef struct OrtStatus OrtStatus;
typedef struct OrtValue OrtValue;

typedef const OrtApi *(*OrtGetApiFn)(uint32_t version);
typedef const char *(*OrtGetVersionStringFn)(void);

struct OrtApiBase {
    OrtGetApiFn GetApi;
    OrtGetVersionStringFn GetVersionString;
};

typedef const OrtApiBase *(*OrtGetApiBaseFn)(void);

enum {
    KionORTAPIVersion = 23,
    KionORTLoggingWarning = 2,
    KionORTGraphOptimizationAll = 99,
    KionORTArenaAllocator = 1,
    KionORTMemTypeDefault = 0,
    KionONNXTensorElementDataTypeFloat = 1
};

// The vendored dylib is pinned to 1.27.0 (Scripts/bootstrap-vendor.sh); every
// vtable slot index below was derived by counting fields in that version's
// `OrtApi` struct. ORT's C API is append-only across releases (existing slots
// never move), but a major bump could still insert/reorder — gate on the
// prefix so a mismatch fails loudly instead of calling the wrong function
// pointer through a stale index.
static const char *const KionORTExpectedVersionPrefix = "1.27.";

typedef OrtStatus *(*KionCreateEnvFn)(int, const char *, OrtEnv **);
typedef const char *(*KionGetErrorMessageFn)(const OrtStatus *);
typedef OrtStatus *(*KionCreateSessionFn)(const OrtEnv *, const char *, const OrtSessionOptions *, OrtSession **);
typedef OrtStatus *(*KionRunFn)(
    OrtSession *,
    const void *,
    const char *const *,
    const OrtValue *const *,
    size_t,
    const char *const *,
    size_t,
    OrtValue **
);
typedef OrtStatus *(*KionCreateSessionOptionsFn)(OrtSessionOptions **);
typedef OrtStatus *(*KionSetSessionGraphOptimizationLevelFn)(OrtSessionOptions *, int);
typedef OrtStatus *(*KionCreateTensorWithDataAsOrtValueFn)(
    const OrtMemoryInfo *,
    void *,
    size_t,
    const int64_t *,
    size_t,
    int,
    OrtValue **
);
typedef OrtStatus *(*KionGetTensorMutableDataFn)(OrtValue *, void **);
typedef OrtStatus *(*KionCreateMemoryInfoFn)(const char *, int, int, int, OrtMemoryInfo **);
typedef void (*KionReleaseValueFn)(OrtValue *);
typedef void (*KionReleaseStatusFn)(OrtStatus *);
typedef void (*KionReleaseSessionFn)(OrtSession *);
typedef void (*KionReleaseEnvFn)(OrtEnv *);
typedef void (*KionReleaseMemoryInfoFn)(OrtMemoryInfo *);

struct KionORTSession {
    void *library;
    const OrtApi *api;
    KionGetErrorMessageFn get_error_message;
    KionCreateTensorWithDataAsOrtValueFn create_tensor;
    KionGetTensorMutableDataFn get_tensor_data;
    KionCreateMemoryInfoFn create_memory_info;
    KionRunFn run;
    KionReleaseValueFn release_value;
    KionReleaseStatusFn release_status;
    KionReleaseSessionFn release_session;
    KionReleaseEnvFn release_env;
    KionReleaseMemoryInfoFn release_memory_info;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory_info;
};

static void kion_set_error(char *buffer, size_t length, const char *message) {
    if (buffer == NULL || length == 0) {
        return;
    }
    if (message == NULL) {
        message = "unknown ONNX Runtime error";
    }
    snprintf(buffer, length, "%s", message);
}

static void *kion_api_slot(const OrtApi *api, size_t index) {
    const void *const *slots = (const void *const *)api;
    return (void *)slots[index];
}

// Fails with a message naming the missing function rather than letting a NULL
// slot be cast to a function pointer and called (undefined behavior).
static int kion_require_slot(
    const void *slot,
    const char *name,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (slot != NULL) {
        return 0;
    }
    char message[192];
    snprintf(message, sizeof message, "ONNX Runtime API is missing required function: %s", name);
    kion_set_error(error_buffer, error_buffer_length, message);
    return 1;
}

static int kion_check_status(
    struct KionORTSession *state,
    OrtStatus *status,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (status == NULL) {
        return 0;
    }
    const char *message = state != NULL && state->get_error_message != NULL
        ? state->get_error_message(status)
        : "ONNX Runtime call failed";
    kion_set_error(error_buffer, error_buffer_length, message);
    if (state != NULL && state->release_status != NULL) {
        state->release_status(status);
    }
    return 1;
}

int KionORTCreate(
    const char *runtime_path,
    const char *model_path,
    KionORTSessionHandle *handle,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (runtime_path == NULL || model_path == NULL || handle == NULL) {
        kion_set_error(error_buffer, error_buffer_length, "invalid ONNX Runtime creation arguments");
        return 1;
    }

    struct KionORTSession *state = calloc(1, sizeof(struct KionORTSession));
    if (state == NULL) {
        kion_set_error(error_buffer, error_buffer_length, "failed to allocate ONNX Runtime state");
        return 1;
    }

    state->library = dlopen(runtime_path, RTLD_NOW | RTLD_LOCAL);
    if (state->library == NULL) {
        kion_set_error(error_buffer, error_buffer_length, dlerror());
        free(state);
        return 1;
    }

    OrtGetApiBaseFn get_api_base = (OrtGetApiBaseFn)dlsym(state->library, "OrtGetApiBase");
    if (get_api_base == NULL) {
        kion_set_error(error_buffer, error_buffer_length, "OrtGetApiBase not found");
        KionORTDestroy(state);
        return 1;
    }

    const OrtApiBase *api_base = get_api_base();

    // Gate on the runtime's own version string BEFORE deriving anything from
    // the vtable — the hardcoded slot indices below are only valid for the
    // 1.27.x layout they were counted against.
    const char *version_string = api_base != NULL && api_base->GetVersionString != NULL
        ? api_base->GetVersionString()
        : NULL;
    if (version_string == NULL || strncmp(version_string, KionORTExpectedVersionPrefix, strlen(KionORTExpectedVersionPrefix)) != 0) {
        char message[256];
        snprintf(
            message,
            sizeof message,
            "unsupported ONNX Runtime version: expected %sx, found %s",
            KionORTExpectedVersionPrefix,
            version_string != NULL ? version_string : "unknown"
        );
        kion_set_error(error_buffer, error_buffer_length, message);
        KionORTDestroy(state);
        return 1;
    }

    state->api = api_base->GetApi(KionORTAPIVersion);
    if (state->api == NULL) {
        kion_set_error(error_buffer, error_buffer_length, "ONNX Runtime API version unavailable");
        KionORTDestroy(state);
        return 1;
    }

    // Slot indices below are counted fields of `OrtApi` (onnxruntime_c_api.h) at
    // the pinned 1.27.0 layout gated above.
    void *slot_get_error_message = kion_api_slot(state->api, 2); // GetErrorMessage
    void *slot_create_env = kion_api_slot(state->api, 3); // CreateEnv
    void *slot_create_session = kion_api_slot(state->api, 7); // CreateSession
    void *slot_run = kion_api_slot(state->api, 9); // Run
    void *slot_create_session_options = kion_api_slot(state->api, 10); // CreateSessionOptions
    void *slot_set_graph_optimization_level = kion_api_slot(state->api, 23); // SetSessionGraphOptimizationLevel
    void *slot_create_tensor = kion_api_slot(state->api, 49); // CreateTensorWithDataAsOrtValue
    void *slot_get_tensor_data = kion_api_slot(state->api, 51); // GetTensorMutableData
    void *slot_create_memory_info = kion_api_slot(state->api, 68); // CreateMemoryInfo
    void *slot_release_env = kion_api_slot(state->api, 92); // ReleaseEnv
    void *slot_release_status = kion_api_slot(state->api, 93); // ReleaseStatus
    void *slot_release_memory_info = kion_api_slot(state->api, 94); // ReleaseMemoryInfo
    void *slot_release_session = kion_api_slot(state->api, 95); // ReleaseSession
    void *slot_release_value = kion_api_slot(state->api, 96); // ReleaseValue

    struct {
        const void *slot;
        const char *name;
    } required_slots[] = {
        {slot_get_error_message, "GetErrorMessage"},
        {slot_create_env, "CreateEnv"},
        {slot_create_session, "CreateSession"},
        {slot_run, "Run"},
        {slot_create_session_options, "CreateSessionOptions"},
        {slot_set_graph_optimization_level, "SetSessionGraphOptimizationLevel"},
        {slot_create_tensor, "CreateTensorWithDataAsOrtValue"},
        {slot_get_tensor_data, "GetTensorMutableData"},
        {slot_create_memory_info, "CreateMemoryInfo"},
        {slot_release_env, "ReleaseEnv"},
        {slot_release_status, "ReleaseStatus"},
        {slot_release_memory_info, "ReleaseMemoryInfo"},
        {slot_release_session, "ReleaseSession"},
        {slot_release_value, "ReleaseValue"},
    };
    for (size_t i = 0; i < sizeof(required_slots) / sizeof(required_slots[0]); i++) {
        if (kion_require_slot(required_slots[i].slot, required_slots[i].name, error_buffer, error_buffer_length)) {
            KionORTDestroy(state);
            return 1;
        }
    }

    KionCreateEnvFn create_env = (KionCreateEnvFn)slot_create_env;
    KionCreateSessionFn create_session = (KionCreateSessionFn)slot_create_session;
    KionCreateSessionOptionsFn create_session_options = (KionCreateSessionOptionsFn)slot_create_session_options;
    KionSetSessionGraphOptimizationLevelFn set_graph_optimization_level =
        (KionSetSessionGraphOptimizationLevelFn)slot_set_graph_optimization_level;
    state->run = (KionRunFn)slot_run;
    state->create_tensor = (KionCreateTensorWithDataAsOrtValueFn)slot_create_tensor;
    state->get_tensor_data = (KionGetTensorMutableDataFn)slot_get_tensor_data;
    state->create_memory_info = (KionCreateMemoryInfoFn)slot_create_memory_info;
    state->get_error_message = (KionGetErrorMessageFn)slot_get_error_message;
    state->release_value = (KionReleaseValueFn)slot_release_value;
    state->release_status = (KionReleaseStatusFn)slot_release_status;
    state->release_session = (KionReleaseSessionFn)slot_release_session;
    state->release_env = (KionReleaseEnvFn)slot_release_env;
    state->release_memory_info = (KionReleaseMemoryInfoFn)slot_release_memory_info;

    if (kion_check_status(state, create_env(KionORTLoggingWarning, "KionEngine", &state->env), error_buffer, error_buffer_length)) {
        KionORTDestroy(state);
        return 1;
    }

    OrtSessionOptions *options = NULL;
    if (kion_check_status(state, create_session_options(&options), error_buffer, error_buffer_length)) {
        KionORTDestroy(state);
        return 1;
    }

    OrtStatus *optimization_status = set_graph_optimization_level(options, KionORTGraphOptimizationAll);
    if (kion_check_status(state, optimization_status, error_buffer, error_buffer_length)) {
        KionORTDestroy(state);
        return 1;
    }

    // Intentionally run ArcFace on the default CPU execution provider rather than
    // appending CoreML. The CPU provider is ONNX Runtime's reference implementation
    // for this ResNet100 graph; the CoreML provider was observed to produce
    // low-variance, near-collapsed embeddings (cosine ~0.98 between distinct
    // identities), which destroys the identity discrimination the matcher relies on.
    // Running on CPU yields the correct, well-separated ArcFace embeddings.

    if (kion_check_status(state, create_session(state->env, model_path, options, &state->session), error_buffer, error_buffer_length)) {
        KionORTDestroy(state);
        return 1;
    }

    OrtStatus *memory_status = state->create_memory_info(
        "Cpu",
        KionORTArenaAllocator,
        0,
        KionORTMemTypeDefault,
        &state->memory_info
    );
    if (kion_check_status(state, memory_status, error_buffer, error_buffer_length)) {
        KionORTDestroy(state);
        return 1;
    }

    *handle = state;
    return 0;
}

int KionORTRun(
    KionORTSessionHandle handle,
    const float *input,
    size_t input_count,
    float *output,
    size_t output_count,
    char *error_buffer,
    size_t error_buffer_length
) {
    struct KionORTSession *state = (struct KionORTSession *)handle;
    if (state == NULL || input == NULL || output == NULL) {
        kion_set_error(error_buffer, error_buffer_length, "invalid ONNX Runtime run arguments");
        return 1;
    }
    if (input_count != 1 * 3 * 112 * 112 || output_count != 512) {
        kion_set_error(error_buffer, error_buffer_length, "unexpected ArcFace tensor size");
        return 1;
    }

    int result = 0;
    OrtValue *input_value = NULL;
    OrtValue *output_value = NULL;
    int64_t input_shape[4] = {1, 3, 112, 112};
    const char *input_names[1] = {"data"};
    const char *output_names[1] = {"fc1"};
    void *output_data = NULL;
    OrtStatus *tensor_status = NULL;
    OrtStatus *run_status = NULL;
    OrtStatus *data_status = NULL;

    tensor_status = state->create_tensor(
        state->memory_info,
        (void *)input,
        input_count * sizeof(float),
        input_shape,
        4,
        KionONNXTensorElementDataTypeFloat,
        &input_value
    );
    if (kion_check_status(state, tensor_status, error_buffer, error_buffer_length)) {
        result = 1;
        goto cleanup;
    }

    run_status = state->run(
        state->session,
        NULL,
        input_names,
        (const OrtValue *const *)&input_value,
        1,
        output_names,
        1,
        &output_value
    );
    if (kion_check_status(state, run_status, error_buffer, error_buffer_length)) {
        result = 1;
        goto cleanup;
    }

    data_status = state->get_tensor_data(output_value, &output_data);
    if (kion_check_status(state, data_status, error_buffer, error_buffer_length)) {
        result = 1;
        goto cleanup;
    }

    // Copy the tensor's data out BEFORE releasing output_value below: releasing
    // frees the buffer ORT allocated for the tensor, so reading through
    // output_data after the release would be a use-after-free.
    memcpy(output, output_data, output_count * sizeof(float));

cleanup:
    // Every exit path past tensor creation (success, run failure, data-extraction
    // failure) converges here so both OrtValues are released exactly once,
    // NULL-safely, regardless of how KionORTRun returns.
    if (output_value != NULL && state->release_value != NULL) {
        state->release_value(output_value);
    }
    if (input_value != NULL && state->release_value != NULL) {
        state->release_value(input_value);
    }
    return result;
}

void KionORTDestroy(KionORTSessionHandle handle) {
    struct KionORTSession *state = (struct KionORTSession *)handle;
    if (state == NULL) {
        return;
    }
    // Tear down ORT-owned resources in dependency order — memory-info and the
    // session both reference the env — before dlclose. ORT sessions own thread
    // pools; unloading the dylib while workers are parked in its code is a
    // crash risk, and skipping this leaks the env/session/memory-info
    // allocations. Every release is NULL-safe so this is also correct when
    // called after a partially-failed KionORTCreate (some fields never set).
    if (state->memory_info != NULL && state->release_memory_info != NULL) {
        state->release_memory_info(state->memory_info);
        state->memory_info = NULL;
    }
    if (state->session != NULL && state->release_session != NULL) {
        state->release_session(state->session);
        state->session = NULL;
    }
    if (state->env != NULL && state->release_env != NULL) {
        state->release_env(state->env);
        state->env = NULL;
    }
    if (state->library != NULL) {
        dlclose(state->library);
    }
    free(state);
}

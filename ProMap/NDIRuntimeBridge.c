#include "NDIRuntimeBridge.h"

#include <dlfcn.h>
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if __has_include(<Processing.NDI.Lib.h>) && __has_include(<Processing.NDI.DynamicLoad.h>)
#include <Processing.NDI.Lib.h>
#include <Processing.NDI.DynamicLoad.h>
#define PROMAP_HAS_NDI_SDK_HEADERS 1
#else
#define PROMAP_HAS_NDI_SDK_HEADERS 0
#endif

#if PROMAP_HAS_NDI_SDK_HEADERS

typedef struct {
    int32_t frameType;
    NDIlib_video_frame_v2_t video;
    NDIlib_audio_frame_v3_t audio;
} ProMapNDIFrameStorage;

static void *gNDILibrary = NULL;
static const NDIlib_v5 *gNDI = NULL;
static int32_t gInitializationStatus = 0;
static ProMapNDISource *gCopiedSources = NULL;
static uint32_t gCopiedSourceCount = 0;

static bool ProMapNDILoadLibrary(void) {
    if (gNDI) return true;
    if (gInitializationStatus != 0) return false;

    static const char *paths[] = {
        "/usr/local/lib/libndi.dylib",
        "/usr/local/lib/libndi.6.dylib",
        "/usr/local/lib/libndi.5.dylib",
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"
    };
    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); ++index) {
        gNDILibrary = dlopen(paths[index], RTLD_NOW | RTLD_LOCAL);
        if (gNDILibrary) break;
    }

    if (!gNDILibrary) {
        gInitializationStatus = -1;
        return false;
    }

    typedef const NDIlib_v5 *(*NDILoadFunction)(void);
    NDILoadFunction loadFunction = (NDILoadFunction)dlsym(gNDILibrary, "NDIlib_v5_load");
    if (!loadFunction) {
        gInitializationStatus = -2;
        return false;
    }

    gNDI = loadFunction();
    if (!gNDI || !gNDI->NDIlib_initialize || !gNDI->NDIlib_initialize()) {
        gInitializationStatus = -3;
        return false;
    }
    gInitializationStatus = 1;
    return true;
}

int32_t ProMapNDIInitialize(void) {
    if (ProMapNDILoadLibrary()) return 1;
    if (gInitializationStatus == 0) gInitializationStatus = -4;
    return gInitializationStatus;
}

const char *ProMapNDIStatusMessage(int32_t status) {
    switch (status) {
        case 1: return "NDI runtime ready";
        case -1: return "NDI runtime not found. Install the NDI SDK runtime and restart ProMap.";
        case -2: return "The NDI runtime is missing its supported v5 compatibility loader. Update the NDI SDK.";
        case -3: return "The NDI runtime could not initialize.";
        case -4: return "NDI could not be initialized.";
        default: return "NDI is unavailable.";
    }
}

void *ProMapNDIFindCreate(void) {
    if (!ProMapNDILoadLibrary() || !gNDI->NDIlib_find_create_v2) return NULL;
    return gNDI->NDIlib_find_create_v2(NULL);
}

void ProMapNDIFindDestroy(void *finder) {
    if (finder && gNDI && gNDI->NDIlib_find_destroy) {
        gNDI->NDIlib_find_destroy((NDIlib_find_instance_t)finder);
    }
}

bool ProMapNDIFindWaitForSources(void *finder, uint32_t timeoutMilliseconds) {
    return finder && gNDI && gNDI->NDIlib_find_wait_for_sources
        ? gNDI->NDIlib_find_wait_for_sources((NDIlib_find_instance_t)finder, timeoutMilliseconds)
        : false;
}

int32_t ProMapNDIFindCopySources(void *finder) {
    ProMapNDIFreeCopiedSources();
    if (!finder || !gNDI || !gNDI->NDIlib_find_get_current_sources) return 0;

    uint32_t sourceCount = 0;
    const NDIlib_source_t *sources = gNDI->NDIlib_find_get_current_sources((NDIlib_find_instance_t)finder, &sourceCount);
    if (!sources || sourceCount == 0) return 0;

    ProMapNDISource *copied = calloc(sourceCount, sizeof(ProMapNDISource));
    if (!copied) return 0;
    for (uint32_t index = 0; index < sourceCount; ++index) {
        const char *sourceName = sources[index].p_ndi_name;
        const char *sourceURL = sources[index].p_url_address;
        copied[index].name = sourceName ? strdup(sourceName) : strdup("");
        copied[index].url = sourceURL ? strdup(sourceURL) : strdup("");
        if (!copied[index].name || !copied[index].url) {
            for (uint32_t freeIndex = 0; freeIndex < sourceCount; ++freeIndex) {
                free(copied[freeIndex].name);
                free(copied[freeIndex].url);
            }
            free(copied);
            return 0;
        }
    }
    gCopiedSources = copied;
    gCopiedSourceCount = sourceCount;
    return (int32_t)sourceCount;
}

const char *ProMapNDIFindSourceNameAt(uint32_t index) {
    return index < gCopiedSourceCount ? gCopiedSources[index].name : NULL;
}

const char *ProMapNDIFindSourceURLAt(uint32_t index) {
    return index < gCopiedSourceCount ? gCopiedSources[index].url : NULL;
}

void ProMapNDIFreeCopiedSources(void) {
    if (!gCopiedSources) return;
    for (uint32_t index = 0; index < gCopiedSourceCount; ++index) {
        free(gCopiedSources[index].name);
        free(gCopiedSources[index].url);
    }
    free(gCopiedSources);
    gCopiedSources = NULL;
    gCopiedSourceCount = 0;
}

void *ProMapNDIReceiverCreate(const char *name, const char *url, int32_t bandwidth) {
    if (!name || !gNDI || !gNDI->NDIlib_recv_create_v3) return NULL;
    NDIlib_recv_create_v3_t settings = {0};
    settings.source_to_connect_to.p_ndi_name = name;
    settings.source_to_connect_to.p_url_address = url;
    settings.color_format = NDIlib_recv_color_format_BGRX_BGRA;
    settings.bandwidth = bandwidth == 0 ? NDIlib_recv_bandwidth_lowest : NDIlib_recv_bandwidth_highest;
    settings.allow_video_fields = false;
    settings.p_ndi_name = "ProMap NDI Input";
    return gNDI->NDIlib_recv_create_v3(&settings);
}

int32_t ProMapNDIReceiverCapture(void *receiver, ProMapNDIVideoFrame *videoOutput, ProMapNDIAudioFrame *audioOutput, void **frameHandle, uint32_t timeoutMilliseconds) {
    if (frameHandle) *frameHandle = NULL;
    if (!receiver || !videoOutput || !audioOutput || !frameHandle || !gNDI || !gNDI->NDIlib_recv_capture_v3) return -1;
    memset(videoOutput, 0, sizeof(*videoOutput));
    memset(audioOutput, 0, sizeof(*audioOutput));

    ProMapNDIFrameStorage *storage = calloc(1, sizeof(ProMapNDIFrameStorage));
    if (!storage) return -1;
    NDIlib_frame_type_e result = gNDI->NDIlib_recv_capture_v3(
        (NDIlib_recv_instance_t)receiver,
        &storage->video,
        &storage->audio,
        NULL,
        timeoutMilliseconds
    );

    if (result == NDIlib_frame_type_video) {
        storage->frameType = (int32_t)result;
        videoOutput->width = storage->video.xres;
        videoOutput->height = storage->video.yres;
        videoOutput->stride = storage->video.line_stride_in_bytes;
        videoOutput->frameRateNumerator = storage->video.frame_rate_N;
        videoOutput->frameRateDenominator = storage->video.frame_rate_D;
        videoOutput->fourCC = (uint32_t)storage->video.FourCC;
        videoOutput->data = storage->video.p_data;
        videoOutput->hasAlpha = storage->video.FourCC == NDIlib_FourCC_type_BGRA;
    } else if (result == NDIlib_frame_type_audio) {
        storage->frameType = (int32_t)result;
        audioOutput->sampleRate = storage->audio.sample_rate;
        audioOutput->channelCount = storage->audio.no_channels;
        audioOutput->sampleCount = storage->audio.no_samples;
        audioOutput->channelStride = storage->audio.channel_stride_in_bytes;
        audioOutput->fourCC = (uint32_t)storage->audio.FourCC;
        audioOutput->data = storage->audio.p_data;
        audioOutput->isFloatPlanar = storage->audio.FourCC == NDIlib_FourCC_type_FLTP;
    } else {
        free(storage);
        return (int32_t)result;
    }
    *frameHandle = storage;
    return (int32_t)result;
}

void ProMapNDIReceiverFreeFrame(void *receiver, void *frameHandle) {
    ProMapNDIFrameStorage *storage = frameHandle;
    if (!storage) return;
    if (receiver && gNDI) {
        if (storage->frameType == NDIlib_frame_type_video && gNDI->NDIlib_recv_free_video_v2) {
            gNDI->NDIlib_recv_free_video_v2((NDIlib_recv_instance_t)receiver, &storage->video);
        } else if (storage->frameType == NDIlib_frame_type_audio && gNDI->NDIlib_recv_free_audio_v3) {
            gNDI->NDIlib_recv_free_audio_v3((NDIlib_recv_instance_t)receiver, &storage->audio);
        }
    }
    free(storage);
}

void ProMapNDIReceiverDestroy(void *receiver) {
    if (receiver && gNDI && gNDI->NDIlib_recv_destroy) {
        gNDI->NDIlib_recv_destroy((NDIlib_recv_instance_t)receiver);
    }
}

bool ProMapNDISendAvailable(void) {
    return ProMapNDILoadLibrary() && gNDI->NDIlib_send_create
        && gNDI->NDIlib_send_send_video_v2 && gNDI->NDIlib_send_destroy;
}

void *ProMapNDISendCreate(const char *name) {
    if (!name || !ProMapNDISendAvailable()) return NULL;
    NDIlib_send_create_t settings = {0};
    settings.p_ndi_name = name;
    settings.p_groups = NULL;
    settings.clock_video = false;
    settings.clock_audio = false;
    return gNDI->NDIlib_send_create(&settings);
}

bool ProMapNDISendVideoFrame(void *sender, int32_t width, int32_t height, int32_t frameRateNumerator, int32_t frameRateDenominator, const uint8_t *bgraData) {
    if (!sender || !bgraData || width <= 0 || height <= 0 || (width & 1) != 0
        || width > INT_MAX / 4 || frameRateNumerator <= 0 || frameRateDenominator <= 0
        || !ProMapNDISendAvailable()) return false;
    NDIlib_video_frame_v2_t frame = {0};
    frame.xres = width;
    frame.yres = height;
    frame.FourCC = NDIlib_FourCC_type_BGRA;
    frame.frame_rate_N = frameRateNumerator;
    frame.frame_rate_D = frameRateDenominator;
    frame.picture_aspect_ratio = (float)width / (float)height;
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = NDIlib_send_timecode_synthesize;
    frame.p_data = (uint8_t *)bgraData;
    frame.line_stride_in_bytes = width * 4;
    frame.p_metadata = NULL;
    gNDI->NDIlib_send_send_video_v2((NDIlib_send_instance_t)sender, &frame);
    return true;
}

void ProMapNDISendDestroy(void *sender) {
    if (sender && gNDI && gNDI->NDIlib_send_destroy) {
        gNDI->NDIlib_send_destroy((NDIlib_send_instance_t)sender);
    }
}

#elif defined(__APPLE__)


// The macOS NDI runtime exports the public C entry points as well as the
// optional NDIlib_v5_load function table. Binding the C entry points here
// keeps NDI usable when the runtime is installed but the SDK headers are not.
typedef struct {
    const char *name;
    const char *url;
} ProMapNDIRuntimeSource;

typedef struct {
    int32_t width;
    int32_t height;
    int32_t fourCC;
    int32_t frameRateNumerator;
    int32_t frameRateDenominator;
    float pictureAspectRatio;
    int32_t frameFormat;
    int64_t timecode;
    uint8_t *data;
    int32_t stride;
    const char *metadata;
    int64_t timestamp;
} ProMapNDIRuntimeVideoFrame;

typedef struct {
    int32_t sampleRate;
    int32_t channelCount;
    int32_t sampleCount;
    int64_t timecode;
    int32_t fourCC;
    uint8_t *data;
    int32_t channelStride;
    const char *metadata;
    int64_t timestamp;
} ProMapNDIRuntimeAudioFrame;

typedef struct {
    ProMapNDIRuntimeSource source;
    int32_t colorFormat;
    int32_t bandwidth;
    bool allowVideoFields;
    const char *receiverName;
} ProMapNDIRuntimeReceiverSettings;

typedef struct {
    const char *name;
    const char *groups;
    bool clockVideo;
    bool clockAudio;
} ProMapNDIRuntimeSendSettings;

_Static_assert(sizeof(ProMapNDIRuntimeSource) == 16, "Unexpected NDI source ABI");
_Static_assert(sizeof(ProMapNDIRuntimeReceiverSettings) == 40, "Unexpected NDI receiver settings ABI");
_Static_assert(sizeof(ProMapNDIRuntimeVideoFrame) == 72, "Unexpected NDI video frame ABI");
_Static_assert(offsetof(ProMapNDIRuntimeVideoFrame, data) == 40, "Unexpected NDI video frame data offset");
_Static_assert(sizeof(ProMapNDIRuntimeAudioFrame) == 64, "Unexpected NDI audio frame ABI");
_Static_assert(offsetof(ProMapNDIRuntimeAudioFrame, data) == 32, "Unexpected NDI audio frame data offset");
_Static_assert(sizeof(ProMapNDIRuntimeSendSettings) == 24, "Unexpected NDI sender settings ABI");

typedef bool (*ProMapNDIInitializeFunction)(void);
typedef void *(*ProMapNDIFindCreateFunction)(const void *settings);
typedef void (*ProMapNDIFindDestroyFunction)(void *finder);
typedef bool (*ProMapNDIFindWaitFunction)(void *finder, uint32_t timeoutMilliseconds);
typedef const ProMapNDIRuntimeSource *(*ProMapNDIFindSourcesFunction)(void *finder, uint32_t *sourceCount);
typedef void *(*ProMapNDIReceiverCreateFunction)(const ProMapNDIRuntimeReceiverSettings *settings);
typedef int32_t (*ProMapNDIReceiverCaptureFunction)(void *receiver, ProMapNDIRuntimeVideoFrame *video, void *audio, void *metadata, uint32_t timeoutMilliseconds);
typedef void (*ProMapNDIReceiverFreeVideoFunction)(void *receiver, const ProMapNDIRuntimeVideoFrame *video);
typedef void (*ProMapNDIReceiverFreeAudioFunction)(void *receiver, const ProMapNDIRuntimeAudioFrame *audio);
typedef void (*ProMapNDIReceiverDestroyFunction)(void *receiver);
typedef void *(*ProMapNDISendCreateFunction)(const ProMapNDIRuntimeSendSettings *settings);
typedef void (*ProMapNDISendVideoFunction)(void *sender, const ProMapNDIRuntimeVideoFrame *video);
typedef void (*ProMapNDISendDestroyFunction)(void *sender);

typedef struct {
    ProMapNDIInitializeFunction initialize;
    ProMapNDIFindCreateFunction findCreate;
    ProMapNDIFindDestroyFunction findDestroy;
    ProMapNDIFindWaitFunction findWait;
    ProMapNDIFindSourcesFunction findSources;
    ProMapNDIReceiverCreateFunction receiverCreate;
    ProMapNDIReceiverCaptureFunction receiverCapture;
    ProMapNDIReceiverFreeVideoFunction receiverFreeVideo;
    ProMapNDIReceiverFreeAudioFunction receiverFreeAudio;
    ProMapNDIReceiverDestroyFunction receiverDestroy;
    ProMapNDISendCreateFunction sendCreate;
    ProMapNDISendVideoFunction sendVideo;
    ProMapNDISendDestroyFunction sendDestroy;
} ProMapNDIRuntimeFunctions;

typedef struct {
    int32_t frameType;
    ProMapNDIRuntimeVideoFrame video;
    ProMapNDIRuntimeAudioFrame audio;
} ProMapNDIFrameStorage;

static void *gNDILibrary = NULL;
static ProMapNDIRuntimeFunctions gNDI = {0};
static int32_t gInitializationStatus = 0;
static ProMapNDISource *gCopiedSources = NULL;
static uint32_t gCopiedSourceCount = 0;

static bool ProMapNDILoadLibrary(void) {
    if (gNDI.initialize) return true;
    if (gInitializationStatus != 0) return false;

    static const char *paths[] = {
        "/usr/local/lib/libndi.dylib",
        "/usr/local/lib/libndi.6.dylib",
        "/usr/local/lib/libndi.5.dylib",
        "/opt/homebrew/lib/libndi.dylib",
        "/opt/homebrew/lib/libndi.6.dylib",
        "/opt/homebrew/lib/libndi.5.dylib",
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"
    };
    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); ++index) {
        gNDILibrary = dlopen(paths[index], RTLD_NOW | RTLD_LOCAL);
        if (gNDILibrary) break;
    }
    if (!gNDILibrary) {
        gInitializationStatus = -1;
        return false;
    }

    gNDI.initialize = (ProMapNDIInitializeFunction)dlsym(gNDILibrary, "NDIlib_initialize");
    gNDI.findCreate = (ProMapNDIFindCreateFunction)dlsym(gNDILibrary, "NDIlib_find_create_v2");
    gNDI.findDestroy = (ProMapNDIFindDestroyFunction)dlsym(gNDILibrary, "NDIlib_find_destroy");
    gNDI.findWait = (ProMapNDIFindWaitFunction)dlsym(gNDILibrary, "NDIlib_find_wait_for_sources");
    gNDI.findSources = (ProMapNDIFindSourcesFunction)dlsym(gNDILibrary, "NDIlib_find_get_current_sources");
    gNDI.receiverCreate = (ProMapNDIReceiverCreateFunction)dlsym(gNDILibrary, "NDIlib_recv_create_v3");
    gNDI.receiverCapture = (ProMapNDIReceiverCaptureFunction)dlsym(gNDILibrary, "NDIlib_recv_capture_v3");
    gNDI.receiverFreeVideo = (ProMapNDIReceiverFreeVideoFunction)dlsym(gNDILibrary, "NDIlib_recv_free_video_v2");
    gNDI.receiverFreeAudio = (ProMapNDIReceiverFreeAudioFunction)dlsym(gNDILibrary, "NDIlib_recv_free_audio_v3");
    gNDI.receiverDestroy = (ProMapNDIReceiverDestroyFunction)dlsym(gNDILibrary, "NDIlib_recv_destroy");
    gNDI.sendCreate = (ProMapNDISendCreateFunction)dlsym(gNDILibrary, "NDIlib_send_create");
    gNDI.sendVideo = (ProMapNDISendVideoFunction)dlsym(gNDILibrary, "NDIlib_send_send_video_v2");
    gNDI.sendDestroy = (ProMapNDISendDestroyFunction)dlsym(gNDILibrary, "NDIlib_send_destroy");

    if (!gNDI.initialize || !gNDI.findCreate || !gNDI.findDestroy || !gNDI.findWait
        || !gNDI.findSources || !gNDI.receiverCreate || !gNDI.receiverCapture
        || !gNDI.receiverFreeVideo || !gNDI.receiverFreeAudio || !gNDI.receiverDestroy) {
        gInitializationStatus = -2;
        return false;
    }
    if (!gNDI.initialize()) {
        gInitializationStatus = -3;
        return false;
    }
    gInitializationStatus = 1;
    return true;
}

int32_t ProMapNDIInitialize(void) {
    if (ProMapNDILoadLibrary()) return 1;
    if (gInitializationStatus == 0) gInitializationStatus = -4;
    return gInitializationStatus;
}

const char *ProMapNDIStatusMessage(int32_t status) {
    switch (status) {
        case 1: return "NDI runtime ready";
        case -1: return "NDI runtime not found. Install the NDI SDK runtime and restart ProMap.";
        case -2: return "The installed NDI runtime is missing required receive functions. Update the NDI SDK.";
        case -3: return "The NDI runtime could not initialize.";
        case -4: return "NDI could not be initialized.";
        default: return "NDI is unavailable.";
    }
}

void *ProMapNDIFindCreate(void) {
    if (!ProMapNDILoadLibrary()) return NULL;
    return gNDI.findCreate(NULL);
}

void ProMapNDIFindDestroy(void *finder) {
    if (finder && gNDI.findDestroy) gNDI.findDestroy(finder);
}

bool ProMapNDIFindWaitForSources(void *finder, uint32_t timeoutMilliseconds) {
    return finder && gNDI.findWait ? gNDI.findWait(finder, timeoutMilliseconds) : false;
}

int32_t ProMapNDIFindCopySources(void *finder) {
    ProMapNDIFreeCopiedSources();
    if (!finder || !gNDI.findSources) return 0;

    uint32_t sourceCount = 0;
    const ProMapNDIRuntimeSource *sources = gNDI.findSources(finder, &sourceCount);
    if (!sources || sourceCount == 0) return 0;

    ProMapNDISource *copied = calloc(sourceCount, sizeof(ProMapNDISource));
    if (!copied) return 0;
    for (uint32_t index = 0; index < sourceCount; ++index) {
        copied[index].name = strdup(sources[index].name ? sources[index].name : "");
        copied[index].url = strdup(sources[index].url ? sources[index].url : "");
        if (!copied[index].name || !copied[index].url) {
            for (uint32_t freeIndex = 0; freeIndex < sourceCount; ++freeIndex) {
                free(copied[freeIndex].name);
                free(copied[freeIndex].url);
            }
            free(copied);
            return 0;
        }
    }
    gCopiedSources = copied;
    gCopiedSourceCount = sourceCount;
    return (int32_t)sourceCount;
}

const char *ProMapNDIFindSourceNameAt(uint32_t index) {
    return index < gCopiedSourceCount ? gCopiedSources[index].name : NULL;
}

const char *ProMapNDIFindSourceURLAt(uint32_t index) {
    return index < gCopiedSourceCount ? gCopiedSources[index].url : NULL;
}

void ProMapNDIFreeCopiedSources(void) {
    if (!gCopiedSources) return;
    for (uint32_t index = 0; index < gCopiedSourceCount; ++index) {
        free(gCopiedSources[index].name);
        free(gCopiedSources[index].url);
    }
    free(gCopiedSources);
    gCopiedSources = NULL;
    gCopiedSourceCount = 0;
}

void *ProMapNDIReceiverCreate(const char *name, const char *url, int32_t bandwidth) {
    if (!name || !gNDI.receiverCreate) return NULL;
    ProMapNDIRuntimeReceiverSettings settings = {0};
    settings.source.name = name;
    settings.source.url = url;
    settings.colorFormat = 0; // BGRX without alpha, BGRA with alpha
    settings.bandwidth = bandwidth == 0 ? 0 : 100; // lowest or highest bandwidth
    settings.allowVideoFields = false;
    settings.receiverName = "ProMap NDI Input";
    return gNDI.receiverCreate(&settings);
}

int32_t ProMapNDIReceiverCapture(void *receiver, ProMapNDIVideoFrame *videoOutput, ProMapNDIAudioFrame *audioOutput, void **frameHandle, uint32_t timeoutMilliseconds) {
    if (frameHandle) *frameHandle = NULL;
    if (!receiver || !videoOutput || !audioOutput || !frameHandle || !gNDI.receiverCapture) return -1;
    memset(videoOutput, 0, sizeof(*videoOutput));
    memset(audioOutput, 0, sizeof(*audioOutput));

    ProMapNDIFrameStorage *storage = calloc(1, sizeof(ProMapNDIFrameStorage));
    if (!storage) return -1;
    int32_t result = gNDI.receiverCapture(receiver, &storage->video, &storage->audio, NULL, timeoutMilliseconds);
    if (result == 1) {
        storage->frameType = result;
        videoOutput->width = storage->video.width;
        videoOutput->height = storage->video.height;
        videoOutput->stride = storage->video.stride;
        videoOutput->frameRateNumerator = storage->video.frameRateNumerator;
        videoOutput->frameRateDenominator = storage->video.frameRateDenominator;
        videoOutput->fourCC = (uint32_t)storage->video.fourCC;
        videoOutput->data = storage->video.data;
        uint32_t bgraForward = (uint32_t)'B' | ((uint32_t)'G' << 8) | ((uint32_t)'R' << 16) | ((uint32_t)'A' << 24);
        uint32_t bgraReverse = ((uint32_t)'B' << 24) | ((uint32_t)'G' << 16) | ((uint32_t)'R' << 8) | (uint32_t)'A';
        videoOutput->hasAlpha = videoOutput->fourCC == bgraForward || videoOutput->fourCC == bgraReverse;
    } else if (result == 2) {
        storage->frameType = result;
        audioOutput->sampleRate = storage->audio.sampleRate;
        audioOutput->channelCount = storage->audio.channelCount;
        audioOutput->sampleCount = storage->audio.sampleCount;
        audioOutput->channelStride = storage->audio.channelStride;
        audioOutput->fourCC = (uint32_t)storage->audio.fourCC;
        audioOutput->data = storage->audio.data;
        uint32_t fltp = (uint32_t)'F' | ((uint32_t)'L' << 8) | ((uint32_t)'T' << 16) | ((uint32_t)'p' << 24);
        audioOutput->isFloatPlanar = audioOutput->fourCC == fltp;
    } else {
        free(storage);
        return result;
    }
    *frameHandle = storage;
    return result;
}

void ProMapNDIReceiverFreeFrame(void *receiver, void *frameHandle) {
    ProMapNDIFrameStorage *storage = frameHandle;
    if (!storage) return;
    if (receiver) {
        if (storage->frameType == 1 && gNDI.receiverFreeVideo) gNDI.receiverFreeVideo(receiver, &storage->video);
        else if (storage->frameType == 2 && gNDI.receiverFreeAudio) gNDI.receiverFreeAudio(receiver, &storage->audio);
    }
    free(storage);
}

void ProMapNDIReceiverDestroy(void *receiver) {
    if (receiver && gNDI.receiverDestroy) gNDI.receiverDestroy(receiver);
}

bool ProMapNDISendAvailable(void) {
    return ProMapNDILoadLibrary() && gNDI.sendCreate && gNDI.sendVideo && gNDI.sendDestroy;
}

void *ProMapNDISendCreate(const char *name) {
    if (!name || !ProMapNDISendAvailable()) return NULL;
    ProMapNDIRuntimeSendSettings settings = {0};
    settings.name = name;
    settings.groups = NULL;
    settings.clockVideo = false;
    settings.clockAudio = false;
    return gNDI.sendCreate(&settings);
}

bool ProMapNDISendVideoFrame(void *sender, int32_t width, int32_t height, int32_t frameRateNumerator, int32_t frameRateDenominator, const uint8_t *bgraData) {
    if (!sender || !bgraData || width <= 0 || height <= 0 || (width & 1) != 0
        || width > INT_MAX / 4 || frameRateNumerator <= 0 || frameRateDenominator <= 0
        || !ProMapNDISendAvailable()) return false;
    ProMapNDIRuntimeVideoFrame frame = {0};
    frame.width = width;
    frame.height = height;
    frame.fourCC = 0x41524742; // NDIlib_FourCC_type_BGRA
    frame.frameRateNumerator = frameRateNumerator;
    frame.frameRateDenominator = frameRateDenominator;
    frame.pictureAspectRatio = (float)width / (float)height;
    frame.frameFormat = 1; // NDIlib_frame_format_type_progressive
    frame.timecode = INT64_MAX; // NDIlib_send_timecode_synthesize
    frame.data = (uint8_t *)bgraData;
    frame.stride = width * 4;
    gNDI.sendVideo(sender, &frame);
    return true;
}

void ProMapNDISendDestroy(void *sender) {
    if (sender && gNDI.sendDestroy) gNDI.sendDestroy(sender);
}

#else

int32_t ProMapNDIInitialize(void) { return 0; }
const char *ProMapNDIStatusMessage(int32_t status) {
    (void)status;
    return "NDI SDK headers were not available when ProMap was built. Install the NDI SDK and rebuild to enable NDI inputs.";
}
void *ProMapNDIFindCreate(void) { return NULL; }
void ProMapNDIFindDestroy(void *finder) { (void)finder; }
bool ProMapNDIFindWaitForSources(void *finder, uint32_t timeoutMilliseconds) {
    (void)finder; (void)timeoutMilliseconds; return false;
}
int32_t ProMapNDIFindCopySources(void *finder) { (void)finder; return 0; }
const char *ProMapNDIFindSourceNameAt(uint32_t index) { (void)index; return NULL; }
const char *ProMapNDIFindSourceURLAt(uint32_t index) { (void)index; return NULL; }
void ProMapNDIFreeCopiedSources(void) {}
void *ProMapNDIReceiverCreate(const char *name, const char *url, int32_t bandwidth) {
    (void)name; (void)url; (void)bandwidth; return NULL;
}
int32_t ProMapNDIReceiverCapture(void *receiver, ProMapNDIVideoFrame *videoFrame, ProMapNDIAudioFrame *audioFrame, void **frameHandle, uint32_t timeoutMilliseconds) {
    (void)receiver; (void)videoFrame; (void)audioFrame; (void)frameHandle; (void)timeoutMilliseconds; return -1;
}
void ProMapNDIReceiverFreeFrame(void *receiver, void *frameHandle) {
    (void)receiver; (void)frameHandle;
}
void ProMapNDIReceiverDestroy(void *receiver) { (void)receiver; }
bool ProMapNDISendAvailable(void) { return false; }
void *ProMapNDISendCreate(const char *name) { (void)name; return NULL; }
bool ProMapNDISendVideoFrame(void *sender, int32_t width, int32_t height, int32_t frameRateNumerator, int32_t frameRateDenominator, const uint8_t *bgraData) { (void)sender; (void)width; (void)height; (void)frameRateNumerator; (void)frameRateDenominator; (void)bgraData; return false; }
void ProMapNDISendDestroy(void *sender) { (void)sender; }

#endif

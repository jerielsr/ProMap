#ifndef PROMAP_NDI_RUNTIME_BRIDGE_H
#define PROMAP_NDI_RUNTIME_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    char *name;
    char *url;
} ProMapNDISource;

typedef struct {
    int32_t width;
    int32_t height;
    int32_t stride;
    int32_t frameRateNumerator;
    int32_t frameRateDenominator;
    uint32_t fourCC;
    const uint8_t *data;
    bool hasAlpha;
} ProMapNDIVideoFrame;

typedef struct {
    int32_t sampleRate;
    int32_t channelCount;
    int32_t sampleCount;
    int32_t channelStride;
    uint32_t fourCC;
    const uint8_t *data;
    bool isFloatPlanar;
} ProMapNDIAudioFrame;

int32_t ProMapNDIInitialize(void);
const char *ProMapNDIStatusMessage(int32_t status);
void *ProMapNDIFindCreate(void);
void ProMapNDIFindDestroy(void *finder);
bool ProMapNDIFindWaitForSources(void *finder, uint32_t timeoutMilliseconds);
int32_t ProMapNDIFindCopySources(void *finder);
const char *ProMapNDIFindSourceNameAt(uint32_t index);
const char *ProMapNDIFindSourceURLAt(uint32_t index);
void ProMapNDIFreeCopiedSources(void);
void *ProMapNDIReceiverCreate(const char *name, const char *url, int32_t bandwidth);
int32_t ProMapNDIReceiverCapture(void *receiver, ProMapNDIVideoFrame *videoFrame, ProMapNDIAudioFrame *audioFrame, void **frameHandle, uint32_t timeoutMilliseconds);
void ProMapNDIReceiverFreeFrame(void *receiver, void *frameHandle);
void ProMapNDIReceiverDestroy(void *receiver);
bool ProMapNDISendAvailable(void);
void *ProMapNDISendCreate(const char *name);
bool ProMapNDISendVideoFrame(void *sender, int32_t width, int32_t height, int32_t frameRateNumerator, int32_t frameRateDenominator, const uint8_t *bgraData);
void ProMapNDISendDestroy(void *sender);

#endif

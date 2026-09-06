#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

/// Single producer (HAL callback), single consumer (recorder queue).
/// Create/start/stop/destroy must be serialized by the owner. Creation does not start I/O.
typedef struct TFHALInput TFHALInput;
typedef struct {
    double sampleRate;
    UInt32 channels;
    UInt32 maximumFrames;
    UInt32 deviceBufferFrames;
} TFHALInputFormat;
typedef struct {
    UInt32 frames;
    UInt64 sampleHostTime;
    UInt64 callbackHostTime;
} TFHALInputPacket;

TFHALInput * _Nullable TFHALInputCreate(AudioDeviceID device, OSStatus * _Nonnull error);
TFHALInputFormat TFHALInputGetFormat(TFHALInput * _Nonnull input);
OSStatus TFHALInputStart(TFHALInput * _Nonnull input);
void TFHALInputStop(TFHALInput * _Nonnull input);
void TFHALInputDestroy(TFHALInput * _Nullable input);
bool TFHALInputRead(TFHALInput * _Nonnull input, float * _Nonnull destination,
                    UInt32 capacityFrames, TFHALInputPacket * _Nonnull packet);
OSStatus TFHALInputGetError(TFHALInput * _Nonnull input);
UInt64 TFHALInputDroppedFrames(TFHALInput * _Nonnull input);

/// Hardware-free entry points for exercising exactly the production ring buffer.
TFHALInput * _Nullable TFHALInputCreateBufferForTesting(double sampleRate, UInt32 channels, UInt32 maximumFrames);
bool TFHALInputPushForTesting(TFHALInput * _Nonnull input, const float * _Nonnull samples,
                              UInt32 frames, UInt64 sampleHostTime, UInt64 callbackHostTime);

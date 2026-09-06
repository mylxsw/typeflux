#include "TFHALInput.h"
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <CoreServices/CoreServices.h>

struct TFHALInput {
    AudioUnit unit;
    TFHALInputFormat format;
    float *samples;
    float *scratch;
    TFHALInputPacket *packets;
    UInt32 slotCount;
    _Atomic UInt64 writeIndex;
    _Atomic UInt64 readIndex;
    _Atomic UInt64 droppedFrames;
    _Atomic OSStatus error;
    bool initialized;
    bool running;
};

static bool allocateBuffers(TFHALInput *input) {
    if (!isfinite(input->format.sampleRate) || input->format.sampleRate <= 0 ||
        input->format.channels == 0 || input->format.channels > 32 ||
        input->format.maximumFrames == 0 || input->format.maximumFrames > 8192) return false;
    // Size by the actual I/O quantum, not the maximum slice: a unit may reserve
    // 4096 frames but deliver only 256 at a time. Bound total storage to 32 MiB.
    UInt32 quantum = input->format.deviceBufferFrames ? input->format.deviceBufferFrames : input->format.maximumFrames;
    double slots = ceil(input->format.sampleRate * 2 / quantum);
    input->slotCount = (UInt32)fmin(512, fmax(8, slots));
    size_t samplesPerSlot = (size_t)input->format.maximumFrames * input->format.channels;
    input->slotCount = (UInt32)fmin(input->slotCount, fmax(8, (32 * 1024 * 1024) / (samplesPerSlot * sizeof(float))));
    input->samples = calloc(input->slotCount * samplesPerSlot, sizeof(float));
    input->scratch = calloc(samplesPerSlot, sizeof(float));
    input->packets = calloc(input->slotCount, sizeof(TFHALInputPacket));
    atomic_init(&input->writeIndex, 0);
    atomic_init(&input->readIndex, 0);
    atomic_init(&input->droppedFrames, 0);
    atomic_init(&input->error, noErr);
    return input->samples && input->scratch && input->packets;
}

static OSStatus receiveInput(void *context, AudioUnitRenderActionFlags *flags,
                             const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
                             AudioBufferList *unused) {
    TFHALInput *input = context;
    UInt64 callbackTime = mach_absolute_time();
    if (frames > input->format.maximumFrames) {
        atomic_store(&input->error, kAudioUnitErr_TooManyFramesToProcess);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    UInt64 write = atomic_load_explicit(&input->writeIndex, memory_order_relaxed);
    UInt64 read = atomic_load_explicit(&input->readIndex, memory_order_acquire);
    bool full = write - read >= input->slotCount;
    UInt32 slot = (UInt32)(write % input->slotCount);
    float *destination = full ? input->scratch :
        input->samples + (size_t)slot * input->format.maximumFrames * input->format.channels;
    AudioBufferList buffers = { .mNumberBuffers = 1, .mBuffers = {{
        .mNumberChannels = input->format.channels,
        .mDataByteSize = frames * input->format.channels * sizeof(float),
        .mData = destination
    }}};
    OSStatus status = AudioUnitRender(input->unit, flags, timestamp, bus, frames, &buffers);
    if (status != noErr) {
        atomic_store(&input->error, status);
        return status;
    }
    if (full) {
        atomic_fetch_add_explicit(&input->droppedFrames, frames, memory_order_relaxed);
        return noErr;
    }
    input->packets[slot] = (TFHALInputPacket){frames,
        (timestamp->mFlags & kAudioTimeStampHostTimeValid) ? timestamp->mHostTime : 0,
        callbackTime};
    atomic_store_explicit(&input->writeIndex, write + 1, memory_order_release);
    return noErr;
}

TFHALInput *TFHALInputCreate(AudioDeviceID device, OSStatus *error) {
    TFHALInput *input = calloc(1, sizeof(TFHALInput));
    if (!input) { *error = memFullErr; return NULL; }
    AudioComponentDescription description = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
        kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    OSStatus status = component ? AudioComponentInstanceNew(component, &input->unit) : kAudioUnitErr_FailedInitialization;
    if (status != noErr) goto failure;
    UInt32 enabled = 1, disabled = 0;
    status = AudioUnitSetProperty(input->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
    if (status != noErr) goto failure;
    status = AudioUnitSetProperty(input->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, sizeof(disabled));
    if (status != noErr) goto failure;
    status = AudioUnitSetProperty(input->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device));
    if (status != noErr) goto failure;
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    status = AudioUnitGetProperty(input->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size);
    if (status != noErr) goto failure;
    input->format.sampleRate = format.mSampleRate;
    input->format.channels = format.mChannelsPerFrame;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mBitsPerChannel = 32;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = format.mChannelsPerFrame * sizeof(float);
    format.mBytesPerPacket = format.mBytesPerFrame;
    status = AudioUnitSetProperty(input->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format));
    if (status != noErr) goto failure;
    size = sizeof(input->format.maximumFrames);
    status = AudioUnitGetProperty(input->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &input->format.maximumFrames, &size);
    if (status != noErr) goto failure;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    size = sizeof(input->format.deviceBufferFrames);
    status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &input->format.deviceBufferFrames);
    if (status != noErr) goto failure;
    // Respect the device's existing buffer size; changing it affects other applications too.
    if (!allocateBuffers(input)) { status = memFullErr; goto failure; }
    AURenderCallbackStruct callback = {receiveInput, input};
    status = AudioUnitSetProperty(input->unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback));
    if (status != noErr) goto failure;
    status = AudioUnitInitialize(input->unit);
    if (status != noErr) goto failure;
    input->initialized = true;
    *error = noErr;
    return input;
failure:
    *error = status;
    TFHALInputDestroy(input);
    return NULL;
}

TFHALInputFormat TFHALInputGetFormat(TFHALInput *input) { return input->format; }
OSStatus TFHALInputStart(TFHALInput *input) {
    OSStatus status = AudioOutputUnitStart(input->unit);
    input->running = status == noErr;
    return status;
}
void TFHALInputStop(TFHALInput *input) {
    if (input->running) {
        OSStatus status = AudioOutputUnitStop(input->unit);
        if (status != noErr) atomic_store(&input->error, status);
    }
    input->running = false;
}
void TFHALInputDestroy(TFHALInput *input) {
    if (!input) return;
    TFHALInputStop(input);
    if (input->initialized) AudioUnitUninitialize(input->unit);
    if (input->unit) AudioComponentInstanceDispose(input->unit);
    free(input->samples);
    free(input->scratch);
    free(input->packets);
    free(input);
}
bool TFHALInputRead(TFHALInput *input, float *destination, UInt32 capacityFrames, TFHALInputPacket *packet) {
    UInt64 read = atomic_load_explicit(&input->readIndex, memory_order_relaxed);
    UInt64 write = atomic_load_explicit(&input->writeIndex, memory_order_acquire);
    if (read == write) return false;
    UInt32 slot = (UInt32)(read % input->slotCount);
    *packet = input->packets[slot];
    if (packet->frames > capacityFrames) return false;
    memcpy(destination, input->samples + (size_t)slot * input->format.maximumFrames * input->format.channels,
           (size_t)packet->frames * input->format.channels * sizeof(float));
    atomic_store_explicit(&input->readIndex, read + 1, memory_order_release);
    return true;
}
OSStatus TFHALInputGetError(TFHALInput *input) { return atomic_load(&input->error); }
UInt64 TFHALInputDroppedFrames(TFHALInput *input) { return atomic_load(&input->droppedFrames); }

TFHALInput *TFHALInputCreateBufferForTesting(double sampleRate, UInt32 channels, UInt32 maximumFrames) {
    TFHALInput *input = calloc(1, sizeof(TFHALInput));
    if (!input) return NULL;
    input->format = (TFHALInputFormat){sampleRate, channels, maximumFrames, maximumFrames};
    if (!allocateBuffers(input)) { TFHALInputDestroy(input); return NULL; }
    return input;
}
bool TFHALInputPushForTesting(TFHALInput *input, const float *samples, UInt32 frames, UInt64 sampleHostTime, UInt64 callbackHostTime) {
    if (frames > input->format.maximumFrames) return false;
    UInt64 write = atomic_load_explicit(&input->writeIndex, memory_order_relaxed);
    UInt64 read = atomic_load_explicit(&input->readIndex, memory_order_acquire);
    if (write - read >= input->slotCount) {
        atomic_fetch_add(&input->droppedFrames, frames);
        return false;
    }
    UInt32 slot = (UInt32)(write % input->slotCount);
    memcpy(input->samples + (size_t)slot * input->format.maximumFrames * input->format.channels,
           samples, (size_t)frames * input->format.channels * sizeof(float));
    input->packets[slot] = (TFHALInputPacket){frames, sampleHostTime, callbackHostTime};
    atomic_store_explicit(&input->writeIndex, write + 1, memory_order_release);
    return true;
}

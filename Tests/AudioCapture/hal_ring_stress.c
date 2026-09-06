#include "TFHALInput.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>

static TFHALInput *ring;
static const unsigned packetCount = 100000;

static void *produce(void *unused) {
    for (unsigned packet = 1; packet <= packetCount; packet++) {
        float samples[32];
        for (unsigned i = 0; i < 32; i++) samples[i] = (float)packet;
        while (!TFHALInputPushForTesting(ring, samples, 16, packet, packet + 1)) sched_yield();
    }
    return NULL;
}

int main(void) {
    ring = TFHALInputCreateBufferForTesting(48000, 2, 16);
    assert(ring);
    pthread_t producer;
    assert(pthread_create(&producer, NULL, produce, NULL) == 0);
    for (unsigned expected = 1; expected <= packetCount; expected++) {
        float samples[32];
        TFHALInputPacket packet;
        while (!TFHALInputRead(ring, samples, 16, &packet)) sched_yield();
        assert(packet.frames == 16);
        assert(packet.sampleHostTime == expected && packet.callbackHostTime == expected + 1);
        for (unsigned i = 0; i < 32; i++) assert(samples[i] == (float)expected);
    }
    pthread_join(producer, NULL);
    TFHALInputDestroy(ring);
    puts("100000 concurrent stereo packets: order, samples and timestamps preserved");
}

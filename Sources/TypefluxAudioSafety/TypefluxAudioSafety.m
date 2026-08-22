#import "TypefluxAudioSafety.h"

NSString *const TFAudioTapErrorDomain = @"ai.gulu.app.typeflux.audio-tap";

BOOL TFInstallAudioTapSafely(
    AVAudioNode *node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    AVAudioNodeTapBlock tapBlock,
    NSError *_Nullable *_Nullable error
) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:tapBlock];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"The microphone input changed while recording was starting.";
            *error = [NSError errorWithDomain:TFAudioTapErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: reason,
                                         @"exceptionName": exception.name
                                     }];
        }
        return NO;
    }
}

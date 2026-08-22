#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const TFAudioTapErrorDomain;

/// Installs an AVAudioNode tap while converting AVFAudio's Objective-C
/// exceptions into NSError values that Swift can recover from.
FOUNDATION_EXPORT BOOL TFInstallAudioTapSafely(
    AVAudioNode *node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    AVAudioNodeTapBlock tapBlock,
    NSError *_Nullable *_Nullable error
);

NS_ASSUME_NONNULL_END

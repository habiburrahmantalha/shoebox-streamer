#import <VLCKit/VLCMediaPlayer.h>
#import <CoreVideo/CoreVideo.h>

BOOL ShoeboxSetSubtitleScale(VLCMediaPlayer * _Nonnull player, int percent);
// VLCKit's stop is asynchronous; run the synchronous C stop away from AppKit.
void ShoeboxStopPlayer(VLCMediaPlayer * _Nonnull player, void (^_Nonnull completion)(void));

// Install/remove only while the player is stopped. The owner must outlive playback.
@interface ShoeboxVideoFrames : NSObject
- (instancetype _Nonnull)initWithHandler:(void (^_Nonnull)(CVPixelBufferRef _Nonnull))handler;
- (void)attachToPlayer:(VLCMediaPlayer * _Nonnull)player;
- (void)detachFromPlayer:(VLCMediaPlayer * _Nonnull)player;
@end

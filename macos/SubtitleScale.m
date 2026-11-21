#import "SubtitleScale.h"

// VLCKit 3.7.3 has no text scale setter. This is the integer variable used by
// VLC 3's text renderer; the renderer inherits it from the media player.
typedef struct libvlc_media_player_t libvlc_media_player_t;
#import "VLCMediaPlayer+Internal.h"
#import <vlc/vlc.h>

typedef union { int64_t i_int; } VLCIntegerValue;
enum { VLCIntegerVariable = 0x0030 };
extern int var_Type(void *object, const char *name);
extern int var_Create(void *object, const char *name, int type);
extern int var_SetChecked(void *object, const char *name, int type, VLCIntegerValue value);

BOOL ShoeboxSetSubtitleScale(VLCMediaPlayer *player, int percent) {
    void *object = player.playerInstance;
    const char *name = "sub-text-scale";
    if (!object || percent < 50 || percent > 200) return NO;
    if (!var_Type(object, name) && var_Create(object, name, VLCIntegerVariable) != 0) return NO;
    return var_SetChecked(object, name, VLCIntegerVariable, (VLCIntegerValue){ .i_int = percent }) == 0;
}

void ShoeboxStopPlayer(VLCMediaPlayer *player, void (^completion)(void)) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("Shoebox.stop", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        libvlc_media_player_stop(player.playerInstance);
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

@interface ShoeboxVideoFrames () {
    NSLock *_lock;
    void *_pixels;
    unsigned _width, _height, _pitch, _lines;
    void (^_handler)(CVPixelBufferRef);
    libvlc_media_player_t *_player;
}
@end

@implementation ShoeboxVideoFrames
- (instancetype)initWithHandler:(void (^)(CVPixelBufferRef))handler {
    if ((self = [super init])) { _lock = [NSLock new]; _handler = [handler copy]; }
    return self;
}
- (void)dealloc { free(_pixels); }
static unsigned setupFrames(void **opaque, char *chroma, unsigned *width, unsigned *height,
                            unsigned *pitches, unsigned *lines) {
    ShoeboxVideoFrames *frames = (__bridge ShoeboxVideoFrames *)*opaque;
    if (!*width || !*height) return 0;
    double displayWidth = *width, displayHeight = *height;
    libvlc_media_t *media = libvlc_media_player_get_media(frames->_player);
    if (media) {
        libvlc_media_track_t **tracks = NULL;
        unsigned count = libvlc_media_tracks_get(media, &tracks);
        for (unsigned i = 0; i < count; i++) {
            if (tracks[i]->i_type != libvlc_track_video) continue;
            libvlc_video_track_t *video = tracks[i]->video;
            if (video->i_width && video->i_height) {
                displayWidth = video->i_width; displayHeight = video->i_height;
                if (video->i_sar_num && video->i_sar_den) displayWidth *= (double)video->i_sar_num / video->i_sar_den;
                if (video->i_orientation >= libvlc_video_orient_left_top) {
                    double swapped = displayWidth; displayWidth = displayHeight; displayHeight = swapped;
                }
            }
            break;
        }
        libvlc_media_tracks_release(tracks, count);
        libvlc_media_release(media);
    }
    // AI mode targets the glasses' 1920×1080 per eye and uses SDR BGRA frames.
    double scale = fmin(1.0, fmin(1920.0 / displayWidth, 1080.0 / displayHeight));
    *width = MAX(2, (unsigned)(displayWidth * scale) & ~1u);
    *height = MAX(2, (unsigned)(displayHeight * scale) & ~1u);
    frames->_width = *width; frames->_height = *height;
    frames->_pitch = (*width * 4 + 63) & ~63u;
    frames->_lines = (*height + 31) & ~31u;
    free(frames->_pixels); frames->_pixels = NULL;
    if (posix_memalign(&frames->_pixels, 64, frames->_pitch * frames->_lines)) return 0;
    memcpy(chroma, "RV32", 4);
    pitches[0] = frames->_pitch; lines[0] = frames->_lines;
    return 1;
}
static void *lockFrame(void *opaque, void **planes) {
    ShoeboxVideoFrames *frames = (__bridge ShoeboxVideoFrames *)opaque;
    [frames->_lock lock]; planes[0] = frames->_pixels; return NULL;
}
static void unlockFrame(void *opaque, void *picture, void *const *planes) {
    ShoeboxVideoFrames *frames = (__bridge ShoeboxVideoFrames *)opaque;
    [frames->_lock unlock];
}
static void displayFrame(void *opaque, void *picture) {
    @autoreleasepool {
        ShoeboxVideoFrames *frames = (__bridge ShoeboxVideoFrames *)opaque;
        CVPixelBufferRef buffer = NULL;
        NSDictionary *attributes = @{(id)kCVPixelBufferMetalCompatibilityKey: @YES,
                                     (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, frames->_width, frames->_height,
                               kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &buffer)) return;
        CVPixelBufferLockBaseAddress(buffer, 0);
        [frames->_lock lock];
        for (unsigned y = 0; y < frames->_height; y++) {
            memcpy((char *)CVPixelBufferGetBaseAddress(buffer) + y * CVPixelBufferGetBytesPerRow(buffer),
                   (char *)frames->_pixels + y * frames->_pitch, frames->_width * 4);
            uint8_t *row = (uint8_t *)CVPixelBufferGetBaseAddress(buffer) + y * CVPixelBufferGetBytesPerRow(buffer);
            for (unsigned x = 0; x < frames->_width; x++) row[x * 4 + 3] = 255;
        }
        [frames->_lock unlock];
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        frames->_handler(buffer);
        CVPixelBufferRelease(buffer);
    }
}
- (void)attachToPlayer:(VLCMediaPlayer *)player {
    _player = player.playerInstance;
    libvlc_video_set_callbacks(player.playerInstance, lockFrame, unlockFrame, displayFrame, (__bridge void *)self);
    libvlc_video_set_format_callbacks(player.playerInstance, setupFrames, NULL);
}
- (void)detachFromPlayer:(VLCMediaPlayer *)player {
    libvlc_video_set_callbacks(player.playerInstance, NULL, NULL, NULL, NULL);
    libvlc_video_set_format_callbacks(player.playerInstance, NULL, NULL);
    // In VLC 3, clearing callbacks alone leaves vout=vmem and disables hardware decoding.
    libvlc_media_player_set_nsobject(player.playerInstance, NULL);
    _player = NULL;
}
@end

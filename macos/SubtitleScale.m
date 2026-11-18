#import "SubtitleScale.h"

// VLCKit 3.7.3 has no text scale setter. This is the integer variable used by
// VLC 3's text renderer; the renderer inherits it from the media player.
typedef struct libvlc_media_player_t libvlc_media_player_t;
#import "VLCMediaPlayer+Internal.h"

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

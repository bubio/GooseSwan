/* Streaming audio output for the frontend: one SDL3 audio stream that the
   main thread feeds with each frame's samples, so consecutive frames play
   back to back. (The audio package only starts independent voices at the
   next device block, which leaves gaps and overlaps between frames.)

   The SDL3 headers are not shipped with Goose, but libSDL3 is linked in
   through the gfx package, so the few declarations needed are written out
   here (SDL3 ABI). Main thread only. */
#include <stdint.h>
#include <stdbool.h>

typedef struct SDL_AudioStream SDL_AudioStream;
typedef struct { int format; int channels; int freq; } SDL_AudioSpec;
typedef void (*SDL_AudioStreamCallback)(void *, SDL_AudioStream *, int, int);

extern bool SDL_InitSubSystem(uint32_t flags);
extern void SDL_QuitSubSystem(uint32_t flags);
extern SDL_AudioStream *SDL_OpenAudioDeviceStream(uint32_t devid, const SDL_AudioSpec *spec,
                                                  SDL_AudioStreamCallback cb, void *userdata);
extern bool SDL_ResumeAudioStreamDevice(SDL_AudioStream *stream);
extern bool SDL_PutAudioStreamData(SDL_AudioStream *stream, const void *buf, int len);
extern int SDL_GetAudioStreamQueued(SDL_AudioStream *stream);
extern void SDL_DestroyAudioStream(SDL_AudioStream *stream);

#define HA_INIT_AUDIO 0x00000010u
#define HA_AUDIO_S16LE 0x8010
#define HA_DEFAULT_PLAYBACK 0xFFFFFFFFu

typedef struct { const int16_t *data; int64_t len; } ha_i16_slice;

static SDL_AudioStream *ha_stream;

/* Open the default device for interleaved stereo s16 at `rate`; SDL
   resamples to the device. */
bool hostaudio_open(int64_t rate) {
    if (ha_stream) return true;
    if (!SDL_InitSubSystem(HA_INIT_AUDIO)) return false;
    SDL_AudioSpec spec = { HA_AUDIO_S16LE, 2, (int)rate };
    ha_stream = SDL_OpenAudioDeviceStream(HA_DEFAULT_PLAYBACK, &spec, 0, 0);
    if (!ha_stream) { SDL_QuitSubSystem(HA_INIT_AUDIO); return false; }
    if (!SDL_ResumeAudioStreamDevice(ha_stream)) {
        SDL_DestroyAudioStream(ha_stream);
        ha_stream = 0;
        SDL_QuitSubSystem(HA_INIT_AUDIO);
        return false;
    }
    return true;
}

/* Append interleaved stereo samples to the stream. */
void hostaudio_push(ha_i16_slice pcm) {
    if (ha_stream && pcm.len > 0) SDL_PutAudioStreamData(ha_stream, pcm.data, (int)(pcm.len * 2));
}

/* Stereo frames queued and not yet played. */
int64_t hostaudio_queued(void) {
    if (!ha_stream) return 0;
    int bytes = SDL_GetAudioStreamQueued(ha_stream);
    return bytes > 0 ? bytes / 4 : 0;
}

void hostaudio_close(void) {
    if (!ha_stream) return;
    SDL_DestroyAudioStream(ha_stream);
    ha_stream = 0;
    SDL_QuitSubSystem(HA_INIT_AUDIO);
}

/* Exercises the production Wine driver with a deterministic mock at the Apple
 * AudioUnit/mach and Nt event boundaries. It does not certify Apple SDK ABI,
 * hardware scheduling, routing, sound quality, or iOS interruptions.
 * GPL-3.0-or-later. */
#define _DEFAULT_SOURCE 1
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>

static unsigned long checks;
#define CHECK(x) do { ++checks; if (!(x)) { \
    fprintf(stderr, "audio_driver_test:%d: %s\n", __LINE__, #x); abort(); } } while (0)

static int fail_allocation;
static void *audio_test_calloc(size_t n, size_t size) {
    if (fail_allocation > 0 && --fail_allocation == 0) return NULL;
    return calloc(n, size);
}
#define calloc audio_test_calloc
#include "../build/ntdll-unix/audio_null_ios.c"
#undef calloc

struct FakeAU { int allocated, running; AudioStreamBasicDescription format; AURenderCallbackStruct cb; };
static struct FakeAU units[32];
static int fail_setup, fail_start;
static _Atomic uint64_t fake_ticks;
static _Atomic unsigned events;
static _Atomic int *timer_joined;
int madeira_get_diag_enabled(void) { return 0; }
uint64_t mach_absolute_time(void) { return atomic_load(&fake_ticks); }
int mach_timebase_info(mach_timebase_info_data_t *info) {
    info->numer = 125; info->denom = 3; return 0;
}
AudioComponent AudioComponentFindNext(AudioComponent previous, const AudioComponentDescription *desc) {
    (void)previous; (void)desc; return fail_setup == 1 ? NULL : (void *)(uintptr_t)1;
}
OSStatus AudioComponentInstanceNew(AudioComponent comp, AudioUnit *unit) {
    (void)comp;
    if (fail_setup == 2) return -1;
    for (unsigned i = 0; i < 32; ++i) if (!units[i].allocated) {
        memset(&units[i], 0, sizeof(units[i])); units[i].allocated = 1; *unit = &units[i]; return 0;
    }
    return -1;
}
OSStatus AudioComponentInstanceDispose(AudioUnit unit) { unit->allocated = 0; return 0; }
OSStatus AudioUnitSetProperty(AudioUnit unit, UInt32 property, UInt32 scope, UInt32 bus,
                             const void *data, UInt32 size) {
    (void)scope; (void)bus; (void)size;
    if (fail_setup == 3) return -1;
    if (property == kAudioUnitProperty_StreamFormat) unit->format = *(const AudioStreamBasicDescription *)data;
    if (property == kAudioUnitProperty_SetRenderCallback) unit->cb = *(const AURenderCallbackStruct *)data;
    return 0;
}
OSStatus AudioUnitInitialize(AudioUnit unit) { (void)unit; return fail_setup == 4 ? -1 : 0; }
OSStatus AudioUnitUninitialize(AudioUnit unit) { (void)unit; return 0; }
OSStatus AudioOutputUnitStart(AudioUnit unit) { if (fail_start) return -1; unit->running = 1; return 0; }
OSStatus AudioOutputUnitStop(AudioUnit unit) { unit->running = 0; return 0; }
NTSTATUS NtSetEvent(HANDLE event, void *prev) { (void)event; (void)prev; atomic_fetch_add(&events, 1); return 0; }
NTSTATUS NtWaitForSingleObject(HANDLE handle, BOOL alertable, const void *timeout) {
    (void)alertable; (void)timeout;
    pthread_join(*(pthread_t *)handle, NULL);
    if (timer_joined) atomic_store(timer_joined, 1);
    return 0;
}
NTSTATUS NtClose(HANDLE handle) { (void)handle; return 0; }

static struct WAVEFORMATEX_stub format(unsigned bits, unsigned channels, unsigned rate, unsigned tag) {
    struct WAVEFORMATEX_stub f = {0};
    f.wFormatTag = tag; f.wBitsPerSample = bits; f.nChannels = channels;
    f.nSamplesPerSec = rate; f.nBlockAlign = bits / 8 * channels;
    f.nAvgBytesPerSec = f.nBlockAlign * rate;
    return f;
}
static stream_handle create(const struct WAVEFORMATEX_stub *f, int64_t duration) {
    stream_handle h = UINT64_MAX;
    UINT32 channels = 0;
    struct create_stream_params p = {.flow = eRender, .fmt = f, .duration = duration,
                                    .stream = &h, .channel_count = &channels};
    ios_create_stream(&p); CHECK(p.result == S_OK); CHECK(h != 0); CHECK(channels == f->nChannels);
    return h;
}
static void release(stream_handle h) {
    struct release_stream_params p = {.stream = h};
    ios_release_stream(&p); CHECK(p.result == S_OK); CHECK(!stream_from_handle(h));
}
static HRESULT get(stream_handle h, unsigned frames, BYTE **data) {
    struct get_render_buffer_params p = {.stream = h, .frames = frames, .data = data};
    ios_get_render_buffer(&p); return p.result;
}
static HRESULT put(stream_handle h, unsigned frames, unsigned flags) {
    struct release_render_buffer_params p = {.stream = h, .written_frames = frames, .flags = flags};
    ios_release_render_buffer(&p); return p.result;
}
static HRESULT reset(stream_handle h) {
    struct stream_handle_params p = {.stream = h}; ios_reset(&p); return p.result;
}
static HRESULT start(stream_handle h) {
    struct stream_handle_params p = {.stream = h}; ios_start(&p); return p.result;
}
static HRESULT stop(stream_handle h) {
    struct stream_handle_params p = {.stream = h}; ios_stop(&p); return p.result;
}
static unsigned live_units(void) { unsigned n = 0; for (unsigned i = 0; i < 32; ++i) n += units[i].allocated; return n; }

static void formats(void) {
    for (unsigned channels = 1; channels <= 2; ++channels) {
        for (unsigned bits = 8; bits <= 32; bits += 8) {
            struct WAVEFORMATEX_stub f = format(bits, channels, 48000, 1);
            CHECK(ios_format_supported(&f));
            stream_handle h = create(&f, 100000); struct ios_stream *s = stream_from_handle(h);
            CHECK(s->au->format.mBitsPerChannel == bits);
            CHECK(s->au->format.mBytesPerFrame == f.nBlockAlign);
            CHECK(s->silence_byte == (bits == 8 ? 128 : 0));
            if (bits == 8) CHECK(!(s->au->format.mFormatFlags & kAudioFormatFlagIsSignedInteger));
            release(h);
        }
    }
    struct WAVEFORMATEX_stub f = format(32, 2, 44100, 3);
    CHECK(ios_format_supported(&f));
    stream_handle h = create(&f, INT64_MAX); CHECK(stream_from_handle(h)->buffer_frames == 44100 * 4); release(h);
    f.nBlockAlign = 3; CHECK(!ios_format_supported(&f));
    f = format(16, 2, 48000, 1); f.nAvgBytesPerSec++; CHECK(!ios_format_supported(&f));
    f = format(16, 3, 48000, 1); CHECK(!ios_format_supported(&f));
    f = format(64, 2, 48000, 3); CHECK(!ios_format_supported(&f));
    for (unsigned tag = 0; tag < 0xffff; tag += 7) {
        f = format(16, 2, 48000, tag);
        CHECK(ios_format_supported(&f) == (tag == 1));
    }
    f = format(16, 2, 7999, 1); CHECK(!ios_format_supported(&f));
    f = format(16, 2, 192001, 1); CHECK(!ios_format_supported(&f));
    CHECK(!ios_format_supported(NULL));
    unsigned char ext[40];
    struct get_mix_format_params mix = {.flow = eRender, .fmt = ext};
    ios_get_mix_format(&mix); CHECK(mix.result == S_OK);
    CHECK(ios_format_supported((const void *)ext));
    ext[39] ^= 1; CHECK(!ios_format_supported((const void *)ext)); ext[39] ^= 1;
    ext[24] = 3; ext[14] = 32; ext[12] = 8;
    ((struct WAVEFORMATEX_stub *)ext)->nAvgBytesPerSec = 48000 * 8;
    ext[18] = 32; CHECK(ios_format_supported((const void *)ext));
    ext[18] = 24; CHECK(!ios_format_supported((const void *)ext));
    CHECK(ios_buffer_frames(-1, 48000) == 4800);
    CHECK(ios_buffer_frames(INT64_MAX, 192000) == 768000);
    CHECK(ios_buffer_frames(1000001, 44100) == 4411); // round up, never truncate requested duration
    struct is_format_supported_params query = {.flow = eCapture, .fmt_in = &f};
    ios_is_format_supported(&query); CHECK(query.result == AUDCLNT_E_UNSUPPORTED_FORMAT);
}

static void buffer_contract(void) {
    struct WAVEFORMATEX_stub f = format(16, 2, 48000, 1);
    stream_handle h = create(&f, 0); struct ios_stream *s = stream_from_handle(h);
    BYTE *data = (BYTE *)(uintptr_t)123;
    CHECK(get(h, 0, &data) == S_OK && data == (BYTE *)(uintptr_t)123);
    CHECK(get(h, 1, NULL) == E_POINTER);
    CHECK(get(h, UINT_MAX, &data) == AUDCLNT_E_BUFFER_TOO_LARGE && !data);
    CHECK(put(h, 1, 0) == AUDCLNT_E_OUT_OF_ORDER);
    CHECK(get(h, 100, &data) == S_OK && data == s->render_scratch);
    memset(data, 0x43, 100 * 4);
    CHECK(get(h, 3, &data) == AUDCLNT_E_OUT_OF_ORDER);
    CHECK(s->pending_frames == 100);
    CHECK(put(h, 101, 0) == AUDCLNT_E_INVALID_SIZE && s->pending_frames == 100);
    CHECK(put(h, 100, 4) == E_INVALIDARG && s->pending_frames == 100);
    CHECK(reset(h) == AUDCLNT_E_BUFFER_OPERATION_PENDING);
    CHECK(put(h, 100, 0) == S_OK && ios_padding(s) == 100);
    CHECK(start(h) == S_OK); CHECK(reset(h) == AUDCLNT_E_NOT_STOPPED);
    CHECK(stop(h) == S_OK); CHECK(reset(h) == S_OK && ios_padding(s) == 0);
    CHECK(get(h, s->buffer_frames, &data) == S_OK);
    CHECK(put(h, s->buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT) == S_OK);
    CHECK(get(h, 1, &data) == AUDCLNT_E_BUFFER_TOO_LARGE);
    CHECK(ios_padding(s) == s->buffer_frames);
    CHECK(reset(h) == S_OK);
    CHECK(get(h, 12, &data) == S_OK); CHECK(put(h, 0, 0) == S_OK && ios_padding(s) == 0);
    CHECK(get(h, 12, &data) == S_OK); CHECK(put(h, 6, 0) == S_OK && ios_padding(s) == 6);
    struct set_sample_rate_params rate = {.stream = h, .rate = 96000};
    ios_set_sample_rate(&rate); CHECK(rate.result == E_NOTIMPL && s->sample_rate == 48000);
    rate.rate = NAN; ios_set_sample_rate(&rate); CHECK(rate.result == E_INVALIDARG);
    rate.rate = 48000; ios_set_sample_rate(&rate); CHECK(rate.result == S_OK);
    release(h); CHECK(get(h, 1, &data) == AUDCLNT_E_NOT_INITIALIZED);
    CHECK(put(h, 1, 0) == AUDCLNT_E_NOT_INITIALIZED);
    stream_handle next = create(&f, 0); CHECK(h != next && !stream_from_handle(h)); release(next);
}

static void failures(void) {
    struct WAVEFORMATEX_stub f = format(16, 2, 48000, 1);
    for (int fail = 1; fail <= 3; ++fail) {
        fail_allocation = fail;
        stream_handle h = UINT64_MAX; UINT32 channels = 99;
        struct create_stream_params p = {.flow = eRender, .fmt = &f, .stream = &h, .channel_count = &channels};
        ios_create_stream(&p);
        CHECK(p.result == E_OUTOFMEMORY && h == 0 && channels == 0 && live_units() == 0);
        fail_allocation = 0;
    }
    stream_handle all[IOS_MAX_STREAMS];
    for (unsigned i = 0; i < IOS_MAX_STREAMS; ++i) all[i] = create(&f, 0);
    stream_handle h = UINT64_MAX;
    struct create_stream_params p = {.flow = eRender, .fmt = &f, .stream = &h};
    ios_create_stream(&p); CHECK(p.result == E_OUTOFMEMORY && h == 0 && live_units() == IOS_MAX_STREAMS);
    for (unsigned i = 0; i < IOS_MAX_STREAMS; ++i) release(all[i]);
    p.flow = eCapture; ios_create_stream(&p); CHECK(p.result == AUDCLNT_E_UNSUPPORTED_FORMAT && h == 0);
    p.flow = eRender; p.fmt = NULL; ios_create_stream(&p); CHECK(p.result == E_POINTER && h == 0);
    for (int fail = 1; fail <= 4; ++fail) {
        fail_setup = fail; h = create(&f, 0); struct ios_stream *s = stream_from_handle(h);
        CHECK(!s->au && live_units() == 0);
        BYTE *data; CHECK(get(h, UINT_MAX, &data) == AUDCLNT_E_BUFFER_TOO_LARGE);
        CHECK(get(h, 100, &data) == S_OK); CHECK(put(h, 100, 0) == S_OK);
        CHECK(start(h) == S_OK); atomic_fetch_add(&fake_ticks, 24000000); // one second
        CHECK(elapsed_frames(s) == 48000);
        CHECK(stop(h) == S_OK); CHECK(elapsed_frames(s) == 48000);
        CHECK(reset(h) == S_OK && elapsed_frames(s) == 0);
        release(h);
    }
    fail_setup = 0;
    CHECK(mach_to_ns(UINT64_C(10000000000000000)) == UINT64_C(416666666666666666));
    CHECK(mach_to_ns(UINT64_MAX) == UINT64_MAX);
}

static void *timer_entry(void *ctx) {
    struct timer_loop_params p = {.stream = *(stream_handle *)ctx}; ios_timer_loop(&p); return NULL;
}
static void timer_lifetime(void) {
    struct WAVEFORMATEX_stub f = format(16, 2, 48000, 1);
    stream_handle h = create(&f, 0); CHECK(start(h) == S_OK);
    struct set_event_handle_params event = {.stream = h, .event = (void *)(uintptr_t)1};
    ios_set_event_handle(&event); CHECK(event.result == S_OK);
    pthread_t thread; CHECK(pthread_create(&thread, NULL, timer_entry, &h) == 0);
    usleep(30000);
    _Atomic int joined = 0; timer_joined = &joined;
    struct release_stream_params p = {.stream = h, .timer_thread = &thread};
    ios_release_stream(&p);
    CHECK(p.result == S_OK && joined && !stream_from_handle(h) && live_units() == 0);
    timer_joined = NULL;
}

static OSStatus render(struct ios_stream *s, UINT32 frames, void *data, UINT32 bytes,
                       AudioUnitRenderActionFlags *flags) {
    AudioBufferList buffers = {.mNumberBuffers = 1, .mBuffers = {{s->channels, bytes, data}}};
    return s->au->cb.inputProc(s->au->cb.inputProcRefCon, flags, NULL, 0, frames, &buffers);
}
static UINT64 position(stream_handle h) {
    UINT64 pos = UINT64_MAX;
    struct get_position_params p = {.stream = h, .pos = &pos};
    ios_get_position(&p); CHECK(p.result == S_OK); return pos;
}
static void set_volume(stream_handle h, float master, const float *channels, const float *session) {
    struct set_volumes_params p = {h, master, channels, session}; ios_set_volumes(&p);
}
static void callback_contract(void) {
    struct WAVEFORMATEX_stub f = format(8, 2, 48000, 1);
    stream_handle h = create(&f, 0); struct ios_stream *s = stream_from_handle(h);
    BYTE out[130], *data; memset(out, 0xaa, sizeof(out));
    AudioUnitRenderActionFlags flags = 0;
    CHECK(start(h) == S_OK && start(h) == AUDCLNT_E_NOT_STOPPED);
    CHECK(render(s, 64, out + 1, 127, &flags) == kAudio_ParamError);
    CHECK(render(s, UINT32_MAX, out + 1, 128, &flags) == kAudio_ParamError);
    CHECK(render(s, 1, NULL, 128, &flags) == kAudio_ParamError);
    CHECK(render(s, 0, NULL, 0, &flags) == noErr);
    CHECK(ios_audio_render_cb(s, &flags, NULL, 0, 1, NULL) == kAudio_ParamError);
    AudioBufferList invalid = {.mNumberBuffers = 0};
    CHECK(ios_audio_render_cb(s, &flags, NULL, 0, 1, &invalid) == kAudio_ParamError);
    invalid.mNumberBuffers = 1; invalid.mBuffers[0].mNumberChannels = 1;
    CHECK(ios_audio_render_cb(s, &flags, NULL, 0, 1, &invalid) == kAudio_ParamError);
    for (unsigned i = 0; i < sizeof(out); ++i) CHECK(out[i] == 0xaa);
    CHECK(position(h) == 0 && !s->underruns);
    CHECK(render(s, 64, out + 1, 128, &flags) == noErr);
    CHECK(flags & kAudioUnitRenderAction_OutputIsSilence);
    for (unsigned i = 1; i <= 128; ++i) CHECK(out[i] == 128);
    CHECK(out[0] == 0xaa && out[129] == 0xaa);
    CHECK(position(h) == 64 && s->play_pos == 0 && s->underruns == 1);
    CHECK(get(h, 16, &data) == S_OK); memset(data, 37, 32); CHECK(put(h, 16, 0) == S_OK);
    flags = 0; CHECK(render(s, 64, out + 1, 128, &flags) == noErr);
    CHECK(!(flags & kAudioUnitRenderAction_OutputIsSilence));
    for (unsigned i = 1; i <= 128; ++i) CHECK(out[i] == (i <= 32 ? 37 : 128));
    CHECK(position(h) == 128 && s->play_pos == 16 && s->underruns == 2 && ios_padding(s) == 0);
    CHECK(stop(h) == S_OK && stop(h) == S_FALSE);
    atomic_fetch_add(&fake_ticks, 24000000); CHECK(position(h) == 128);
    CHECK(start(h) == S_OK);
    CHECK(render(s, 64, out + 1, 128, NULL) == noErr && position(h) == 192);
    CHECK(stop(h) == S_OK);
    fail_start = 1; CHECK(start(h) == S_OK && !s->au); fail_start = 0;
    CHECK(position(h) == 192); atomic_fetch_add(&fake_ticks, 24000000);
    CHECK(position(h) == 48192); CHECK(stop(h) == S_OK);
    CHECK(reset(h) == S_OK && position(h) == 0 && s->underruns == 0);
    release(h);
}
static int32_t read_integer(const BYTE *sample, unsigned bits) {
    if (bits == 8) return sample[0] - 128;
    if (bits == 16) { int16_t v; memcpy(&v, sample, 2); return v; }
    if (bits == 24) {
        int32_t v = sample[0] | (sample[1] << 8) | (sample[2] << 16);
        return v & 0x800000 ? v - 0x1000000 : v;
    }
    int32_t v; memcpy(&v, sample, 4); return v;
}
static void write_integer(BYTE *sample, unsigned bits, int32_t value) {
    if (bits == 8) { sample[0] = (BYTE)(value + 128); return; }
    uint32_t v = (uint32_t)value;
    for (unsigned i = 0; i < bits / 8; ++i) sample[i] = (BYTE)(v >> (8 * i));
}
static void volume_contract(void) {
    for (unsigned bits = 8; bits <= 32; bits += 8) {
        for (unsigned channels = 1; channels <= 2; ++channels) {
            struct WAVEFORMATEX_stub f = format(bits, channels, 48000, 1);
            stream_handle h = create(&f, 0); struct ios_stream *s = stream_from_handle(h);
            CHECK(atomic_is_lock_free(&s->gain_bits[0]) && atomic_is_lock_free(&s->clock_frames));
            int32_t minimum = bits == 32 ? INT32_MIN : -(1 << (bits - 1));
            int32_t maximum = bits == 32 ? INT32_MAX : (1 << (bits - 1)) - 1;
            int32_t values[] = {minimum, maximum, -1, 0, 1, minimum / 2, maximum / 2};
            enum { FRAMES = 7 };
            BYTE *data, out[FRAMES * 8 + 2];
            CHECK(get(h, FRAMES, &data) == S_OK);
            for (unsigned n = 0; n < FRAMES; ++n) for (unsigned ch = 0; ch < channels; ++ch)
                write_integer(data + n * f.nBlockAlign + ch * bits / 8, bits, values[n]);
            CHECK(put(h, FRAMES, 0) == S_OK);
            /* Volume is applied at consumption, including packets queued before the change. */
            float channel_gains[2] = {0.5f, 1}, session_gains[2] = {1, 0.5f};
            set_volume(h, 0.5f, channel_gains, session_gains);
            memset(out, 0xcc, sizeof(out));
            CHECK(render(s, FRAMES, out + 1, FRAMES * f.nBlockAlign, NULL) == noErr);
            for (unsigned n = 0; n < FRAMES; ++n) for (unsigned ch = 0; ch < channels; ++ch)
                CHECK(read_integer(out + 1 + n * f.nBlockAlign + ch * bits / 8, bits) ==
                      (int32_t)(values[n] * 0.25));
            CHECK(out[0] == 0xcc && out[1 + FRAMES * f.nBlockAlign] == 0xcc);
            for (unsigned round = 0; round < 4; ++round) {
                CHECK(get(h, FRAMES, &data) == S_OK);
                memset(data, 0xff, FRAMES * f.nBlockAlign); CHECK(put(h, FRAMES, 0) == S_OK);
                float gains[] = {0, -1, NAN, INFINITY}; set_volume(h, gains[round], NULL, NULL);
                AudioUnitRenderActionFlags flags = 0;
                CHECK(render(s, FRAMES, out + 1, FRAMES * f.nBlockAlign, &flags) == noErr);
                CHECK(flags & kAudioUnitRenderAction_OutputIsSilence);
                for (unsigned i = 0; i < FRAMES * f.nBlockAlign; ++i) CHECK(out[1 + i] == s->silence_byte);
            }
            set_volume(h, 2, NULL, NULL); // clamp; unity remains bit-exact
            CHECK(get(h, FRAMES, &data) == S_OK);
            for (unsigned i = 0; i < FRAMES * f.nBlockAlign; ++i) data[i] = (BYTE)(i * 37);
            BYTE expected[FRAMES * 8]; memcpy(expected, data, FRAMES * f.nBlockAlign);
            CHECK(put(h, FRAMES, 0) == S_OK);
            CHECK(render(s, FRAMES, out + 1, FRAMES * f.nBlockAlign, NULL) == noErr);
            CHECK(!memcmp(out + 1, expected, FRAMES * f.nBlockAlign));
            release(h);
        }
    }
    struct WAVEFORMATEX_stub f = format(32, 2, 48000, 3);
    stream_handle h = create(&f, 0); struct ios_stream *s = stream_from_handle(h);
    float values[] = {1, -1, 0.5f, -0.5f, NAN, INFINITY}; BYTE *data;
    CHECK(get(h, 3, &data) == S_OK); memcpy(data, values, sizeof(values)); CHECK(put(h, 3, 0) == S_OK);
    float gains[] = {0.5f, 0}; set_volume(h, 1, gains, NULL);
    BYTE output[sizeof(values) + 1]; CHECK(render(s, 3, output + 1, sizeof(values), NULL) == noErr);
    float result[6]; memcpy(result, output + 1, sizeof(result));
    CHECK(result[0] == 0.5f && result[1] == 0 && result[2] == 0.25f && result[3] == 0);
    CHECK(result[4] == 0 && result[5] == 0);
    release(h);
}

/* The production producer and callback run concurrently. Each frame carries
 * a 32-bit sequence number in two PCM16 channels; check no loss, duplication,
 * tearing or reordering across repeated ring wraps and arbitrary packet sizes. */
struct stress_context { struct ios_stream *s; stream_handle handle; uint32_t frames; };
static void *stress_producer(void *arg) {
    struct stress_context *ctx = arg; uint32_t next = 1;
    while (next <= ctx->frames) {
        uint32_t count = (next * 17u % 197u) + 1;
        if (count > ctx->frames + 1 - next) count = ctx->frames + 1 - next;
        BYTE *data; HRESULT hr = get(ctx->handle, count, &data);
        if (hr == AUDCLNT_E_BUFFER_TOO_LARGE) { sched_yield(); continue; }
        assert(hr == S_OK);
        for (unsigned i = 0; i < count; ++i) { uint32_t value = next + i; memcpy(data + 4 * i, &value, 4); }
        assert(put(ctx->handle, count, 0) == S_OK); next += count;
    }
    return NULL;
}
static void concurrent_ring(void) {
    struct WAVEFORMATEX_stub f = format(16, 2, 48000, 1);
    stream_handle h = create(&f, 0); struct ios_stream *s = stream_from_handle(h);
    struct stress_context ctx = {s, h, 1000000};
    pthread_t producer; CHECK(pthread_create(&producer, NULL, stress_producer, &ctx) == 0);
    uint32_t next = 1; uint64_t rendered = 0;
    while (next <= ctx.frames) {
        uint32_t count = (next * 13u % 251u) + 1, output[251];
        uint64_t before = s->play_pos;
        CHECK(render(s, count, output, sizeof(output), NULL) == noErr);
        unsigned copied = (unsigned)(s->play_pos - before);
        CHECK(copied <= count);
        for (unsigned i = 0; i < copied; ++i) CHECK(output[i] == next++);
        for (unsigned i = copied; i < count; ++i) CHECK(output[i] == 0);
        rendered += count;
        if (!copied) sched_yield();
    }
    CHECK(pthread_join(producer, NULL) == 0);
    CHECK(s->play_pos == ctx.frames && s->write_pos == ctx.frames && ios_padding(s) == 0);
    CHECK(s->clock_frames == rendered);
    release(h);
}

int main(void) {
    ios_process_attach(NULL);
    CHECK(sizeof(audio_null_ios_unix_call_funcs) / sizeof(void *) == 37);
    formats(); buffer_contract(); failures(); timer_lifetime();
    callback_contract(); volume_contract(); concurrent_ring();
    CHECK(live_units() == 0);
    for (unsigned i = 0; i < IOS_MAX_STREAMS; ++i) CHECK(g_streams[i] == NULL);
    printf("Audio driver contracts: %lu checks passed (Apple/Nt boundaries mocked)\n", checks);
    return 0;
}

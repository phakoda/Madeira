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

int main(void) {
    ios_process_attach(NULL);
    CHECK(sizeof(audio_null_ios_unix_call_funcs) / sizeof(void *) == 37);
    formats(); buffer_contract(); failures(); timer_lifetime();
    CHECK(live_units() == 0);
    for (unsigned i = 0; i < IOS_MAX_STREAMS; ++i) CHECK(g_streams[i] == NULL);
    printf("Audio driver contracts: %lu checks passed (Apple/Nt boundaries mocked)\n", checks);
    return 0;
}

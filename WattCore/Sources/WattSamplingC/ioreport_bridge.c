#include "WattSamplingC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

/*
 * IOReport: system + per-cluster energy counters
 * ──────────────────────────────────────────────
 * IOReport exposes a unified counter system the kernel populates from each
 * driver. Activity Monitor's "Energy" column reads from this. The framework
 * is exported from IOKit.framework but headers live in a private
 * IOReport.framework; we resolve symbols dynamically so the build doesn't
 * depend on private SDK paths.
 *
 * The "Energy Model" group is the right one for our purposes. Each channel
 * is a cumulative joule counter keyed by channel name; `Delta` gives joules
 * accrued since the previous sample.
 */

typedef struct __IOReportSubscription   *IOReportSubscriptionRef;
typedef int (*IOReportSampleCallback)(int kIOReportIterOk, CFDictionaryRef chan);

typedef CFMutableDictionaryRef (*IOReportCopyChannelsInGroup_f)(
    CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
typedef IOReportSubscriptionRef (*IOReportCreateSubscription_f)(
    void *a, CFMutableDictionaryRef desired,
    CFMutableDictionaryRef *subbedChannels, uint64_t channel_id, CFTypeRef b);
typedef CFDictionaryRef (*IOReportCreateSamples_f)(
    IOReportSubscriptionRef sub, CFMutableDictionaryRef subbed, CFTypeRef a);
typedef CFDictionaryRef (*IOReportCreateSamplesDelta_f)(
    CFDictionaryRef prev, CFDictionaryRef curr, CFTypeRef a);
typedef int (*IOReportIterate_f)(CFDictionaryRef samples, IOReportSampleCallback cb);
typedef CFStringRef (*IOReportChannelGetGroup_f)(CFDictionaryRef ch);
typedef CFStringRef (*IOReportChannelGetSubGroup_f)(CFDictionaryRef ch);
typedef CFStringRef (*IOReportChannelGetChannelName_f)(CFDictionaryRef ch);
typedef int64_t (*IOReportSimpleGetIntegerValue_f)(CFDictionaryRef ch, int unit);

static IOReportCopyChannelsInGroup_f       p_copyChannelsInGroup;
static IOReportCreateSubscription_f        p_createSubscription;
static IOReportCreateSamples_f             p_createSamples;
static IOReportCreateSamplesDelta_f        p_createSamplesDelta;
static IOReportIterate_f                   p_iterate;
static IOReportChannelGetGroup_f           p_chGetGroup;
static IOReportChannelGetSubGroup_f        p_chGetSubGroup;
static IOReportChannelGetChannelName_f     p_chGetChannelName;
static IOReportSimpleGetIntegerValue_f     p_chGetIntegerValue;

static IOReportSubscriptionRef g_sub;
static CFMutableDictionaryRef  g_subbedChannels;
static CFDictionaryRef         g_priorSamples;
static uint64_t                g_priorAbsTime;
static int                     g_resolved; /* 0=not tried, 1=ok, -1=fail */
static pthread_mutex_t         g_lock = PTHREAD_MUTEX_INITIALIZER;

#define KIORPT_ITER_OK 0

static int resolve_symbols(void) {
    if (g_resolved != 0) return g_resolved == 1;
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit) { g_resolved = -1; return 0; }

    p_copyChannelsInGroup    = (IOReportCopyChannelsInGroup_f)       dlsym(iokit, "IOReportCopyChannelsInGroup");
    p_createSubscription     = (IOReportCreateSubscription_f)        dlsym(iokit, "IOReportCreateSubscription");
    p_createSamples          = (IOReportCreateSamples_f)             dlsym(iokit, "IOReportCreateSamples");
    p_createSamplesDelta     = (IOReportCreateSamplesDelta_f)        dlsym(iokit, "IOReportCreateSamplesDelta");
    p_iterate                = (IOReportIterate_f)                   dlsym(iokit, "IOReportIterate");
    p_chGetGroup             = (IOReportChannelGetGroup_f)           dlsym(iokit, "IOReportChannelGetGroup");
    p_chGetSubGroup          = (IOReportChannelGetSubGroup_f)        dlsym(iokit, "IOReportChannelGetSubGroup");
    p_chGetChannelName       = (IOReportChannelGetChannelName_f)     dlsym(iokit, "IOReportChannelGetChannelName");
    p_chGetIntegerValue      = (IOReportSimpleGetIntegerValue_f)     dlsym(iokit, "IOReportSimpleGetIntegerValue");

    int ok = (p_copyChannelsInGroup && p_createSubscription && p_createSamples
              && p_createSamplesDelta && p_iterate && p_chGetGroup
              && p_chGetSubGroup && p_chGetChannelName && p_chGetIntegerValue);
    g_resolved = ok ? 1 : -1;
    return ok;
}

int watt_ioreport_open(void) {
    pthread_mutex_lock(&g_lock);
    if (!resolve_symbols()) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    if (g_sub != NULL) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }

    CFMutableDictionaryRef channels = p_copyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    CFMutableDictionaryRef subbed = NULL;
    g_sub = p_createSubscription(NULL, channels, &subbed, 0, NULL);
    g_subbedChannels = subbed;
    CFRelease(channels);
    if (!g_sub) {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    pthread_mutex_unlock(&g_lock);
    return 0;
}

void watt_ioreport_close(void) {
    pthread_mutex_lock(&g_lock);
    if (g_priorSamples) { CFRelease(g_priorSamples); g_priorSamples = NULL; }
    if (g_subbedChannels) { CFRelease(g_subbedChannels); g_subbedChannels = NULL; }
    /* IOReportSubscriptionRef is leaked deliberately; the public docs don't
     * provide a free function, and Activity Monitor leaves its subscription
     * alive for the lifetime of the process. */
    g_sub = NULL;
    g_priorAbsTime = 0;
    pthread_mutex_unlock(&g_lock);
}

static double abs_to_seconds(uint64_t delta) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    if (tb.denom == 0) return 0;
    return ((double)delta) * ((double)tb.numer / (double)tb.denom) / 1e9;
}

/* Sum of nJ accrued for each accumulator key during this delta. */
typedef struct {
    double total_nj;
    double cpu_nj;
    double gpu_nj;
    double ane_nj;
    double dram_nj;
} accum_t;

static accum_t g_accum;

static int sample_callback(int status, CFDictionaryRef chan) {
    if (status != KIORPT_ITER_OK) return KIORPT_ITER_OK;
    CFStringRef chName = p_chGetChannelName(chan);
    if (!chName) return KIORPT_ITER_OK;

    int64_t value = p_chGetIntegerValue(chan, 0);
    if (value <= 0) return KIORPT_ITER_OK;
    double nj = (double)value;

    char namebuf[128] = {0};
    CFStringGetCString(chName, namebuf, sizeof(namebuf), kCFStringEncodingUTF8);

    /* Channels we care about. The exact list varies across Apple Silicon
     * SoCs (M1/M2/M3/M4 each name them slightly differently). The strategy
     * is: total = sum of every channel; per-bucket = pattern-match the name. */
    g_accum.total_nj += nj;

    /* CPU: anything containing "CPU" but not "GPU" */
    if (strstr(namebuf, "CPU") && !strstr(namebuf, "GPU")) {
        g_accum.cpu_nj += nj;
    }
    /* P/E cluster names on M1/M2: "ECPU Energy", "PCPU Energy" */
    if (strstr(namebuf, "ECPU") || strstr(namebuf, "PCPU")) {
        g_accum.cpu_nj += nj;
    }
    if (strstr(namebuf, "GPU")) {
        g_accum.gpu_nj += nj;
    }
    if (strstr(namebuf, "ANE") || strstr(namebuf, "Neural")) {
        g_accum.ane_nj += nj;
    }
    if (strstr(namebuf, "DRAM")) {
        g_accum.dram_nj += nj;
    }
    return KIORPT_ITER_OK;
}

/* Block-style callback wrapper. IOReportIterate takes a block; we use a
 * static accumulator so we don't have to wrestle with Block_copy. */
static int dispatch_callback(int s, CFDictionaryRef ch) { return sample_callback(s, ch); }

int watt_ioreport_sample(watt_power_sample_t *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));

    pthread_mutex_lock(&g_lock);
    if (g_sub == NULL) { pthread_mutex_unlock(&g_lock); return -1; }

    CFDictionaryRef current = p_createSamples(g_sub, g_subbedChannels, NULL);
    if (!current) { pthread_mutex_unlock(&g_lock); return -1; }
    uint64_t now = mach_absolute_time();

    if (!g_priorSamples) {
        g_priorSamples = current;
        g_priorAbsTime = now;
        pthread_mutex_unlock(&g_lock);
        return 0;
    }

    CFDictionaryRef delta = p_createSamplesDelta(g_priorSamples, current, NULL);
    if (delta) {
        memset(&g_accum, 0, sizeof(g_accum));
        /* IOReportIterate takes an Objective-C block on real Apple
         * platforms; we call the underscore C variant so we can pass a
         * plain function pointer and avoid pulling Block.framework into
         * a vanilla C compilation unit. */
        p_iterate(delta, (IOReportSampleCallback)dispatch_callback);
        CFRelease(delta);
    }

    double elapsed = abs_to_seconds(now - g_priorAbsTime);
    if (elapsed <= 0) elapsed = 1; /* defensive */

    out->total_watts     = g_accum.total_nj / 1e9 / elapsed;
    out->cpu_watts       = g_accum.cpu_nj   / 1e9 / elapsed;
    out->gpu_watts       = g_accum.gpu_nj   / 1e9 / elapsed;
    out->ane_watts       = g_accum.ane_nj   / 1e9 / elapsed;
    out->dram_watts      = g_accum.dram_nj  / 1e9 / elapsed;
    out->elapsed_seconds = elapsed;

    CFRelease(g_priorSamples);
    g_priorSamples = current;
    g_priorAbsTime = now;
    pthread_mutex_unlock(&g_lock);
    return 0;
}

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
/* IOReportIterate's callback is an Objective-C block, not a C function
 * pointer. Block calling convention takes an opaque pointer (the block
 * struct) as its first arg, then the documented args. We declare a typedef
 * for the block type so we can pass real ^{} blocks. */
typedef int (^IOReportSampleCallback)(CFDictionaryRef chan);

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
typedef CFStringRef (*IOReportChannelGetUnitLabel_f)(CFDictionaryRef ch);
typedef int64_t (*IOReportSimpleGetIntegerValue_f)(CFDictionaryRef ch, int unit);

static IOReportCopyChannelsInGroup_f       p_copyChannelsInGroup;
static IOReportCreateSubscription_f        p_createSubscription;
static IOReportCreateSamples_f             p_createSamples;
static IOReportCreateSamplesDelta_f        p_createSamplesDelta;
static IOReportIterate_f                   p_iterate;
static IOReportChannelGetGroup_f           p_chGetGroup;
static IOReportChannelGetSubGroup_f        p_chGetSubGroup;
static IOReportChannelGetChannelName_f     p_chGetChannelName;
static IOReportChannelGetUnitLabel_f       p_chGetUnitLabel;
static IOReportSimpleGetIntegerValue_f     p_chGetIntegerValue;

static IOReportSubscriptionRef g_sub;
static CFMutableDictionaryRef  g_subbedChannels;
static CFDictionaryRef         g_priorSamples;
static uint64_t                g_priorAbsTime;
static int                     g_resolved; /* 0=not tried, 1=ok, -1=fail */
static pthread_mutex_t         g_lock = PTHREAD_MUTEX_INITIALIZER;

#define KIORPT_ITER_OK    0
#define KIORPT_ITER_FAILED 0x10000

static int resolve_symbols(void) {
    if (g_resolved != 0) return g_resolved == 1;
    /* IOReport symbols live in libIOReport.dylib (resolved from the dyld
     * shared cache on macOS 11+). They are NOT in IOKit.framework despite
     * what older docs imply. */
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!lib) {
        lib = dlopen("libIOReport.dylib", RTLD_LAZY);
    }
    if (!lib) { g_resolved = -1; return 0; }

    p_copyChannelsInGroup    = (IOReportCopyChannelsInGroup_f)       dlsym(lib, "IOReportCopyChannelsInGroup");
    p_createSubscription     = (IOReportCreateSubscription_f)        dlsym(lib, "IOReportCreateSubscription");
    p_createSamples          = (IOReportCreateSamples_f)             dlsym(lib, "IOReportCreateSamples");
    p_createSamplesDelta     = (IOReportCreateSamplesDelta_f)        dlsym(lib, "IOReportCreateSamplesDelta");
    p_iterate                = (IOReportIterate_f)                   dlsym(lib, "IOReportIterate");
    p_chGetGroup             = (IOReportChannelGetGroup_f)           dlsym(lib, "IOReportChannelGetGroup");
    p_chGetSubGroup          = (IOReportChannelGetSubGroup_f)        dlsym(lib, "IOReportChannelGetSubGroup");
    p_chGetChannelName       = (IOReportChannelGetChannelName_f)     dlsym(lib, "IOReportChannelGetChannelName");
    p_chGetUnitLabel         = (IOReportChannelGetUnitLabel_f)       dlsym(lib, "IOReportChannelGetUnitLabel");
    p_chGetIntegerValue      = (IOReportSimpleGetIntegerValue_f)     dlsym(lib, "IOReportSimpleGetIntegerValue");

    int ok = (p_copyChannelsInGroup && p_createSubscription && p_createSamples
              && p_createSamplesDelta && p_iterate && p_chGetGroup
              && p_chGetSubGroup && p_chGetChannelName
              /* p_chGetUnitLabel is optional — older macOS may not have it */
              && p_chGetIntegerValue);
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

static double channel_value_in_nanojoules(CFDictionaryRef chan, int64_t raw) {
    /* IOReport energy values come in different units depending on the
     * channel — the unit label tells us which. Empirically on Apple Silicon
     * (M-series) the rolled-up Energy Model channels report milli-joules,
     * but the kernel sometimes labels them "mJ", "uJ", "nJ", or just
     * "Energy" with an implicit unit. We normalise to nanojoules. */
    if (!p_chGetUnitLabel) {
        /* Pre-macOS-12 fallback: assume nanojoules. */
        return (double)raw;
    }
    CFStringRef unitLabel = p_chGetUnitLabel(chan);
    if (!unitLabel) return (double)raw;
    char buf[32] = {0};
    CFStringGetCString(unitLabel, buf, sizeof(buf), kCFStringEncodingUTF8);

    /* Look for the multiplier prefix. The label is something like
     * "Energy (mJ)", "uJ", "nJ", "pJ", or "fJ". */
    double scale = 1.0; /* default: assume nanojoules */
    if      (strstr(buf, "mJ")) scale = 1e6;   /* millijoules → ns */
    else if (strstr(buf, "uJ")) scale = 1e3;   /* microjoules → ns */
    else if (strstr(buf, "nJ")) scale = 1.0;
    else if (strstr(buf, "pJ")) scale = 1e-3;
    else if (strstr(buf, "fJ")) scale = 1e-6;
    /* Some channels report ticks; a heuristic fallback for those is to
     * trust nanojoules. */
    return (double)raw * scale;
}

static void accumulate_channel(accum_t *acc, CFDictionaryRef chan) {
    CFStringRef chName = p_chGetChannelName(chan);
    if (!chName) return;

    int64_t value = p_chGetIntegerValue(chan, 0);
    if (value <= 0) return;
    double nj = channel_value_in_nanojoules(chan, value);

    char namebuf[128] = {0};
    CFStringGetCString(chName, namebuf, sizeof(namebuf), kCFStringEncodingUTF8);

    /* Apple Silicon's IOReport "Energy Model" group ships both rolled-up
     * top-level channels and per-core/per-cluster subdivisions. We use ONLY
     * the rolled-up channels so we don't double-count. The names are stable
     * across M1/M2/M3/M4 SoCs (verified empirically on M-series).
     *
     * Top-level channel names we read:
     *   "CPU Energy"  – sum of E + P clusters
     *   "GPU"         – GPU complex
     *   "ANE"         – Apple Neural Engine
     *   "DRAM"        – memory subsystem
     *   "DISP"        – display
     *   "AMCC"        – memory controller
     *   "AFR"         – fabric / always-on
     *   "AVE", "ISP", "FAB" – various media/fabric blocks
     *
     * For our snapshot we report CPU/GPU/ANE/DRAM individually and a total
     * that sums the entire Energy Model group (all the rolled-up channels
     * only), not just CPU+GPU+ANE+DRAM. That way "total watts" on the menu
     * actually matches what Activity Monitor reports as system power.
     */
    int matched = 0;
    if (strcmp(namebuf, "CPU Energy") == 0) {
        acc->cpu_nj += nj; matched = 1;
    } else if (strcmp(namebuf, "GPU") == 0 || strcmp(namebuf, "GPU Energy") == 0) {
        acc->gpu_nj += nj; matched = 1;
    } else if (strcmp(namebuf, "ANE") == 0 || strcmp(namebuf, "ANE Energy") == 0) {
        acc->ane_nj += nj; matched = 1;
    } else if (strcmp(namebuf, "DRAM") == 0 || strcmp(namebuf, "DRAM Energy") == 0) {
        acc->dram_nj += nj; matched = 1;
    } else if (strcmp(namebuf, "DISP") == 0 ||
               strcmp(namebuf, "AMCC") == 0 ||
               strcmp(namebuf, "AFR")  == 0 ||
               strcmp(namebuf, "AVE")  == 0 ||
               strcmp(namebuf, "ISP")  == 0 ||
               strcmp(namebuf, "FAB")  == 0) {
        matched = 1;
    }
    if (matched) {
        acc->total_nj += nj;
    }
}

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

    accum_t accum;
    memset(&accum, 0, sizeof(accum));

    CFDictionaryRef delta = p_createSamplesDelta(g_priorSamples, current, NULL);
    if (delta) {
        accum_t *accumPtr = &accum;
        p_iterate(delta, ^int (CFDictionaryRef chan) {
            accumulate_channel(accumPtr, chan);
            return KIORPT_ITER_OK;
        });
        CFRelease(delta);
    }

    double elapsed = abs_to_seconds(now - g_priorAbsTime);
    if (elapsed <= 0) elapsed = 1; /* defensive */

    out->total_watts     = accum.total_nj / 1e9 / elapsed;
    out->cpu_watts       = accum.cpu_nj   / 1e9 / elapsed;
    out->gpu_watts       = accum.gpu_nj   / 1e9 / elapsed;
    out->ane_watts       = accum.ane_nj   / 1e9 / elapsed;
    out->dram_watts      = accum.dram_nj  / 1e9 / elapsed;
    out->elapsed_seconds = elapsed;

    CFRelease(g_priorSamples);
    g_priorSamples = current;
    g_priorAbsTime = now;
    pthread_mutex_unlock(&g_lock);
    return 0;
}

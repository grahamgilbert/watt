#include "WattSamplingC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

/*
 * IOHIDEventSystemClient is a private API used by Activity Monitor, stats, and
 * iStat Menus to read fan RPM and per-die temperatures on Apple Silicon.
 * It is exported from /System/Library/Frameworks/IOKit.framework/IOKit.
 *
 * We resolve symbols dynamically at first use so a build that lacks any of
 * them simply returns "no readings" instead of failing to link.
 */

#ifndef WATT_USE_PRIVATE_HID

int watt_read_temperatures(watt_temp_reading_t *out, int out_capacity) {
    (void)out; (void)out_capacity;
    return 0;
}
int watt_read_fans(watt_fan_reading_t *out, int out_capacity) {
    (void)out; (void)out_capacity;
    return 0;
}

#else

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient      *IOHIDServiceClientRef;
typedef struct __IOHIDEvent              *IOHIDEventRef;

typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreate_f)(CFAllocatorRef);
typedef int                       (*IOHIDEventSystemClientSetMatching_f)(IOHIDEventSystemClientRef, CFDictionaryRef);
typedef CFArrayRef                (*IOHIDEventSystemClientCopyServices_f)(IOHIDEventSystemClientRef);
typedef CFTypeRef                 (*IOHIDServiceClientCopyProperty_f)(IOHIDServiceClientRef, CFStringRef);
typedef IOHIDEventRef             (*IOHIDServiceClientCopyEvent_f)(IOHIDServiceClientRef, int64_t type, int32_t options, int64_t timeout);
typedef double                    (*IOHIDEventGetFloatValue_f)(IOHIDEventRef, int32_t field);

#define WATT_kIOHIDEventTypeTemperature 15
#define WATT_kIOHIDEventTypeFanSpeed    9
#define WATT_IOHIDEventFieldBase(t)     (((int32_t)(t)) << 16)

static IOHIDEventSystemClientCreate_f       p_clientCreate;
static IOHIDEventSystemClientSetMatching_f  p_setMatching;
static IOHIDEventSystemClientCopyServices_f p_copyServices;
static IOHIDServiceClientCopyProperty_f     p_serviceCopyProperty;
static IOHIDServiceClientCopyEvent_f        p_serviceCopyEvent;
static IOHIDEventGetFloatValue_f            p_eventGetFloat;
static int p_resolved = 0;
static pthread_mutex_t p_lock = PTHREAD_MUTEX_INITIALIZER;

static int resolve_symbols(void) {
    pthread_mutex_lock(&p_lock);
    if (p_resolved != 0) {
        int ok = (p_resolved > 0);
        pthread_mutex_unlock(&p_lock);
        return ok;
    }
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit) {
        p_resolved = -1;
        pthread_mutex_unlock(&p_lock);
        return 0;
    }
    p_clientCreate        = (IOHIDEventSystemClientCreate_f)       dlsym(iokit, "IOHIDEventSystemClientCreate");
    p_setMatching         = (IOHIDEventSystemClientSetMatching_f)  dlsym(iokit, "IOHIDEventSystemClientSetMatching");
    p_copyServices        = (IOHIDEventSystemClientCopyServices_f) dlsym(iokit, "IOHIDEventSystemClientCopyServices");
    p_serviceCopyProperty = (IOHIDServiceClientCopyProperty_f)     dlsym(iokit, "IOHIDServiceClientCopyProperty");
    p_serviceCopyEvent    = (IOHIDServiceClientCopyEvent_f)        dlsym(iokit, "IOHIDServiceClientCopyEvent");
    p_eventGetFloat       = (IOHIDEventGetFloatValue_f)            dlsym(iokit, "IOHIDEventGetFloatValue");

    int all = (p_clientCreate && p_setMatching && p_copyServices &&
               p_serviceCopyProperty && p_serviceCopyEvent && p_eventGetFloat);
    p_resolved = all ? 1 : -1;
    pthread_mutex_unlock(&p_lock);
    return all;
}

static CFDictionaryRef build_match(int32_t usage_page, int32_t usage) {
    CFNumberRef pageNum  = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage_page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage);
    const void *keys[]   = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { pageNum, usageNum };
    CFDictionaryRef d = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                           &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    CFRelease(pageNum);
    CFRelease(usageNum);
    return d;
}

static int read_kind(int32_t usage_page, int32_t usage,
                     int64_t event_type,
                     char *name_out, double *value_out,
                     int max_count,
                     void *generic_out, int reading_size) {
    if (!resolve_symbols()) return 0;

    IOHIDEventSystemClientRef client = p_clientCreate(kCFAllocatorDefault);
    if (!client) return 0;

    CFDictionaryRef match = build_match(usage_page, usage);
    p_setMatching(client, match);
    CFRelease(match);

    CFArrayRef services = p_copyServices(client);
    if (!services) {
        CFRelease(client);
        return 0;
    }

    int written = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count && written < max_count; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);

        IOHIDEventRef event = p_serviceCopyEvent(svc, event_type, 0, 0);
        if (!event) continue;
        double value = p_eventGetFloat(event, WATT_IOHIDEventFieldBase(event_type));
        CFRelease(event);

        char name[128] = {0};
        CFStringRef product = (CFStringRef)p_serviceCopyProperty(svc, CFSTR("Product"));
        if (product) {
            CFStringGetCString(product, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(product);
        } else {
            snprintf(name, sizeof(name), "sensor-%ld", (long)i);
        }

        unsigned char *slot = ((unsigned char *)generic_out) + (size_t)written * (size_t)reading_size;
        memcpy(slot, name, sizeof(name));
        memcpy(slot + sizeof(name), &value, sizeof(double));
        written++;
    }

    CFRelease(services);
    CFRelease(client);
    (void)name_out; (void)value_out;
    return written;
}

int watt_read_temperatures(watt_temp_reading_t *out, int out_capacity) {
    if (!out || out_capacity <= 0) return 0;
    return read_kind(0xFF00, 5, WATT_kIOHIDEventTypeTemperature,
                     NULL, NULL, out_capacity,
                     out, (int)sizeof(watt_temp_reading_t));
}

int watt_read_fans(watt_fan_reading_t *out, int out_capacity) {
    if (!out || out_capacity <= 0) return 0;
    return read_kind(0xFF00, 2, WATT_kIOHIDEventTypeFanSpeed,
                     NULL, NULL, out_capacity,
                     out, (int)sizeof(watt_fan_reading_t));
}

#endif /* WATT_USE_PRIVATE_HID */

#ifndef WATT_SAMPLING_C_H
#define WATT_SAMPLING_C_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/resource.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <mach/host_info.h>

/*
 * libproc + rusage wrappers
 * ─────────────────────────
 * libproc.h declares these but Swift can't always import them via the
 * Darwin module map cleanly; explicit re-declaration in our umbrella header
 * makes them visible without #if-importing every translation unit.
 */
int watt_proc_listallpids(int32_t *buffer, int buffersize_bytes);
int watt_proc_name(int pid, char *buffer, uint32_t buffersize);
/// Absolute executable path for `pid`. Works without privilege for any
/// process visible to libproc (including root-owned daemons we can't
/// rusage). Returns the number of bytes written, 0 if not available.
int watt_proc_pidpath(int pid, char *buffer, uint32_t buffersize);
int watt_proc_pid_rusage_v6(int pid, struct rusage_info_v6 *out);

/*
 * host_processor_info wrapper
 * ───────────────────────────
 * Returns malloc'd processor_cpu_load_info; caller must vm_deallocate it.
 * Out params: cpu_count, info_count (machine-word count), info pointer.
 */
kern_return_t watt_host_processor_load(natural_t *cpu_count_out,
                                       processor_cpu_load_info_t *info_out,
                                       mach_msg_type_number_t *info_count_out);

void watt_vm_deallocate_info(vm_address_t addr, mach_msg_type_number_t count);

/*
 * host_statistics64(HOST_VM_INFO64) wrapper.
 */
kern_return_t watt_host_vm_statistics64(struct vm_statistics64 *out);

/*
 * Page size, sampled once.
 */
uint64_t watt_page_size(void);

/*
 * IOHIDEventSystem private bridge (Apple Sensors)
 * ───────────────────────────────────────────────
 * All four functions are no-ops returning empty data when WATT_USE_PRIVATE_HID
 * is not defined at compile time, so the public surface is stable either way.
 */
typedef struct {
    char  name[128];
    double valueCelsius;
} watt_temp_reading_t;

typedef struct {
    char  name[128];
    double rpm;
} watt_fan_reading_t;

/* Returns number of readings written into out (capped at out_capacity).
 * Returns -1 on failure. */
int watt_read_temperatures(watt_temp_reading_t *out, int out_capacity);
int watt_read_fans(watt_fan_reading_t *out, int out_capacity);

/*
 * IOReport bridge — system / per-cluster power
 * ────────────────────────────────────────────
 * Reads cumulative joules counters out of IOKit's IOReport framework. The
 * framework is exported from IOKit.framework but its headers ship in the
 * private IOReport.framework, so we resolve symbols via dlopen.
 *
 * Lifecycle:
 *   watt_ioreport_open()    -> 0 on success, -1 on failure (treat as
 *                              "no IOReport support, fall back").
 *   watt_ioreport_sample()  -> reads the latest cumulative counters into the
 *                              buffer and returns elapsed-since-prior. The
 *                              first call seeds the prior values and returns
 *                              0 watts; subsequent calls return real data.
 *   watt_ioreport_close()   -> tears the subscription down.
 *
 * `watt_power_sample_t` is the per-tick aggregate exposed to Swift. All
 * fields are joules-per-second across the elapsed interval.
 */
typedef struct {
    double total_watts;     /* package + cluster + GPU + neural; whole SoC */
    double cpu_watts;       /* sum of P-cluster + E-cluster */
    double gpu_watts;
    double ane_watts;       /* Apple Neural Engine */
    double dram_watts;
    double elapsed_seconds; /* time since last call to sample(), 0 on first */
} watt_power_sample_t;

int  watt_ioreport_open(void);
int  watt_ioreport_sample(watt_power_sample_t *out);
void watt_ioreport_close(void);

#endif /* WATT_SAMPLING_C_H */

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

#endif /* WATT_SAMPLING_C_H */

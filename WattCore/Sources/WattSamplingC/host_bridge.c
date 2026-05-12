#include "WattSamplingC.h"

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <unistd.h>

kern_return_t watt_host_processor_load(natural_t *cpu_count_out,
                                       processor_cpu_load_info_t *info_out,
                                       mach_msg_type_number_t *info_count_out) {
    return host_processor_info(mach_host_self(),
                               PROCESSOR_CPU_LOAD_INFO,
                               cpu_count_out,
                               (processor_info_array_t *)info_out,
                               info_count_out);
}

void watt_vm_deallocate_info(vm_address_t addr, mach_msg_type_number_t count) {
    if (addr == 0 || count == 0) {
        return;
    }
    vm_deallocate(mach_task_self(), addr, count * sizeof(integer_t));
}

kern_return_t watt_host_vm_statistics64(struct vm_statistics64 *out) {
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    return host_statistics64(mach_host_self(),
                             HOST_VM_INFO64,
                             (host_info64_t)out,
                             &count);
}

uint64_t watt_page_size(void) {
    long sz = sysconf(_SC_PAGESIZE);
    return sz > 0 ? (uint64_t)sz : 16384u;
}

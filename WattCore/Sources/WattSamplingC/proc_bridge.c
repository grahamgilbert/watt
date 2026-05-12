#include "WattSamplingC.h"

#include <libproc.h>
#include <sys/resource.h>
#include <stdlib.h>

int watt_proc_listallpids(int32_t *buffer, int buffersize_bytes) {
    return proc_listallpids(buffer, buffersize_bytes);
}

int watt_proc_name(int pid, char *buffer, uint32_t buffersize) {
    return proc_name(pid, buffer, buffersize);
}

int watt_proc_pid_rusage_v6(int pid, struct rusage_info_v6 *out) {
    /*
     * Despite the misleading `rusage_info_t *` (which is `void **`) signature,
     * proc_pid_rusage expects a *single-level* pointer to the destination
     * buffer; the kernel writes into the memory you point at. Passing the
     * address of a local `void *` (as the libproc.h prototype suggests)
     * causes the kernel to scribble all over the stack.
     */
    return proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)out);
}

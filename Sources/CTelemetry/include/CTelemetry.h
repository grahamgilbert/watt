#include <stdint.h>
#include <sqlite3.h>
typedef struct { uint64_t user, system, idle, memory, compressed, swap, rx, tx; } WattSystem;
// Identity remains observable even when macOS withholds another user's counters.
// Unavailable counters are zero-initialized and must be gated on metrics_available.
typedef struct { int32_t pid, parent; uint32_t uid; uint64_t start, cpu, footprint, read, written, energy_nj, idle_wakeups, interrupt_wakeups; int metrics_available, wakeups_available, energy_available; char name[256]; } WattProcess;
int watt_system(WattSystem *out);
int watt_processes(WattProcess *out, int capacity, int *denied);

uint64_t watt_memory_used_pages(uint64_t anonymous, uint64_t purgeable, uint64_t wired, uint64_t compressed);

uint64_t watt_cpu_time_nanoseconds(uint64_t ticks, uint32_t numerator, uint32_t denominator);
int watt_process_path(int32_t pid, char *buffer, int capacity);

uint64_t watt_process_start_time(int32_t pid);

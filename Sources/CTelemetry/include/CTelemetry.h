#include <stdint.h>
#include <sqlite3.h>
typedef struct { uint64_t user, system, idle, memory, compressed, swap, rx, tx; } WattSystem;
typedef struct { int32_t pid, parent; uint64_t start, cpu, footprint, read, written; char name[256]; } WattProcess;
int watt_system(WattSystem *out);
int watt_processes(WattProcess *out, int capacity, int *denied);

uint64_t watt_memory_used_pages(uint64_t anonymous, uint64_t purgeable, uint64_t wired, uint64_t compressed);

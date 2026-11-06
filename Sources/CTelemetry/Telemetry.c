#include "CTelemetry.h"
#include <mach/mach.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <stdlib.h>
#include <string.h>
// Anonymous pages exclude file-backed cache. Purgeable anonymous pages are reclaimable.
uint64_t watt_memory_used_pages(uint64_t anonymous, uint64_t purgeable, uint64_t wired, uint64_t compressed) {
    return (anonymous > purgeable ? anonymous - purgeable : 0) + wired + compressed;
}
int watt_system(WattSystem *o) {
    memset(o,0,sizeof(*o));
    static mach_port_t host=0; if(!host) host=mach_host_self();
    host_cpu_load_info_data_t cpu; mach_msg_type_number_t n=HOST_CPU_LOAD_INFO_COUNT;
    if(host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&cpu,&n)!=KERN_SUCCESS) return 0;
    o->user=cpu.cpu_ticks[CPU_STATE_USER]+cpu.cpu_ticks[CPU_STATE_NICE]; o->system=cpu.cpu_ticks[CPU_STATE_SYSTEM]; o->idle=cpu.cpu_ticks[CPU_STATE_IDLE];
    vm_statistics64_data_t vm; n=HOST_VM_INFO64_COUNT;
    if(host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&vm,&n)==KERN_SUCCESS) {
        vm_size_t page; host_page_size(host,&page);
        o->memory=watt_memory_used_pages(vm.internal_page_count,vm.purgeable_count,vm.wire_count,vm.compressor_page_count)*page;
        o->compressed=(uint64_t)vm.compressor_page_count*page;
    }
    struct xsw_usage swap; size_t size=sizeof(swap); if(!sysctlbyname("vm.swapusage",&swap,&size,0,0)) o->swap=swap.xsu_used;
    struct ifaddrs *interfaces;
    if(!getifaddrs(&interfaces)) {
        for(struct ifaddrs *p=interfaces;p;p=p->ifa_next) {
            if(!p->ifa_addr || p->ifa_addr->sa_family!=AF_LINK || !p->ifa_data) continue;
            // Physical interfaces only: do not sum VPN and loopback copies.
            if(strncmp(p->ifa_name,"en",2)!=0) continue;
            struct if_data *d=p->ifa_data; o->rx+=d->ifi_ibytes; o->tx+=d->ifi_obytes;
        }
        freeifaddrs(interfaces);
    }
    return 1;
}
int watt_processes(WattProcess *out,int capacity,int *denied) {
    *denied=0; int bytes=proc_listallpids(NULL,0); if(bytes<=0) return -1;
    int count=bytes+512; pid_t *pids=calloc(count,sizeof(pid_t)); if(!pids) return -1;
    int got=proc_listallpids(pids,count*sizeof(pid_t)), used=0;
    for(int i=0;i<got && used<capacity;i++) {
        if(pids[i]<=0) continue;
        struct proc_bsdinfo b; struct rusage_info_v2 r;
        if(proc_pidinfo(pids[i],PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b) || proc_pid_rusage(pids[i],RUSAGE_INFO_V2,(rusage_info_t*)&r)) {(*denied)++;continue;}
        WattProcess *p=&out[used++]; memset(p,0,sizeof(*p)); p->pid=pids[i];p->parent=b.pbi_ppid;
        p->start=b.pbi_start_tvsec*1000000ULL+b.pbi_start_tvusec;p->cpu=r.ri_user_time+r.ri_system_time;
        p->footprint=r.ri_phys_footprint;p->read=r.ri_diskio_bytesread;p->written=r.ri_diskio_byteswritten;
        proc_name(p->pid,p->name,sizeof(p->name)); if(!p->name[0]) strlcpy(p->name,b.pbi_comm,sizeof(p->name));
    }
    free(pids);return used;
}

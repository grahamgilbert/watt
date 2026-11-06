#include "CTelemetry.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

enum { WATT_MAX_PROCESSES = 16384 };

// Both public sysctl identities and libproc use epoch microseconds. Never invent
// a PID-only identity when the kernel cannot supply a valid process start time.
static uint64_t process_start_microseconds(int64_t seconds, int64_t microseconds) {
    if(seconds<=0 || microseconds<0 || microseconds>=1000000 ||
       (uint64_t)seconds>(UINT64_MAX-(uint64_t)microseconds)/1000000ULL) return 0;
    return (uint64_t)seconds*1000000ULL+(uint64_t)microseconds;
}
static int public_process_is_live(const struct kinfo_proc *info) {
    return info->kp_proc.p_pid>0 && info->kp_proc.p_stat!=0 &&
        info->kp_proc.p_stat!=SIDL && info->kp_proc.p_stat!=SZOMB &&
        !(info->kp_proc.p_flag&P_WEXIT) &&
        process_start_microseconds(info->kp_proc.p_starttime.tv_sec,info->kp_proc.p_starttime.tv_usec)!=0;
}
static int compare_public_processes(const void *lhs,const void *rhs) {
    pid_t left=((const struct kinfo_proc *)lhs)->kp_proc.p_pid;
    pid_t right=((const struct kinfo_proc *)rhs)->kp_proc.p_pid;
    return (left>right)-(left<right);
}
// Loaded at most once per sample, only if libproc withholds an identity. Sorting
// once avoids a linear scan for every protected PID. Allocation and retries are bounded.
static struct kinfo_proc *public_process_inventory(size_t *count) {
    *count=0;
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL};size_t bytes=0;
    if(sysctl(mib,3,NULL,&bytes,NULL,0)!=0 || bytes==0) return NULL;
    size_t requested=bytes/sizeof(struct kinfo_proc);
    if(requested>WATT_MAX_PROCESSES) return NULL;
    size_t capacity=requested+512;
    if(capacity>WATT_MAX_PROCESSES) capacity=WATT_MAX_PROCESSES;
    for(int attempt=0;attempt<2;attempt++) {
        size_t allocated=capacity*sizeof(struct kinfo_proc);bytes=allocated;
        struct kinfo_proc *inventory=malloc(allocated);
        if(!inventory) return NULL;
        int result=sysctl(mib,3,inventory,&bytes,NULL,0);int error=errno;
        if(result==0 && bytes<=allocated && bytes%sizeof(*inventory)==0) {
            *count=bytes/sizeof(*inventory);
            qsort(inventory,*count,sizeof(*inventory),compare_public_processes);
            return inventory;
        }
        free(inventory);
        if(error!=ENOMEM || capacity==WATT_MAX_PROCESSES) return NULL;
        size_t increase=capacity/4;
        if(increase<512) increase=512;
        capacity+=increase;
        if(capacity>WATT_MAX_PROCESSES) capacity=WATT_MAX_PROCESSES;
    }
    return NULL;
}
static const struct kinfo_proc *find_public_process(const struct kinfo_proc *inventory,size_t count,pid_t pid) {
    size_t lower=0,upper=count;
    while(lower<upper) {
        size_t middle=lower+(upper-lower)/2;
        if(inventory[middle].kp_proc.p_pid<pid) lower=middle+1;else upper=middle;
    }
    return lower<count && inventory[lower].kp_proc.p_pid==pid ? &inventory[lower] : NULL;
}
// proc_pid_rusage CPU time uses Mach absolute-time ticks, not nanoseconds.
uint64_t watt_cpu_time_nanoseconds(uint64_t ticks, uint32_t numerator, uint32_t denominator) {
    if(!denominator) return 0;
    __uint128_t value=(__uint128_t)ticks*numerator/denominator;
    return value>UINT64_MAX ? UINT64_MAX : (uint64_t)value;
}
uint64_t watt_process_start_time(int32_t pid) {
    if(pid<=0) return 0;
    struct proc_bsdinfo info;
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)) {
        if(info.pbi_pid!=(uint32_t)pid || info.pbi_status==SIDL || info.pbi_status==SZOMB) return 0;
        return process_start_microseconds(info.pbi_start_tvsec,info.pbi_start_tvusec);
    }
    struct kinfo_proc public_info;size_t size=sizeof(public_info);
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};
    if(sysctl(mib,4,&public_info,&size,NULL,0)!=0 || size!=sizeof(public_info) ||
       public_info.kp_proc.p_pid!=pid || !public_process_is_live(&public_info)) return 0;
    return process_start_microseconds(public_info.kp_proc.p_starttime.tv_sec,public_info.kp_proc.p_starttime.tv_usec);
}
int watt_process_path(int32_t pid, char *buffer, int capacity) {
    if(!buffer || capacity<=0) return 0;
    buffer[0]=0;
    int result=proc_pidpath(pid,buffer,(uint32_t)capacity);
    buffer[capacity-1]=0;
    return result;
}
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
    if(!out || !denied || capacity<=0) return -1;
    *denied=0;
    if(capacity>WATT_MAX_PROCESSES) capacity=WATT_MAX_PROCESSES;
    mach_timebase_info_data_t timebase;
    if(mach_timebase_info(&timebase)!=KERN_SUCCESS || !timebase.denom) return -1;
    int requested=proc_listallpids(NULL,0);if(requested<=0) return -1;
    int count=requested<WATT_MAX_PROCESSES-512 ? requested+512 : WATT_MAX_PROCESSES;
    pid_t *pids=calloc(count,sizeof(pid_t));if(!pids) return -1;
    int got=proc_listallpids(pids,count*sizeof(pid_t)), used=0;
    if(got<0) {free(pids);return -1;}
    if(got>count) got=count;
    struct kinfo_proc *public_inventory=NULL;size_t public_count=0;int public_loaded=0;
    for(int i=0;i<got && used<capacity;i++) {
        if(pids[i]<=0) continue;
        int restricted=0;
        WattProcess *p=&out[used];memset(p,0,sizeof(*p));p->pid=pids[i];
        struct proc_bsdinfo b; struct rusage_info_v6 r; memset(&r,0,sizeof(r));
        if(proc_pidinfo(pids[i],PROC_PIDTBSDINFO,0,&b,sizeof(b))==sizeof(b)) {
            if(b.pbi_pid!=(uint32_t)pids[i] || b.pbi_status==SIDL || b.pbi_status==SZOMB) continue;
            p->start=process_start_microseconds(b.pbi_start_tvsec,b.pbi_start_tvusec);
            if(!p->start) continue;
            p->parent=b.pbi_ppid;p->uid=b.pbi_uid;
            strlcpy(p->name,b.pbi_comm,sizeof(p->name));
        } else {
            int error=errno;
            if(error==ESRCH || error==ENOENT) continue;
            restricted=1;
            if(!public_loaded) {public_loaded=1;public_inventory=public_process_inventory(&public_count);}
            const struct kinfo_proc *info=find_public_process(public_inventory,public_count,pids[i]);
            if(!info || !public_process_is_live(info)) {(*denied)++;continue;}
            p->start=process_start_microseconds(info->kp_proc.p_starttime.tv_sec,info->kp_proc.p_starttime.tv_usec);
            p->parent=info->kp_eproc.e_ppid;p->uid=info->kp_eproc.e_ucred.cr_uid;
            strlcpy(p->name,info->kp_proc.p_comm,sizeof(p->name));
        }
        int has_v6=proc_pid_rusage(pids[i],RUSAGE_INFO_V6,(rusage_info_t*)&r)==0;
        int has_metrics=has_v6;
        if(!has_v6) {
            // V2 is the common prefix of V6. Older kernels keep all existing telemetry.
            memset(&r,0,sizeof(r));
            has_metrics=proc_pid_rusage(pids[i],RUSAGE_INFO_V2,(rusage_info_t*)&r)==0;
            if(!has_metrics && (errno==ESRCH || errno==ENOENT)) continue;
        }
        if(has_metrics) {
            p->metrics_available=1;
            p->cpu=watt_cpu_time_nanoseconds(r.ri_user_time+r.ri_system_time,timebase.numer,timebase.denom);
            p->footprint=r.ri_phys_footprint;p->read=r.ri_diskio_bytesread;p->written=r.ri_diskio_byteswritten;
            p->idle_wakeups=r.ri_pkg_idle_wkups;p->interrupt_wakeups=r.ri_interrupt_wkups;
            p->wakeups_available=1;
#if defined(__arm64__)
            // Recount attributes estimated CPU energy in nanojoules on supported ARM systems.
            // Intel/unsupported zero counters must not be presented as measured zero power.
            // A new process with a zero lifetime counter needs a positive baseline first.
            p->energy_available=has_v6 && r.ri_energy_nj>0;
            if(p->energy_available) p->energy_nj=r.ri_energy_nj;
#endif
        } else {restricted=1;}
        char name[sizeof(p->name)]={0};
        if(proc_name(p->pid,name,sizeof(name))>0 && name[0]) strlcpy(p->name,name,sizeof(p->name));
        if(!p->name[0] || p->parent<0 || p->parent==p->pid) {(*denied)++;continue;}
        if(restricted) (*denied)++;
        used++;
    }
    free(public_inventory);free(pids);return used;
}

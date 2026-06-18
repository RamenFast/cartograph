/* The capture event ABI — the one struct the kernel (eBPF) and userspace (Zig)
 * agree on. Mirrored exactly by `CgEvent` in src/capture/bpf.zig; the two are
 * size-asserted on both sides. Keep fields naturally aligned (no implicit pad). */
#ifndef CARTOGRAPH_EVENT_H
#define CARTOGRAPH_EVENT_H

enum cg_kind {
    CG_CONNECT = 0, /* a socket entered SYN_SENT in process context (attributed) */
    CG_STATE = 1,   /* any other TCP state transition (may be softirq, pid best-effort) */
};

struct cg_event {
    __u64 ts_ns;
    __u32 pid;
    __u32 uid;
    __u8 kind;     /* enum cg_kind */
    __u8 family;   /* 2 = AF_INET, 10 = AF_INET6 */
    __u8 proto;    /* 6 = TCP (M2 hooks TCP state) */
    __u8 newstate; /* TCP_* state number (matches flow.TcpState) */
    __u16 sport;   /* host byte order */
    __u16 dport;   /* host byte order */
    __u8 saddr[16];
    __u8 daddr[16];
    char comm[16];
};

#endif

// Cartograph's eBPF capture source (M2). CO-RE, so one object runs on any kernel
// with BTF (DECISIONS D3). Hooks the TCP state machine in-kernel: this is what
// closes the `?` rows — short-lived connections /proc misses, and other-user
// sockets — by attributing the owning process *at the moment the socket acts*,
// not by racing a /proc scan afterwards.
//
// NOTE: loading/attaching this needs CAP_BPF+CAP_PERFMON (surveyor is setcap'd,
// never root — ARCHITECTURE.md). The userspace loader is src/capture/bpf.zig; it
// falls back to the unprivileged inet_diag source when caps are absent.

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_tracing.h>
#include "event.h"

char LICENSE[] SEC("license") = "GPL";

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 18); // 256 KiB
} events SEC(".maps");

// AF_INET / AF_INET6 as the kernel numbers them.
#define AF_INET 2
#define AF_INET6 10

// One hook on the TCP state machine. `tp_btf` gives BTF-typed args (verified
// against vmlinux), and the transition fires for the whole life of a connection:
// SYN_SENT (birth, in process context → attributable) through CLOSE (death).
SEC("tp_btf/inet_sock_set_state")
int BPF_PROG(cg_inet_sock_set_state, struct sock *sk, int oldstate, int newstate) {
    __u16 family = BPF_CORE_READ(sk, __sk_common.skc_family);
    if (family != AF_INET && family != AF_INET6) return 0;

    // We only model TCP here; UDP has no state machine (a known M1/M2 limitation).
    __u16 protocol = BPF_CORE_READ(sk, sk_protocol);
    if (protocol != IPPROTO_TCP) return 0;

    struct cg_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) return 0;

    e->ts_ns = bpf_ktime_get_ns();
    e->family = (__u8)family;
    e->proto = IPPROTO_TCP;
    e->newstate = (__u8)newstate;

    // ports: skc_num (local) is host order; skc_dport is network order.
    e->sport = BPF_CORE_READ(sk, __sk_common.skc_num);
    e->dport = bpf_ntohs(BPF_CORE_READ(sk, __sk_common.skc_dport));

    __builtin_memset(e->saddr, 0, sizeof(e->saddr));
    __builtin_memset(e->daddr, 0, sizeof(e->daddr));
    if (family == AF_INET) {
        // __be32 in network order — copy as the first 4 bytes (matches diag.zig).
        __u32 s = BPF_CORE_READ(sk, __sk_common.skc_rcv_saddr);
        __u32 d = BPF_CORE_READ(sk, __sk_common.skc_daddr);
        __builtin_memcpy(e->saddr, &s, 4);
        __builtin_memcpy(e->daddr, &d, 4);
    } else {
        BPF_CORE_READ_INTO(e->saddr, sk, __sk_common.skc_v6_rcv_saddr.in6_u.u6_addr8);
        BPF_CORE_READ_INTO(e->daddr, sk, __sk_common.skc_v6_daddr.in6_u.u6_addr8);
    }

    // Attribution: valid when the transition happens in process context (the common
    // case for SYN_SENT, the outbound connect). For softirq transitions pid may be
    // unrelated; userspace treats pid 0 / kernel as unattributed and the FlowTable
    // late-merges a real pid from the birth event (table.zig observe()).
    e->kind = (newstate == BPF_TCP_SYN_SENT) ? CG_CONNECT : CG_STATE;
    __u64 id = bpf_get_current_pid_tgid();
    e->pid = id >> 32;
    e->uid = (__u32)bpf_get_current_uid_gid();
    bpf_get_current_comm(&e->comm, sizeof(e->comm));

    bpf_ringbuf_submit(e, 0);
    return 0;
}

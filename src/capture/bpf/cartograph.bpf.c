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
        // NOTE: must pass &array so the macro's sizeof(*(dst)) is 16, not the
        // decayed pointer's 1 — the 1-byte truncation shipped in M2 and was only
        // caught by dumping the live map at S3 (every v6 addr read "2600::").
        BPF_CORE_READ_INTO(&e->saddr, sk, __sk_common.skc_v6_rcv_saddr.in6_u.u6_addr8);
        BPF_CORE_READ_INTO(&e->daddr, sk, __sk_common.skc_v6_daddr.in6_u.u6_addr8);
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

// ---- UDP byte counters (S3) -------------------------------------------------
// UDP has no state machine to hook and inet_diag reports no UDP byte counts —
// so QUIC/HTTP-3, DNS, and games were a throughput blind spot. These fexit
// probes accumulate per-socket counters in an LRU hash the userspace tick
// drains; the LRU bounds memory without an explicit close hook.

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 4096);
    __type(key, __u64); /* socket cookie */
    __type(value, struct cg_udp_flow);
} udp_flows SEC(".maps");

#define MSG_PEEK_FLAG 2

static __always_inline struct cg_udp_flow *udp_slot(struct sock *sk) {
    __u64 cookie = bpf_get_socket_cookie(sk);
    struct cg_udp_flow *v = bpf_map_lookup_elem(&udp_flows, &cookie);
    if (v) return v;
    struct cg_udp_flow zero = {};
    bpf_map_update_elem(&udp_flows, &cookie, &zero, BPF_NOEXIST);
    return bpf_map_lookup_elem(&udp_flows, &cookie);
}

// Refresh the slot's identity: the 4-tuple from the socket (a connected UDP
// socket — the QUIC case — has skc_daddr set; an unconnected one leaves the
// wildcard dest, which matches the diag row for that socket) and, in process
// context, the owning pid/comm.
static __always_inline void udp_fill(struct cg_udp_flow *v, struct sock *sk, int from_process) {
    __u16 family = BPF_CORE_READ(sk, __sk_common.skc_family);
    v->family = (__u8)family;
    v->sport = BPF_CORE_READ(sk, __sk_common.skc_num);
    v->dport = bpf_ntohs(BPF_CORE_READ(sk, __sk_common.skc_dport));
    if (family == AF_INET) {
        __u32 s = BPF_CORE_READ(sk, __sk_common.skc_rcv_saddr);
        __u32 d = BPF_CORE_READ(sk, __sk_common.skc_daddr);
        __builtin_memset(v->saddr, 0, sizeof(v->saddr));
        __builtin_memset(v->daddr, 0, sizeof(v->daddr));
        __builtin_memcpy(v->saddr, &s, 4);
        __builtin_memcpy(v->daddr, &d, 4);
    } else {
        // &array, not the decayed pointer — see the same note in the TCP hook.
        BPF_CORE_READ_INTO(&v->saddr, sk, __sk_common.skc_v6_rcv_saddr.in6_u.u6_addr8);
        BPF_CORE_READ_INTO(&v->daddr, sk, __sk_common.skc_v6_daddr.in6_u.u6_addr8);
    }
    if (from_process && v->pid == 0) {
        v->pid = bpf_get_current_pid_tgid() >> 32;
        v->uid = (__u32)bpf_get_current_uid_gid();
        bpf_get_current_comm(&v->comm, sizeof(v->comm));
    }
}

static __always_inline int udp_count_tx(struct sock *sk, int ret) {
    if (ret <= 0) return 0;
    struct cg_udp_flow *v = udp_slot(sk);
    if (!v) return 0;
    udp_fill(v, sk, 1); // sendmsg runs in process context — attribution is exact
    __sync_fetch_and_add(&v->tx_bytes, (__u64)ret);
    return 0;
}

static __always_inline int udp_count_rx(struct sock *sk, int flags, int ret) {
    if (ret <= 0 || (flags & MSG_PEEK_FLAG)) return 0;
    struct cg_udp_flow *v = udp_slot(sk);
    if (!v) return 0;
    udp_fill(v, sk, 1);
    __sync_fetch_and_add(&v->rx_bytes, (__u64)ret);
    return 0;
}

SEC("fexit/udp_sendmsg")
int BPF_PROG(cg_udp_sendmsg, struct sock *sk, struct msghdr *msg, size_t len, int ret) {
    return udp_count_tx(sk, ret);
}

SEC("fexit/udpv6_sendmsg")
int BPF_PROG(cg_udpv6_sendmsg, struct sock *sk, struct msghdr *msg, size_t len, int ret) {
    return udp_count_tx(sk, ret);
}

SEC("fexit/udp_recvmsg")
int BPF_PROG(cg_udp_recvmsg, struct sock *sk, struct msghdr *msg, size_t len, int flags, int *addr_len, int ret) {
    return udp_count_rx(sk, flags, ret);
}

SEC("fexit/udpv6_recvmsg")
int BPF_PROG(cg_udpv6_recvmsg, struct sock *sk, struct msghdr *msg, size_t len, int flags, int *addr_len, int ret) {
    return udp_count_rx(sk, flags, ret);
}

// ---- passive-DNS socket filter (S3) ------------------------------------------
// Attached (SO_ATTACH_BPF) to surveyor's AF_PACKET tap so the kernel forwards
// ONLY UDP source-port-53 packets — the box's own DNS answers — and drops the
// rest before userspace ever copies them. Userspace (pdns.zig) parses answers
// into addr→true-hostname for the identity layer. Return = bytes to keep.

SEC("socket")
int cg_dns_filter(struct __sk_buff *skb) {
    __u8 first;
    if (bpf_skb_load_bytes(skb, 0, &first, 1)) return 0;
    __u8 version = first >> 4;
    if (version == 4) {
        __u8 proto;
        if (bpf_skb_load_bytes(skb, 9, &proto, 1)) return 0;
        if (proto != IPPROTO_UDP) return 0;
        __u32 ihl = (__u32)(first & 0x0f) * 4;
        __be16 sport;
        if (bpf_skb_load_bytes(skb, ihl, &sport, 2)) return 0;
        if (bpf_ntohs(sport) != 53) return 0;
        return 0xffff;
    }
    if (version == 6) {
        __u8 next;
        if (bpf_skb_load_bytes(skb, 6, &next, 1)) return 0;
        if (next != IPPROTO_UDP) return 0; // extension headers: rare on DNS, skipped honestly
        __be16 sport;
        if (bpf_skb_load_bytes(skb, 40, &sport, 2)) return 0;
        if (bpf_ntohs(sport) != 53) return 0;
        return 0xffff;
    }
    return 0;
}

// Generalized litmus harness with optional sched_ext gang opt-in.
//
// One binary runs several classic litmus tests (SB, MP, LB, 2+2W, IRIW) using
// lightweight (non-blocking) sense_barrier synchronization, so the controlled
// "sync held constant" methodology applies across the whole test catalog.
//
//   litmus -t SB        # run test SB under whatever scheduler is active
//   litmus -t MP -g     # opt in to gang scheduling (needs scx_gang/scx_group loaded)
//   litmus -t LB -n 2000000
//
// Weak-behaviour counts are printed to stdout. On x86-TSO only SB exhibits weak
// behaviour; MP/LB/2+2W/IRIW are TSO-forbidden and should read ~0 -- they come
// alive on weakly-ordered hardware (ARM/RISC-V), which is the point of the suite.
#include <atomic>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>

#ifndef NO_BPF
#include <bpf/bpf.h>   // gang opt-in; build with -DNO_BPF on hosts without libbpf
#endif
#include "sense_barrier.h"

using namespace std;

// Two shared locations on separate cache lines (avoid false sharing).
#define PAD 512
static atomic_int mem[4 * PAD];
static atomic_int &X = mem[1 * PAD];
static atomic_int &Y = mem[3 * PAD];

static int R[8];          // per-iteration result registers
static int done;
static mutex lk;

struct Test {
    const char *name;
    int nthreads;
    void (*body)(int tid);          // per-thread accesses for this test
    bool (*weak)();                 // is the recorded outcome a weak behaviour?
};

// ---- test bodies (relaxed atomics + compiler fence; hardware may reorder) ----
static inline void cfence() { atomic_signal_fence(memory_order_acq_rel); }

static void sb_body(int tid) {
    if (tid == 0) { X.store(1, memory_order_relaxed); cfence(); R[0] = Y.load(memory_order_relaxed); }
    else          { Y.store(1, memory_order_relaxed); cfence(); R[1] = X.load(memory_order_relaxed); }
}
static bool sb_weak() { return R[0] == 0 && R[1] == 0; }

static void mp_body(int tid) {
    if (tid == 0) { X.store(1, memory_order_relaxed); cfence(); Y.store(1, memory_order_relaxed); }
    else          { R[1] = Y.load(memory_order_relaxed); cfence(); R[0] = X.load(memory_order_relaxed); }
}
static bool mp_weak() { return R[1] == 1 && R[0] == 0; }   // saw flag, missed data

static void lb_body(int tid) {
    if (tid == 0) { R[0] = X.load(memory_order_relaxed); cfence(); Y.store(1, memory_order_relaxed); }
    else          { R[1] = Y.load(memory_order_relaxed); cfence(); X.store(1, memory_order_relaxed); }
}
static bool lb_weak() { return R[0] == 1 && R[1] == 1; }

static void w22_body(int tid) {
    if (tid == 0) { X.store(1, memory_order_relaxed); cfence(); Y.store(2, memory_order_relaxed); }
    else          { Y.store(1, memory_order_relaxed); cfence(); X.store(2, memory_order_relaxed); }
}
static bool w22_weak() { return X.load(memory_order_relaxed) == 1 && Y.load(memory_order_relaxed) == 1; }

static void iriw_body(int tid) {
    switch (tid) {
    case 0: X.store(1, memory_order_relaxed); break;
    case 1: Y.store(1, memory_order_relaxed); break;
    case 2: R[0] = X.load(memory_order_relaxed); cfence(); R[1] = Y.load(memory_order_relaxed); break;
    case 3: R[2] = Y.load(memory_order_relaxed); cfence(); R[3] = X.load(memory_order_relaxed); break;
    }
}
static bool iriw_weak() { return R[0] == 1 && R[1] == 0 && R[2] == 1 && R[3] == 0; }

static const Test TESTS[] = {
    {"SB",   2, sb_body,   sb_weak},
    {"MP",   2, mp_body,   mp_weak},
    {"LB",   2, lb_body,   lb_weak},
    {"2+2W", 2, w22_body,  w22_weak},
    {"IRIW", 4, iriw_body, iriw_weak},
};

// ---- gang opt-in (mirrors sb_group_plus): add this thread's tid to the gang map ----
[[maybe_unused]] static bool gang_mode = false;
#ifdef NO_BPF
static void gang_optin() {}
#else
static void gang_optin() {
    if (!gang_mode) return;
    int outer = bpf_obj_get("/sys/fs/bpf/groups");
    if (outer < 0) { perror("bpf_obj_get(groups)"); exit(1); }
    uint32_t tgid = getpid();
    int inner_id;
    if (bpf_map_lookup_elem(outer, &tgid, &inner_id) < 0) { perror("lookup inner"); exit(1); }
    int inner = bpf_map_get_fd_by_id(inner_id);
    uint32_t tid = gettid(), gid = 1;
    if (bpf_map_update_elem(inner, &tid, &gid, 0) < 0) { perror("update inner"); exit(1); }
    close(outer); close(inner);
}
#endif

static const Test *T;
static void worker_entry(int tid, sense_barrier *b1, sense_barrier *b2) {
    gang_optin();
    for (;;) {
        b1->wait();
        T->body(tid);
        { lock_guard<mutex> g(lk); if (done) return; }
        b2->wait();
    }
}

int main(int argc, char **argv) {
    string tname = "SB";
    long iters = 1000000;
    for (int o; (o = getopt(argc, argv, "t:n:gh")) != -1; ) {
        switch (o) {
        case 't': tname = optarg; break;
        case 'n': iters = atol(optarg); break;
        case 'g':
#ifdef NO_BPF
            fprintf(stderr, "gang mode (-g) unavailable: built with NO_BPF\n"); return 1;
#else
            gang_mode = true; break;
#endif
        default: fprintf(stderr, "usage: %s -t <SB|MP|LB|2+2W|IRIW> [-g] [-n iters]\n", argv[0]); return o != 'h';
        }
    }
    T = nullptr;
    for (auto &t : TESTS) if (tname == t.name) T = &t;
    if (!T) { fprintf(stderr, "unknown test '%s'\n", tname.c_str()); return 1; }

    sense_barrier b1(T->nthreads + 1), b2(T->nthreads + 1);

    // Gang map setup (main creates the inner map and registers itself).
#ifndef NO_BPF
    if (gang_mode) {
        int outer = bpf_obj_get("/sys/fs/bpf/groups");
        if (outer < 0) { perror("bpf_obj_get(groups)"); exit(1); }
        uint32_t tgid = getpid();
        int inner = bpf_map_create(BPF_MAP_TYPE_HASH, "group", sizeof(uint32_t), sizeof(uint32_t), 64, 0);
        if (bpf_map_update_elem(outer, &tgid, &inner, 0) < 0) { perror("register inner"); exit(1); }
        uint32_t tid = gettid(), gid = 1;
        bpf_map_update_elem(inner, &tid, &gid, 0);
        close(inner); close(outer);
    }
#endif

    thread th[4];
    for (int i = 0; i < T->nthreads; i++) th[i] = thread(worker_entry, i, &b1, &b2);

    long weak = 0;
    for (long i = 0; i < iters; i++) {
        X.store(0, memory_order_relaxed);
        Y.store(0, memory_order_relaxed);
        for (int &r : R) r = -1;
        b1.wait();   // release workers
        b2.wait();   // wait for them to finish recording
        if (T->weak()) ++weak;
    }
    { lock_guard<mutex> g(lk); done = 1; }
    b1.wait();
    for (int i = 0; i < T->nthreads; i++) th[i].join();

#ifndef NO_BPF
    if (gang_mode) {
        int outer = bpf_obj_get("/sys/fs/bpf/groups");
        if (outer >= 0) { uint32_t tgid = getpid(); bpf_map_delete_elem(outer, &tgid); close(outer); }
    }
#endif
    printf("%ld\n", weak);
    return 0;
}

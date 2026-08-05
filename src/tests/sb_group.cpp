#include <atomic>
#include <barrier>
#include <functional>
#include <iostream>
#include <mutex>
#include <thread>

#include <bpf/bpf.h>

#define XY_LENGTH 512

using namespace std;

atomic_int mem_array[3 * XY_LENGTH + 2];
atomic_int &x = mem_array[XY_LENGTH];
atomic_int &y = mem_array[2 * XY_LENGTH + 1];

int r0, r1;
int done;

void
t0(barrier<> &b1, barrier<> &b2, mutex &lock)
{
    int outer_fd = bpf_obj_get("/sys/fs/bpf/groups");
    if (outer_fd < 0) {
        perror("bpf_obj_get");
        exit(1);
    }

    uint32_t tgid = getpid();
    int inner_fd;

    int err = bpf_map_lookup_elem(outer_fd, &tgid, &inner_fd);
    if (err < 0) {
        perror("bpf_map_lookup_elem");
        exit(1);
    }

    inner_fd = bpf_map_get_fd_by_id(inner_fd);
    int tid = gettid();
    int group_id = 1;

    err = bpf_map_update_elem(inner_fd, &tid, &group_id, 0);
    if (err < 0) {
        perror("bpf_map_update_elem");
        exit(1);
    }

    close(outer_fd);
    close(inner_fd);

    int tmp0 = -1;
    int tmp1 = -1;

    for (;;) {
        b1.arrive_and_wait();

        x.store(1, memory_order_relaxed);
        atomic_signal_fence(memory_order_acq_rel);
        tmp0 = y.load(memory_order_relaxed);

        {
            lock_guard<mutex> guard(lock);

            if (tmp0 != -1) {
                r0 = tmp0;
            }
            if (tmp1 != -1) {
                r1 = tmp1;
            }

            if (done) {
                return;
            }
        }

        b2.arrive_and_wait();
    }
}

void
t1(barrier<> &b1, barrier<> &b2, mutex &lock)
{
    int outer_fd = bpf_obj_get("/sys/fs/bpf/groups");
    if (outer_fd < 0) {
        perror("bpf_obj_get");
        exit(1);
    }

    uint32_t tgid = getpid();

    int inner_fd;

    int err = bpf_map_lookup_elem(outer_fd, &tgid, &inner_fd);
    if (err < 0) {
        perror("bpf_map_lookup_elem");
        exit(1);
    }

    inner_fd = bpf_map_get_fd_by_id(inner_fd);
    int tid = gettid();
    int group_id = 1;

    err = bpf_map_update_elem(inner_fd, &tid, &group_id, 0);
    if (err < 0) {
        perror("bpf_map_update_elem");
        exit(1);
    }

    close(outer_fd);
    close(inner_fd);

    int tmp0 = -1;
    int tmp1 = -1;

    for (;;) {
        b1.arrive_and_wait();

        y.store(1, memory_order_relaxed);
        atomic_signal_fence(memory_order_acq_rel);
        tmp1 = x.load(memory_order_relaxed);

        {
            lock_guard<mutex> guard(lock);

            if (tmp0 != -1) {
                r0 = tmp0;
            }
            if (tmp1 != -1) {
                r1 = tmp1;
            }

            if (done) {
                return;
            }
        }

        b2.arrive_and_wait();
    }
}

int
main(int argc, char *argv[])
{
    barrier<> b1(3), b2(3);
    mutex lock;
    thread t[2];

    const int iters = 1000000;

    int outer_fd = bpf_obj_get("/sys/fs/bpf/groups");
    if (outer_fd < 0) {
        perror("bpf_obj_get");
        exit(1);
    }

    uint32_t tgid = getpid();

    int inner_fd = bpf_map_create(BPF_MAP_TYPE_HASH, "group", sizeof(uint32_t),
                                  sizeof(uint32_t), 16, 0);

    int err = bpf_map_update_elem(outer_fd, &tgid, &inner_fd, 0);
    if (err < 0) {
        perror("bpf_map_update_elem");
        exit(1);
    }

    int tid = gettid();
    int group_id = 1;

    err = bpf_map_update_elem(inner_fd, &tid, &group_id, 0);
    if (err < 0) {
        perror("bpf_map_update_elem");
        exit(1);
    }

    close(inner_fd);

    t[0] = thread(t0, ref(b1), ref(b2), ref(lock));
    t[1] = thread(t1, ref(b1), ref(b2), ref(lock));

    int weak = 0;

    for (int i = 0; i < iters; ++i) {
        x = 0;
        y = 0;
        r0 = -1;
        r1 = -1;

        b1.arrive_and_wait();
        b2.arrive_and_wait();

        if (r0 == 0 && r1 == 0) {
            ++weak;
        }
    }

    {
        lock_guard<mutex> guard(lock);
        done = 1;
    }

    b1.arrive_and_wait();

    t[0].join();
    t[1].join();

    cout << weak << endl;

    err = bpf_map_delete_elem(outer_fd, &tgid);
    if (err < 0) {
        perror("bpf_map_delete_elem");
        exit(1);
    }

    close(outer_fd);

    return 0;
}

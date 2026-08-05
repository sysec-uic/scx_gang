#include <atomic>
#include <barrier>
#include <functional>
#include <iostream>
#include <mutex>
#include <thread>

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

    return 0;
}

#include <atomic>
#include <cassert>

class sense_barrier
{
    static const uint32_t sense_mask = (1 << 31);

    const uint32_t threads;
    std::atomic_uint32_t spinner;

  public:
    sense_barrier(const uint32_t threads) : threads(threads), spinner(0)
    {
        assert(threads < 1024);
    }

    void
    wait()
    {
        uint32_t v = ++spinner;
        uint32_t s = v & sense_mask;

        if ((v ^ s) == threads) {
            spinner = s ^ sense_mask;
        } else {
            while (s == (spinner & sense_mask))
                ;
        }
    }
};

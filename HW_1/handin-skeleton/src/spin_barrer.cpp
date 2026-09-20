#include <spin_barrier.h>

spin_barrier::spin_barrier(int n_threads)
    : n_threads(n_threads), count(0), sense(false)
{
    pthread_spin_init(&lock, PTHREAD_PROCESS_PRIVATE);
}

spin_barrier::~spin_barrier()
{
    pthread_spin_destroy(&lock);
}

void spin_barrier::wait()
{
    // each thread flips its own copy first, so a thread that races ahead into the next round
    // cannot be released by the flag that freed the previous one
    static thread_local bool local_sense = false;
    local_sense = !local_sense;

    pthread_spin_lock(&lock);
    count++;
    bool last = count == n_threads;
    if (last) {
        count = 0;
    }
    pthread_spin_unlock(&lock);

    if (last) {
        sense.store(local_sense);
    } else {
        while (sense.load() != local_sense) {
        }
    }
}

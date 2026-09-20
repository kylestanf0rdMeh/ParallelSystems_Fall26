#ifndef _SPIN_BARRIER_H
#define _SPIN_BARRIER_H

#include <pthread.h>
#include <iostream>
#include <atomic>

class spin_barrier {
  public:
    spin_barrier(int n_threads);
    ~spin_barrier();

    void wait();

  private:
    pthread_spinlock_t lock;
    int n_threads;
    int count;
    std::atomic<bool> sense;
};

#endif

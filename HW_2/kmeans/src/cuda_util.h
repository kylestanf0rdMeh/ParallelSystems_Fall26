#ifndef _CUDA_UTIL_H
#define _CUDA_UTIL_H

#include <cstdio>
#include <cstdlib>

static void cuda_check(cudaError_t err, const char *what)
{
    if (err != cudaSuccess)
    {
        fprintf(stderr, "%s: %s\n", what, cudaGetErrorString(err));
        exit(1);
    }
}

// events are only recorded under --verbose, so the graded timing path pays nothing for them
struct gpu_timer {
    bool enabled;
    cudaEvent_t start_event;
    cudaEvent_t stop_event;
    double total_ms;
};

static void timer_init(struct gpu_timer *t, bool enabled)
{
    t->enabled = enabled;
    t->total_ms = 0.0;
    if (enabled)
    {
        cudaEventCreate(&t->start_event);
        cudaEventCreate(&t->stop_event);
    }
}

static void timer_start(struct gpu_timer *t)
{
    if (t->enabled)
    {
        cudaEventRecord(t->start_event);
    }
}

static void timer_stop(struct gpu_timer *t)
{
    if (!t->enabled)
    {
        return;
    }

    cudaEventRecord(t->stop_event);
    cudaEventSynchronize(t->stop_event);

    float ms = 0.0f;
    cudaEventElapsedTime(&ms, t->start_event, t->stop_event);
    t->total_ms += ms;
}

static void timer_free(struct gpu_timer *t)
{
    if (t->enabled)
    {
        cudaEventDestroy(t->start_event);
        cudaEventDestroy(t->stop_event);
    }
}

#endif

#include "kmeans.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#define THREADS_PER_BLOCK 256

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

// the first cuda call in a process builds the device context, which costs a few hundred ms.
// that is runtime startup rather than per iteration work, so it is paid before the clock starts.
void kmeans_gpu_warmup()
{
    cuda_check(cudaFree(0), "warmup");
}

__global__ void assign_points(const double *points, const double *centroids, int *labels,
                              double *sums, int *counts, int n_points, int n_cluster, int dims)
{
    int p = blockIdx.x * blockDim.x + threadIdx.x;
    if (p >= n_points)
    {
        return;
    }

    const double *point = points + p * dims;

    int best = 0;
    double best_dist = 0.0;

    for (int c = 0; c < n_cluster; c++)
    {
        double dist = 0.0;
        for (int j = 0; j < dims; j++)
        {
            double diff = point[j] - centroids[c * dims + j];
            dist += diff * diff;
        }
        if (c == 0 || dist < best_dist)
        {
            best_dist = dist;
            best = c;
        }
    }

    labels[p] = best;
    atomicAdd(&counts[best], 1);
    for (int j = 0; j < dims; j++)
    {
        atomicAdd(&sums[best * dims + j], point[j]);
    }
}

__global__ void assign_points_shared(const double *points, const double *centroids, int *labels,
                                     double *sums, int *counts, int n_points, int n_cluster,
                                     int dims)
{
    extern __shared__ double shared[];
    double *shared_centroids = shared;
    double *shared_sums = shared + n_cluster * dims;
    int *shared_counts = (int *)(shared + 2 * n_cluster * dims);

    int entries = n_cluster * dims;

    for (int i = threadIdx.x; i < entries; i += blockDim.x)
    {
        shared_centroids[i] = centroids[i];
        shared_sums[i] = 0.0;
    }
    for (int c = threadIdx.x; c < n_cluster; c += blockDim.x)
    {
        shared_counts[c] = 0;
    }
    __syncthreads();

    int p = blockIdx.x * blockDim.x + threadIdx.x;

    // a thread past the end still has to reach both barriers, so only the work is masked
    if (p < n_points)
    {
        const double *point = points + p * dims;

        int best = 0;
        double best_dist = 0.0;

        for (int c = 0; c < n_cluster; c++)
        {
            double dist = 0.0;
            for (int j = 0; j < dims; j++)
            {
                double diff = point[j] - shared_centroids[c * dims + j];
                dist += diff * diff;
            }
            if (c == 0 || dist < best_dist)
            {
                best_dist = dist;
                best = c;
            }
        }

        labels[p] = best;
        atomicAdd(&shared_counts[best], 1);
        for (int j = 0; j < dims; j++)
        {
            atomicAdd(&shared_sums[best * dims + j], point[j]);
        }
    }
    __syncthreads();

    for (int i = threadIdx.x; i < entries; i += blockDim.x)
    {
        atomicAdd(&sums[i], shared_sums[i]);
    }
    for (int c = threadIdx.x; c < n_cluster; c += blockDim.x)
    {
        atomicAdd(&counts[c], shared_counts[c]);
    }
}

__global__ void update_centroids(const double *sums, const int *counts, const double *old_centroids,
                                 double *new_centroids, int n_cluster, int dims)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n_cluster * dims)
    {
        return;
    }

    int c = i / dims;
    new_centroids[i] = counts[c] > 0 ? sums[i] / counts[c] : old_centroids[i];
}

static double max_centroid_shift(const double *a, const double *b, int n_cluster, int dims)
{
    double worst = 0.0;

    for (int c = 0; c < n_cluster; c++)
    {
        double moved = 0.0;
        for (int j = 0; j < dims; j++)
        {
            double diff = a[c * dims + j] - b[c * dims + j];
            moved += diff * diff;
        }
        if (moved > worst)
        {
            worst = moved;
        }
    }

    return sqrt(worst);
}

static size_t shared_bytes_needed(int n_cluster, int dims)
{
    return 2 * (size_t)n_cluster * dims * sizeof(double) + (size_t)n_cluster * sizeof(int);
}

static void run_cuda(const double *points, int n_points, double *centroids, int *labels,
                     const struct options_t *opts, int *n_iter, bool use_shared)
{
    int k = opts->n_cluster;
    int dims = opts->dims;
    size_t centroid_bytes = k * dims * sizeof(double);
    size_t shared_bytes = shared_bytes_needed(k, dims);

    if (use_shared)
    {
        cudaDeviceProp prop;
        cuda_check(cudaGetDeviceProperties(&prop, 0), "device properties");
        if (shared_bytes > prop.sharedMemPerBlock)
        {
            // k by d is too wide for one block, so there is nothing to stage and we run the basic kernel
            if (opts->verbose)
            {
                fprintf(stderr, "shared: need %zu bytes but the block limit is %zu, falling back\n",
                        shared_bytes, prop.sharedMemPerBlock);
            }
            use_shared = false;
        }
    }

    struct gpu_timer transfer;
    struct gpu_timer kernel;
    timer_init(&transfer, opts->verbose);
    timer_init(&kernel, opts->verbose);

    double *d_points;
    double *d_centroids;
    double *d_new_centroids;
    double *d_sums;
    int *d_counts;
    int *d_labels;

    cuda_check(cudaMalloc(&d_points, (size_t)n_points * dims * sizeof(double)), "malloc points");
    cuda_check(cudaMalloc(&d_centroids, centroid_bytes), "malloc centroids");
    cuda_check(cudaMalloc(&d_new_centroids, centroid_bytes), "malloc new centroids");
    cuda_check(cudaMalloc(&d_sums, centroid_bytes), "malloc sums");
    cuda_check(cudaMalloc(&d_counts, k * sizeof(int)), "malloc counts");
    cuda_check(cudaMalloc(&d_labels, n_points * sizeof(int)), "malloc labels");

    timer_start(&transfer);
    cuda_check(cudaMemcpy(d_points, points, (size_t)n_points * dims * sizeof(double),
                          cudaMemcpyHostToDevice), "copy points");
    cuda_check(cudaMemcpy(d_centroids, centroids, centroid_bytes, cudaMemcpyHostToDevice),
               "copy centroids");
    timer_stop(&transfer);

    double *host_new = (double *)malloc(centroid_bytes);

    int assign_blocks = (n_points + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
    int update_blocks = (k * dims + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

    int iter = 0;
    bool converged = false;

    while (!converged && iter < opts->max_iter)
    {
        timer_start(&kernel);
        cudaMemset(d_sums, 0, centroid_bytes);
        cudaMemset(d_counts, 0, k * sizeof(int));

        if (use_shared)
        {
            assign_points_shared<<<assign_blocks, THREADS_PER_BLOCK, shared_bytes>>>(
                d_points, d_centroids, d_labels, d_sums, d_counts, n_points, k, dims);
        }
        else
        {
            assign_points<<<assign_blocks, THREADS_PER_BLOCK>>>(
                d_points, d_centroids, d_labels, d_sums, d_counts, n_points, k, dims);
        }

        update_centroids<<<update_blocks, THREADS_PER_BLOCK>>>(d_sums, d_counts, d_centroids,
                                                               d_new_centroids, k, dims);
        timer_stop(&kernel);

        timer_start(&transfer);
        cuda_check(cudaMemcpy(host_new, d_new_centroids, centroid_bytes, cudaMemcpyDeviceToHost),
                   "copy centroids back");
        timer_stop(&transfer);

        converged = max_centroid_shift(centroids, host_new, k, dims) <= opts->threshold;
        memcpy(centroids, host_new, centroid_bytes);

        double *swap = d_centroids;
        d_centroids = d_new_centroids;
        d_new_centroids = swap;

        iter++;
    }

    timer_start(&transfer);
    cuda_check(cudaMemcpy(labels, d_labels, n_points * sizeof(int), cudaMemcpyDeviceToHost),
               "copy labels back");
    timer_stop(&transfer);

    cuda_check(cudaGetLastError(), "kernel launch");

    if (opts->verbose)
    {
        fprintf(stderr, "%s: %d iters, kernel %.3f ms, transfer %.3f ms\n",
                use_shared ? "shared" : "cuda", iter, kernel.total_ms, transfer.total_ms);
    }

    *n_iter = iter;

    free(host_new);
    cudaFree(d_points);
    cudaFree(d_centroids);
    cudaFree(d_new_centroids);
    cudaFree(d_sums);
    cudaFree(d_counts);
    cudaFree(d_labels);
    timer_free(&transfer);
    timer_free(&kernel);
}

void kmeans_cuda(const double *points, int n_points, double *centroids, int *labels,
                 const struct options_t *opts, int *n_iter)
{
    run_cuda(points, n_points, centroids, labels, opts, n_iter, false);
}

void kmeans_shared(const double *points, int n_points, double *centroids, int *labels,
                   const struct options_t *opts, int *n_iter)
{
    run_cuda(points, n_points, centroids, labels, opts, n_iter, true);
}

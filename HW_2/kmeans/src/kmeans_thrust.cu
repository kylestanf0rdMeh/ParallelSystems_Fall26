#include "kmeans.h"
#include "cuda_util.h"

#include <thrust/copy.h>
#include <thrust/device_vector.h>
#include <thrust/fill.h>
#include <thrust/functional.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/reduce.h>
#include <thrust/scatter.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>
#include <thrust/transform.h>
#include <thrust/transform_reduce.h>

#include <cmath>
#include <cstdio>

struct nearest_centroid {
    const double *points;
    const double *centroids;
    int n_cluster;
    int dims;

    nearest_centroid(const double *p, const double *c, int k, int d)
        : points(p), centroids(c), n_cluster(k), dims(d) {}

    __device__ int operator()(int p) const
    {
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
        return best;
    }
};

// one key per point per dimension. the labels arrive sorted and the dimension is the minor
// index, so the expanded keys come out sorted too and reduce_by_key needs no second sort.
struct expand_key {
    const int *sorted_labels;
    int dims;

    expand_key(const int *l, int d) : sorted_labels(l), dims(d) {}

    __device__ int operator()(int i) const
    {
        return sorted_labels[i / dims] * dims + (i % dims);
    }
};

struct gather_value {
    const double *points;
    const int *order;
    int dims;

    gather_value(const double *p, const int *o, int d) : points(p), order(o), dims(d) {}

    __device__ double operator()(int i) const
    {
        return points[order[i / dims] * dims + (i % dims)];
    }
};

struct divide_sums {
    const double *sums;
    const int *counts;
    const double *old_centroids;
    int dims;

    divide_sums(const double *s, const int *c, const double *o, int d)
        : sums(s), counts(c), old_centroids(o), dims(d) {}

    __device__ double operator()(int i) const
    {
        int c = i / dims;
        return counts[c] > 0 ? sums[i] / counts[c] : old_centroids[i];
    }
};

struct centroid_shift {
    const double *before;
    const double *after;
    int dims;

    centroid_shift(const double *b, const double *a, int d) : before(b), after(a), dims(d) {}

    __device__ double operator()(int c) const
    {
        double moved = 0.0;
        for (int j = 0; j < dims; j++)
        {
            double diff = before[c * dims + j] - after[c * dims + j];
            moved += diff * diff;
        }
        return sqrt(moved);
    }
};

void kmeans_thrust(const double *points, int n_points, double *centroids, int *labels,
                   const struct options_t *opts, int *n_iter)
{
    int k = opts->n_cluster;
    int dims = opts->dims;
    int entries = k * dims;
    int expanded = n_points * dims;

    struct gpu_timer transfer;
    struct gpu_timer kernel;
    timer_init(&transfer, opts->verbose);
    timer_init(&kernel, opts->verbose);

    timer_start(&transfer);
    thrust::device_vector<double> d_points(points, points + (size_t)n_points * dims);
    thrust::device_vector<double> d_centroids(centroids, centroids + entries);
    timer_stop(&transfer);

    thrust::device_vector<double> d_new_centroids(entries);
    thrust::device_vector<int> d_labels(n_points);
    thrust::device_vector<int> d_sorted_labels(n_points);
    thrust::device_vector<int> d_order(n_points);
    thrust::device_vector<int> d_keys(expanded);
    thrust::device_vector<double> d_values(expanded);
    thrust::device_vector<int> d_sum_keys(entries);
    thrust::device_vector<double> d_sum_values(entries);
    thrust::device_vector<int> d_count_keys(k);
    thrust::device_vector<int> d_count_values(k);
    thrust::device_vector<double> d_sums(entries);
    thrust::device_vector<int> d_counts(k);

    const double *points_ptr = thrust::raw_pointer_cast(d_points.data());
    const double *centroids_ptr = thrust::raw_pointer_cast(d_centroids.data());
    const double *new_centroids_ptr = thrust::raw_pointer_cast(d_new_centroids.data());
    const int *sorted_ptr = thrust::raw_pointer_cast(d_sorted_labels.data());
    const int *order_ptr = thrust::raw_pointer_cast(d_order.data());
    const double *sums_ptr = thrust::raw_pointer_cast(d_sums.data());
    const int *counts_ptr = thrust::raw_pointer_cast(d_counts.data());

    thrust::counting_iterator<int> first(0);

    int iter = 0;
    bool converged = false;

    while (!converged && iter < opts->max_iter)
    {
        timer_start(&kernel);

        thrust::transform(first, first + n_points, d_labels.begin(),
                          nearest_centroid(points_ptr, centroids_ptr, k, dims));

        thrust::sequence(d_order.begin(), d_order.end());
        thrust::copy(d_labels.begin(), d_labels.end(), d_sorted_labels.begin());
        thrust::stable_sort_by_key(d_sorted_labels.begin(), d_sorted_labels.end(),
                                   d_order.begin());

        thrust::transform(first, first + expanded, d_keys.begin(), expand_key(sorted_ptr, dims));
        thrust::transform(first, first + expanded, d_values.begin(),
                          gather_value(points_ptr, order_ptr, dims));

        thrust::pair<thrust::device_vector<int>::iterator,
                     thrust::device_vector<double>::iterator> sum_end =
            thrust::reduce_by_key(d_keys.begin(), d_keys.end(), d_values.begin(),
                                  d_sum_keys.begin(), d_sum_values.begin());
        int n_sums = sum_end.first - d_sum_keys.begin();

        thrust::pair<thrust::device_vector<int>::iterator,
                     thrust::device_vector<int>::iterator> count_end =
            thrust::reduce_by_key(d_sorted_labels.begin(), d_sorted_labels.end(),
                                  thrust::constant_iterator<int>(1),
                                  d_count_keys.begin(), d_count_values.begin());
        int n_counts = count_end.first - d_count_keys.begin();

        // a cluster nobody joined is simply never scattered, so its count stays zero
        thrust::fill(d_sums.begin(), d_sums.end(), 0.0);
        thrust::fill(d_counts.begin(), d_counts.end(), 0);
        thrust::scatter(d_sum_values.begin(), d_sum_values.begin() + n_sums,
                        d_sum_keys.begin(), d_sums.begin());
        thrust::scatter(d_count_values.begin(), d_count_values.begin() + n_counts,
                        d_count_keys.begin(), d_counts.begin());

        thrust::transform(first, first + entries, d_new_centroids.begin(),
                          divide_sums(sums_ptr, counts_ptr, centroids_ptr, dims));

        double worst = thrust::transform_reduce(
            first, first + k, centroid_shift(centroids_ptr, new_centroids_ptr, dims),
            0.0, thrust::maximum<double>());

        converged = worst <= opts->threshold;
        thrust::copy(d_new_centroids.begin(), d_new_centroids.end(), d_centroids.begin());

        timer_stop(&kernel);
        iter++;
    }

    timer_start(&transfer);
    thrust::copy(d_centroids.begin(), d_centroids.end(), centroids);
    thrust::copy(d_labels.begin(), d_labels.end(), labels);
    timer_stop(&transfer);

    if (opts->verbose)
    {
        fprintf(stderr, "thrust: %d iters, kernel %.3f ms, transfer %.3f ms\n",
                iter, kernel.total_ms, transfer.total_ms);
    }

    *n_iter = iter;

    timer_free(&transfer);
    timer_free(&kernel);
}

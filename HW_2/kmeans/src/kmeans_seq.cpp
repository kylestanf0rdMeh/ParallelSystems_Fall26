#include "kmeans.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

static double sq_distance(const double *a, const double *b, int dims)
{
    double total = 0.0;
    for (int j = 0; j < dims; j++)
    {
        double diff = a[j] - b[j];
        total += diff * diff;
    }
    return total;
}

static int nearest_centroid(const double *point, const double *centroids, int n_cluster, int dims)
{
    int best = 0;
    double best_dist = sq_distance(point, centroids, dims);

    for (int c = 1; c < n_cluster; c++)
    {
        double dist = sq_distance(point, centroids + c * dims, dims);
        if (dist < best_dist)
        {
            best_dist = dist;
            best = c;
        }
    }
    return best;
}

void kmeans_seq(const double *points, int n_points, double *centroids, int *labels,
                const struct options_t *opts, int *n_iter)
{
    int k = opts->n_cluster;
    int dims = opts->dims;

    double *sums = (double *)malloc(k * dims * sizeof(double));
    int *counts = (int *)malloc(k * sizeof(int));
    double *updated = (double *)malloc(k * dims * sizeof(double));

    int iter = 0;
    bool converged = false;

    while (!converged && iter < opts->max_iter)
    {
        memset(sums, 0, k * dims * sizeof(double));
        memset(counts, 0, k * sizeof(int));

        for (int p = 0; p < n_points; p++)
        {
            int c = nearest_centroid(points + p * dims, centroids, k, dims);
            labels[p] = c;
            counts[c]++;
            for (int j = 0; j < dims; j++)
            {
                sums[c * dims + j] += points[p * dims + j];
            }
        }

        for (int c = 0; c < k; c++)
        {
            for (int j = 0; j < dims; j++)
            {
                // a cluster nobody joined keeps its old centroid rather than dividing by zero
                updated[c * dims + j] = counts[c] > 0 ? sums[c * dims + j] / counts[c]
                                                      : centroids[c * dims + j];
            }
        }

        double worst = 0.0;
        for (int c = 0; c < k; c++)
        {
            double moved = sq_distance(centroids + c * dims, updated + c * dims, dims);
            if (moved > worst)
            {
                worst = moved;
            }
        }
        converged = sqrt(worst) <= opts->threshold;

        memcpy(centroids, updated, k * dims * sizeof(double));
        iter++;
    }

    *n_iter = iter;

    free(sums);
    free(counts);
    free(updated);
}

#ifndef _KMEANS_H
#define _KMEANS_H

#include "argparse.h"

void kmeans_seq(const double *points, int n_points, double *centroids, int *labels,
                const struct options_t *opts, int *n_iter);

void kmeans_gpu_warmup();

void kmeans_cuda(const double *points, int n_points, double *centroids, int *labels,
                 const struct options_t *opts, int *n_iter);

void kmeans_shared(const double *points, int n_points, double *centroids, int *labels,
                   const struct options_t *opts, int *n_iter);

void kmeans_thrust(const double *points, int n_points, double *centroids, int *labels,
                   const struct options_t *opts, int *n_iter);

#endif

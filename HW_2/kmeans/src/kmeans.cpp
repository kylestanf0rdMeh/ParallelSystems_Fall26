#include "argparse.h"
#include "io.h"
#include "kmeans.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>

static unsigned long int next_rand = 1;
static unsigned long kmeans_rmax = 32767;

// fixed generator from the assignment, so the starting centroids match across platforms
static int kmeans_rand()
{
    next_rand = next_rand * 1103515245 + 12345;
    return (unsigned int)(next_rand / 65536) % (kmeans_rmax + 1);
}

static void kmeans_srand(unsigned int seed)
{
    next_rand = seed;
}

static void pick_initial_centroids(const double *points, int n_points, double *centroids,
                                   const struct options_t *opts)
{
    kmeans_srand(opts->seed);

    for (int i = 0; i < opts->n_cluster; i++)
    {
        int index = kmeans_rand() % n_points;
        for (int j = 0; j < opts->dims; j++)
        {
            centroids[i * opts->dims + j] = points[index * opts->dims + j];
        }
    }
}

int main(int argc, char **argv)
{
    struct options_t opts;
    get_opts(argc, argv, &opts);

    int n_points = 0;
    double *points = read_points(opts.in_file, opts.dims, &n_points);

    double *centroids = (double *)malloc(opts.n_cluster * opts.dims * sizeof(double));
    int *labels = (int *)malloc(n_points * sizeof(int));

    pick_initial_centroids(points, n_points, centroids, &opts);

    int n_iter = 0;
    auto start = std::chrono::high_resolution_clock::now();

    switch (opts.backend)
    {
    case BACKEND_SEQ:
        kmeans_seq(points, n_points, centroids, labels, &opts, &n_iter);
        break;
    default:
        std::cerr << "that backend is not implemented yet" << std::endl;
        exit(1);
    }

    auto end = std::chrono::high_resolution_clock::now();
    double elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();

    printf("%d,%lf\n", n_iter, elapsed_ms / n_iter);

    if (opts.print_centroids)
    {
        print_centroids(centroids, opts.n_cluster, opts.dims);
    }
    else
    {
        print_labels(labels, n_points);
    }

    free(points);
    free(centroids);
    free(labels);
    return 0;
}

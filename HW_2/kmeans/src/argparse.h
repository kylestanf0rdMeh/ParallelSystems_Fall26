#ifndef _ARGPARSE_H
#define _ARGPARSE_H

#include <cstdlib>
#include <iostream>
#include <getopt.h>

enum backend_t {
    BACKEND_SEQ,
    BACKEND_CUDA,
    BACKEND_SHARED,
    BACKEND_THRUST
};

struct options_t {
    char *in_file;
    int n_cluster;
    int dims;
    int max_iter;
    double threshold;
    int seed;
    bool print_centroids;
    bool verbose;
    backend_t backend;
};

void get_opts(int argc, char **argv, struct options_t *opts);

#endif

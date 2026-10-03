#include "argparse.h"

#include <cstring>

static void usage(char *name)
{
    std::cout << "Usage: " << name << std::endl;
    std::cout << "\t--clusters or -k <num_clusters>" << std::endl;
    std::cout << "\t--dims or -d <dimensions>" << std::endl;
    std::cout << "\t--in or -i <file_path>" << std::endl;
    std::cout << "\t--max_iter or -m <max_iterations>" << std::endl;
    std::cout << "\t--threshold or -t <threshold>" << std::endl;
    std::cout << "\t--seed or -s <seed>" << std::endl;
    std::cout << "\t[Optional] --centroids or -c" << std::endl;
    std::cout << "\t[Optional] --alg <seq|cuda|shared|thrust>" << std::endl;
    std::cout << "\t[Optional] --verbose" << std::endl;
}

static backend_t parse_backend(const char *name)
{
    if (strcmp(name, "seq") == 0) {
        return BACKEND_SEQ;
    }
    if (strcmp(name, "cuda") == 0) {
        return BACKEND_CUDA;
    }
    if (strcmp(name, "shared") == 0) {
        return BACKEND_SHARED;
    }
    if (strcmp(name, "thrust") == 0) {
        return BACKEND_THRUST;
    }

    std::cerr << "unknown backend: " << name << std::endl;
    exit(1);
}

void get_opts(int argc, char **argv, struct options_t *opts)
{
    if (argc == 1)
    {
        usage(argv[0]);
        exit(0);
    }

    opts->in_file = NULL;
    opts->n_cluster = 0;
    opts->dims = 0;
    opts->max_iter = 150;
    opts->threshold = 1e-5;
    opts->seed = 0;
    opts->print_centroids = false;
    opts->verbose = false;
    opts->backend = BACKEND_SEQ;

    struct option l_opts[] = {
        {"clusters", required_argument, NULL, 'k'},
        {"dims", required_argument, NULL, 'd'},
        {"in", required_argument, NULL, 'i'},
        {"max_iter", required_argument, NULL, 'm'},
        {"threshold", required_argument, NULL, 't'},
        {"seed", required_argument, NULL, 's'},
        {"centroids", no_argument, NULL, 'c'},
        {"alg", required_argument, NULL, 'a'},
        {"verbose", no_argument, NULL, 'v'},
        {NULL, 0, NULL, 0}
    };

    int ind, c;
    while ((c = getopt_long(argc, argv, "k:d:i:m:t:s:ca:v", l_opts, &ind)) != -1)
    {
        switch (c)
        {
        case 0:
            break;
        case 'k':
            opts->n_cluster = atoi((char *)optarg);
            break;
        case 'd':
            opts->dims = atoi((char *)optarg);
            break;
        case 'i':
            opts->in_file = (char *)optarg;
            break;
        case 'm':
            opts->max_iter = atoi((char *)optarg);
            break;
        case 't':
            opts->threshold = atof((char *)optarg);
            break;
        case 's':
            opts->seed = atoi((char *)optarg);
            break;
        case 'c':
            opts->print_centroids = true;
            break;
        case 'a':
            opts->backend = parse_backend((char *)optarg);
            break;
        case 'v':
            opts->verbose = true;
            break;
        case ':':
            std::cerr << argv[0] << ": option -" << (char)optopt << " requires an argument." << std::endl;
            exit(1);
        }
    }

    if (opts->in_file == NULL || opts->n_cluster < 1 || opts->dims < 1)
    {
        std::cerr << "need at least -i, -k and -d" << std::endl;
        exit(1);
    }
}

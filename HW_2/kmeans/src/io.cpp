#include "io.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>

double *read_points(const char *file_name, int dims, int *n_points)
{
    std::ifstream in(file_name);
    if (!in.is_open())
    {
        std::cerr << "could not open " << file_name << std::endl;
        exit(1);
    }

    int n = 0;
    in >> n;
    if (n < 1)
    {
        std::cerr << "bad point count in " << file_name << std::endl;
        exit(1);
    }

    double *points = (double *)malloc(n * dims * sizeof(double));

    for (int p = 0; p < n; p++)
    {
        // every line starts with a 1 based index that the algorithm never uses
        int index;
        in >> index;
        for (int j = 0; j < dims; j++)
        {
            in >> points[p * dims + j];
        }
    }

    if (in.fail())
    {
        std::cerr << "ran out of values reading " << file_name
                  << ", check that -d matches the file" << std::endl;
        exit(1);
    }

    in.close();
    *n_points = n;
    return points;
}

void print_centroids(const double *centroids, int n_cluster, int dims)
{
    for (int c = 0; c < n_cluster; c++)
    {
        printf("%d ", c);
        for (int j = 0; j < dims; j++)
        {
            printf("%lf ", centroids[c * dims + j]);
        }
        printf("\n");
    }
}

void print_labels(const int *labels, int n_points)
{
    printf("clusters:");
    for (int p = 0; p < n_points; p++)
    {
        printf(" %d", labels[p]);
    }
    printf("\n");
}

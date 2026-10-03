#ifndef _IO_H
#define _IO_H

double *read_points(const char *file_name, int dims, int *n_points);
void print_centroids(const double *centroids, int n_cluster, int dims);
void print_labels(const int *labels, int n_points);

#endif

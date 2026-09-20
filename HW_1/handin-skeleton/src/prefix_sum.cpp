#include "prefix_sum.h"
#include "helpers.h"

static void split_range(int n_items, int n_threads, int t_id, int *begin, int *end)
{
    int chunk = n_items / n_threads;
    int extra = n_items % n_threads;
    int lo = t_id * chunk + (t_id < extra ? t_id : extra);
    int len = chunk + (t_id < extra ? 1 : 0);

    *begin = lo;
    *end = lo + len;
}

void* compute_prefix_sum(void *a)
{
    prefix_sum_args_t *args = (prefix_sum_args_t *)a;

    int n_vals = args->n_vals;
    int padded = next_power_of_two(n_vals);
    int *work = args->work;
    int begin, end;

    // zero is the identity for the operator, so the padded tail cannot change any real result
    split_range(padded, args->n_threads, args->t_id, &begin, &end);
    for (int i = begin; i < end; ++i) {
        work[i] = i < n_vals ? args->input_vals[i] : 0;
    }
    pthread_barrier_wait(args->bar);

    for (int stride = 2; stride <= padded; stride *= 2) {
        split_range(padded / stride, args->n_threads, args->t_id, &begin, &end);
        for (int node = begin; node < end; ++node) {
            int i = node * stride;
            work[i + stride - 1] = args->op(work[i + stride / 2 - 1],
                                            work[i + stride - 1],
                                            args->n_loops);
        }
        pthread_barrier_wait(args->bar);
    }

    // clearing the root turns the reduction tree into an exclusive scan
    if (args->t_id == 0) {
        work[padded - 1] = 0;
    }
    pthread_barrier_wait(args->bar);

    for (int stride = padded; stride >= 2; stride /= 2) {
        split_range(padded / stride, args->n_threads, args->t_id, &begin, &end);
        for (int node = begin; node < end; ++node) {
            int i = node * stride;
            int left = work[i + stride / 2 - 1];
            work[i + stride / 2 - 1] = work[i + stride - 1];
            work[i + stride - 1] = args->op(left, work[i + stride - 1], args->n_loops);
        }
        pthread_barrier_wait(args->bar);
    }

    // the sweeps leave an exclusive scan, so fold each input back in to make it inclusive
    split_range(n_vals, args->n_threads, args->t_id, &begin, &end);
    for (int i = begin; i < end; ++i) {
        args->output_vals[i] = args->op(work[i], args->input_vals[i], args->n_loops);
    }

    return 0;
}

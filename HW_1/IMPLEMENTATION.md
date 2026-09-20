# What was built, how it works, and why

A plain-language walkthrough of the HW_1 implementation, written so you can answer questions
about any line of it. This is not the report. The report draft is in `report/report.md`.

---

## The problem in one paragraph

A prefix scan turns a list into its running totals. Given `[3, 1, 4, 1]` an inclusive scan
gives `[3, 4, 8, 9]`. Each output depends on every element before it, so the obvious
implementation is a sequential loop and the obvious conclusion is that it cannot be
parallelised. It can, but only by restructuring the computation so that independent pieces
exist to hand out.

The catch is that the naive parallel restructuring does `O(n log n)` operator calls where the
sequential loop does `n`. The assignment forbids that. It requires a **work-efficient** scan,
meaning the same `O(n)` work complexity as the sequential version.

---

## The algorithm

The work-efficient scan is the one in the GPU Gems chapter the assignment links. It treats the
array as a balanced binary tree and makes two passes over it.

### Pass one, the up-sweep

Think of the array as the leaves of a binary tree. Walk up the tree combining pairs. After the
first level, every second slot holds the sum of itself and its neighbour. After the second
level, every fourth slot holds the sum of four elements. And so on, until the last slot holds
the total of the whole array.

In the code this is the loop where `stride` doubles from 2 up to the padded size:

```cpp
for (int stride = 2; stride <= padded; stride *= 2) {
    split_range(padded / stride, args->n_threads, args->t_id, &begin, &end);
    for (int node = begin; node < end; ++node) {
        int i = node * stride;
        work[i + stride - 1] = args->op(work[i + stride / 2 - 1],
                                        work[i + stride - 1],
                                        args->n_loops);
    }
    barrier_wait(args);
}
```

`padded / stride` is the number of nodes active at this level. It halves every level: 8192
nodes, then 4096, then 2048, down to 1. Each thread takes a contiguous slice of those nodes.

This pass does `n - 1` operator calls in total, the same as a sequential sum.

### Pass two, the down-sweep

Now push partial results back down the tree. First the root is overwritten with zero, which is
the identity for addition:

```cpp
if (args->t_id == 0) {
    work[padded - 1] = 0;
}
```

That one line is what converts a reduction tree into a scan. Then walk back down. At each node,
the left child receives the parent's value, and the right child receives the parent's value
combined with the left child's old value:

```cpp
int left = work[i + stride / 2 - 1];
work[i + stride / 2 - 1] = work[i + stride - 1];
work[i + stride - 1] = args->op(left, work[i + stride - 1], args->n_loops);
```

Another `n - 1` operator calls. When it finishes, every slot holds the sum of everything
strictly before it. That is an **exclusive** scan.

### Pass three, making it inclusive

The assignment requires an inclusive scan, where each slot includes itself. Converting is one
more pass, and every element is independent, so it parallelises perfectly:

```cpp
args->output_vals[i] = args->op(work[i], args->input_vals[i], args->n_loops);
```

### Why this matters for your numbers

Add up the three passes and the parallel version performs roughly `3n` operator calls against
the sequential `n`. It is work-efficient in the `O(n)` sense the assignment demands, but the
constant factor is 3.

That constant is the single most important thing in your results. It means perfect scaling on
8 cores gives `8/3 = 2.67` speedup, not 8. It also means two threads should be *slower* than
sequential by a factor of `3/2 = 1.5`, because two threads splitting triple work still do 1.5
times the work of one thread doing single work. Your measurements came back at 1.50, 1.51 and
1.53. The model is not hand-waving, it predicts your data to two decimal places.

---

## The padding

The tree only works on a power-of-two length, and the assignment says input size might not be
one. The skeleton supplies `next_power_of_two` for exactly this and left it unused.

So we allocate a scratch buffer at the padded size, copy the input in, and fill the tail with
zeros:

```cpp
work[i] = i < n_vals ? args->input_vals[i] : 0;
```

Zero is the identity for the operator, so the padding contributes nothing to any real result.
It costs some wasted work in the worst case, an input of 8193 pads to 16384, but it keeps the
index arithmetic simple and correct.

This matters because all four supplied test inputs are powers of two. The padding path would
never have been exercised. That is why `check.sh` generates a 1000-element input of its own.

---

## Why the scratch buffer exists at all

The down-sweep destroys the tree as it goes, and the final inclusive pass needs the original
inputs. If we swept in place over `output_vals` we would still have the originals in
`input_vals`, so that alone would work. But we would also be writing into an array sized
`n_vals` while the tree needs `padded` slots. The separate buffer solves the sizing problem,
and keeping the input pristine makes the final pass trivially correct.

It is allocated in `main.cpp` before the timer starts, so allocation is not counted as scan
time. The instructor confirmed on the forum that setup and transfer costs are excluded from
measured runtime.

---

## The barriers

Between every tree level, all threads must finish before any thread proceeds. Level `k+1`
reads slots that level `k` wrote. Without a barrier, a fast thread reads a stale value and the
answer is silently wrong, usually only at some sizes and some thread counts, which is the worst
kind of bug.

There are about `2 * log2(n)` barriers per run, plus three more for the copy, the root clear,
and the final pass. At 16384 elements that is 31 barrier crossings.

### Part 1 used the pthread barrier

`pthread_barrier_wait` is the library primitive. Threads that arrive early are put to sleep by
the kernel and woken when the last one arrives.

### Part 3 is our own

```cpp
void spin_barrier::wait()
{
    static thread_local bool local_sense = false;
    local_sense = !local_sense;

    pthread_spin_lock(&lock);
    count++;
    bool last = count == n_threads;
    if (last) {
        count = 0;
    }
    pthread_spin_unlock(&lock);

    if (last) {
        sense.store(local_sense);
    } else {
        while (sense.load() != local_sense) {
        }
    }
}
```

A spinlock guards an arrival counter. The last thread to arrive resets the counter and flips a
shared flag. Everyone else spins reading that flag until it changes. Nobody sleeps, so nobody
pays for a system call or a context switch.

**Sense reversal is the part worth understanding.** The assignment requires the barrier to be
re-entrant, meaning reusable across all 31 rounds. A naive version has a fatal race: thread A
is released, races through the next tree level, and arrives back at the barrier while thread B
has not yet noticed the release flag from the *previous* round. If the flag is still set, B
sails through a barrier it should have waited at.

Sense reversal fixes this by making the release condition alternate. Each thread keeps its own
copy of the expected value and flips it on entry. Round one releases on `true`, round two on
`false`, round three on `true`. A thread that laps into the next round is now waiting on the
opposite value from the one that just released it, so it cannot be released early. No reset
step is needed, which is what makes it safe without a second barrier to protect the first.

`thread_local` gives each thread its own `local_sense` without any shared state. This is safe
here because the program creates exactly one barrier object.

`std::atomic<bool>` is not decoration. The compiler is running at `-O3` and would otherwise be
free to hoist the flag read out of the spin loop, producing a genuine infinite loop. The atomic
also establishes the memory ordering that makes the previous level's writes to `work` visible
to every thread after the barrier. Default sequential consistency is stronger than needed;
acquire and release would be cheaper, which is noted in the report.

---

## How the pieces connect

`prefix_sum_args_t` in `helpers.h` gained three fields: the scratch buffer and both barriers.
All threads receive pointers to the same three, which is how they share state. The existing
`spin` flag, already parsed from `-s`, selects which barrier to use:

```cpp
static void barrier_wait(prefix_sum_args_t *args)
{
    if (args->spin) {
        args->sbar->wait();
    } else {
        pthread_barrier_wait(args->bar);
    }
}
```

Everything else in the skeleton is untouched. Argument parsing, file I/O, timing, thread
creation and joining were all already written. `main.cpp` changed in three places: allocate the
buffer and construct the barriers, pass them into `fill_args`, and supply `compute_prefix_sum`
to the `start_threads` call that was left commented out.

The `Makefile` is unmodified, as required.

---

## Work partitioning

`split_range` hands each thread a contiguous slice of whatever is being divided:

```cpp
int chunk = n_items / n_threads;
int extra = n_items % n_threads;
int lo = t_id * chunk + (t_id < extra ? t_id : extra);
int len = chunk + (t_id < extra ? 1 : 0);
```

The remainder is spread one element each across the first `extra` threads rather than dumped on
the last one. With 1000 items and 3 threads you get 334, 333, 333, not 333, 333, 334.

Two properties matter. The slices exactly partition the range, with no gap and no overlap, so
there is no data race. And when there are fewer items than threads, the surplus threads get
empty ranges but still reach every barrier. That second property is what keeps the top levels
of the tree from deadlocking, where only one or two nodes are active but all 32 threads must
still arrive.

---

## Testing

`check.sh` is ours. The supplied `run_tests.py` only parsed timing and never looked at output,
so no correctness check existed.

It generates a golden file with `-n 0`, the true sequential path, then diffs parallel output
against it across five inputs and nine thread counts including odd ones like 3, 5 and 13.
Running it with `-s` exercises the spin barrier instead. All 45 cases pass on both barriers.

Odd thread counts matter because they stress `split_range`'s remainder handling. The
1000-element input matters because it is the only non-power-of-two case.

---

## Measurement method

`run_tests.py` was rewritten into a sweep that writes CSV. Each configuration runs five times
and the **minimum** is kept.

Minimum rather than average or median because Codio is a shared virtual machine. Interference
from other tenants can only make a run slower, never faster, so the fastest of several runs is
the closest estimate of true cost. This matters much more for the spin barrier, where a stolen
core makes every other thread burn its quantum spinning.

`make_plots.py` builds the graphs locally from the CSVs. The instructor confirmed any tool is
acceptable for graphs, and approved plotting speedup as sequential divided by parallel rather
than the other way round.

---

## Where the bodies are buried

Things that would have bitten us, listed so you are not surprised if asked.

**The operator is not free and not what it looks like.** `op(a, b, n_loop)` spins a `volatile`
counter `n_loop` times, then returns `(a+b) * (acc/n_loop)`, and `acc/n_loop` is always 1. So
it computes `a + b` but costs proportional to `-l`. It is marked `noinline` so the optimiser
cannot delete the busy work. Passing `-l 0` would divide by zero.

**`-n 0` and `-n 1` are different.** Zero runs the sequential loop with no threads at all. One
spawns a single thread and pays creation, barrier and teardown costs. The assignment calls this
out specifically, and the golden file for correctness testing has to come from `-n 0`.

**Barrier count is independent of input size in a useful way.** It is `2 * log2(n)`, so going
from 1024 to 16384 elements multiplies the work by 16 but the barrier count only goes from 21
to 31. That is why larger inputs amortise coordination better and cross over to parallel at
cheaper operators.

**The spin barrier degrades non-linearly past the core count.** Not gradually. At 8 threads it
beats the pthread barrier roughly threefold. At 10 threads it is 15 to 20 times worse. The
cliff is at exactly the core count, and `barrier_ratio_l10.png` shows it cleanly.

**Low `-l` values make the spin barrier erratic.** At `-l 1` there is essentially no work
between barriers, so eight threads hammer one spinlock cache line continuously. Those numbers
swing wildly between runs and minimum-of-five does not tame them, which says it is systematic
rather than interference. The report uses the pthread column for the stated crossover points
and discusses the spin behaviour separately rather than pretending those are clean
measurements.

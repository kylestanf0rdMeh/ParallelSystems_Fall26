// lab 3: find the equivalent binary search trees in an input file using goroutines.
// -data-workers turns on hash grouping and -comp-workers turns on tree comparison.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type node struct {
	val         int
	left, right *node
}

// insert adds v under root and returns the root. duplicate values are dropped.
func insert(root *node, v int) *node {
	n := &node{val: v}
	if root == nil {
		return n
	}
	cur := root
	for {
		switch {
		case v < cur.val:
			if cur.left == nil {
				cur.left = n
				return root
			}
			cur = cur.left
		case v > cur.val:
			if cur.right == nil {
				cur.right = n
				return root
			}
			cur = cur.right
		default:
			return root
		}
	}
}

func inorder(n *node, visit func(int)) {
	if n == nil {
		return
	}
	inorder(n.left, visit)
	visit(n.val)
	inorder(n.right, visit)
}

func hashTree(root *node) int {
	hash := 1
	inorder(root, func(v int) {
		v += 2
		hash = (hash*v + v) % 1000
	})
	return hash
}

// walker steps through a tree in order with an explicit stack, so two trees can be walked
// side by side and the comparison can stop at the first value that differs.
type walker struct {
	stack []*node
}

func newWalker(root *node) *walker {
	w := &walker{}
	w.pushLeft(root)
	return w
}

func (w *walker) pushLeft(n *node) {
	for ; n != nil; n = n.left {
		w.stack = append(w.stack, n)
	}
}

func (w *walker) next() (int, bool) {
	if len(w.stack) == 0 {
		return 0, false
	}
	n := w.stack[len(w.stack)-1]
	w.stack = w.stack[:len(w.stack)-1]
	w.pushLeft(n.right)
	return n.val, true
}

func sameTrees(a, b *node) bool {
	wa, wb := newWalker(a), newWalker(b)
	for {
		va, moreA := wa.next()
		vb, moreB := wb.next()
		if moreA != moreB || va != vb {
			return false
		}
		if !moreA {
			return true
		}
	}
}

// readTrees builds one tree per line of the input file. a tree's id is its line number.
func readTrees(path string) []*node {
	data, err := ioutil.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	lines := strings.Split(strings.TrimRight(string(data), " \r\n"), "\n")
	trees := make([]*node, len(lines))
	for i, line := range lines {
		var root *node
		for _, field := range strings.Fields(line) {
			v, err := strconv.Atoi(field)
			if err != nil {
				fmt.Fprintf(os.Stderr, "line %d: %v\n", i, err)
				os.Exit(1)
			}
			root = insert(root, v)
		}
		trees[i] = root
	}
	return trees
}

// parallelFor splits [0, n) into one contiguous block per worker, runs body on every index
// and returns once all the workers are done. one worker runs in the calling goroutine.
func parallelFor(n, workers int, body func(i int)) {
	if workers > n {
		workers = n
	}
	if workers <= 1 {
		for i := 0; i < n; i++ {
			body(i)
		}
		return
	}
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(lo, hi int) {
			defer wg.Done()
			for i := lo; i < hi; i++ {
				body(i)
			}
		}(w*n/workers, (w+1)*n/workers)
	}
	wg.Wait()
}

func hashAll(trees []*node, workers int) []int {
	hashes := make([]int, len(trees))
	parallelFor(len(trees), workers, func(i int) {
		hashes[i] = hashTree(trees[i])
	})
	return hashes
}

// hashGroups maps hash -> tree ids, split into shards by hash so the fine grained versions
// can give each shard its own lock or manager. the plain versions use one shard.
type hashGroups struct {
	shards []map[int][]int
	locks  []sync.Mutex
}

func newHashGroups(shards int) *hashGroups {
	g := &hashGroups{
		shards: make([]map[int][]int, shards),
		locks:  make([]sync.Mutex, shards),
	}
	for s := range g.shards {
		g.shards[s] = make(map[int][]int)
	}
	return g
}

func (g *hashGroups) shardOf(hash int) int {
	return hash % len(g.shards)
}

func (g *hashGroups) add(hash, id int) {
	m := g.shards[g.shardOf(hash)]
	m[hash] = append(m[hash], id)
}

func (g *hashGroups) lockedAdd(hash, id int) {
	s := g.shardOf(hash)
	g.locks[s].Lock()
	g.add(hash, id)
	g.locks[s].Unlock()
}

type hashedTree struct {
	hash, id int
}

// groupByChannel has the hash workers send (hash, id) pairs to manager goroutines that own
// the map. with one manager this is the central manager version, with more each manager
// owns one shard and gets its own channel.
func groupByChannel(trees []*node, hashWorkers, managers int) *hashGroups {
	groups := newHashGroups(managers)
	chans := make([]chan hashedTree, managers)
	var done sync.WaitGroup
	for s := range chans {
		chans[s] = make(chan hashedTree, hashWorkers)
		done.Add(1)
		go func(in chan hashedTree) {
			defer done.Done()
			for t := range in {
				groups.add(t.hash, t.id)
			}
		}(chans[s])
	}

	parallelFor(len(trees), hashWorkers, func(i int) {
		h := hashTree(trees[i])
		chans[groups.shardOf(h)] <- hashedTree{h, i}
	})
	for _, c := range chans {
		close(c)
	}
	done.Wait()
	return groups
}

// groupByLock has every hash worker insert its own results. with one shard they all share
// a single mutex, with more each shard has its own.
func groupByLock(trees []*node, hashWorkers, shards int) *hashGroups {
	groups := newHashGroups(shards)
	parallelFor(len(trees), hashWorkers, func(i int) {
		groups.lockedAdd(hashTree(trees[i]), i)
	})
	return groups
}

// buckets returns the id lists of every hash shared by more than one tree.
func (g *hashGroups) buckets() [][]int {
	var out [][]int
	for _, m := range g.shards {
		for _, ids := range m {
			if len(ids) > 1 {
				out = append(out, ids)
			}
		}
	}
	return out
}

func (g *hashGroups) print(out *bufio.Writer) {
	for _, m := range g.shards {
		for hash, ids := range m {
			if len(ids) > 1 {
				fmt.Fprintf(out, "%d:", hash)
				printIds(out, ids)
			}
		}
	}
}

func printIds(out *bufio.Writer, ids []int) {
	for _, id := range ids {
		fmt.Fprintf(out, " %d", id)
	}
	fmt.Fprintln(out)
}

// pair names two trees to compare: positions x < y inside hash bucket b.
type pair struct {
	b, x, y int
}

// workQueue is the bounded buffer feeding the comparison workers, a ring of len(items) pairs.
type workQueue struct {
	mu                sync.Mutex
	notFull, notEmpty *sync.Cond
	items             []pair
	head, count       int
	closed            bool
}

func newWorkQueue(size int) *workQueue {
	q := &workQueue{items: make([]pair, size)}
	q.notFull = sync.NewCond(&q.mu)
	q.notEmpty = sync.NewCond(&q.mu)
	return q
}

func (q *workQueue) put(p pair) {
	q.mu.Lock()
	for q.count == len(q.items) {
		q.notFull.Wait()
	}
	q.items[(q.head+q.count)%len(q.items)] = p
	q.count++
	q.notEmpty.Signal()
	q.mu.Unlock()
}

// get returns false once the queue has been closed and drained.
func (q *workQueue) get() (pair, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for q.count == 0 && !q.closed {
		q.notEmpty.Wait()
	}
	if q.count == 0 {
		return pair{}, false
	}
	p := q.items[q.head]
	q.head = (q.head + 1) % len(q.items)
	q.count--
	q.notFull.Signal()
	return p, true
}

func (q *workQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.notEmpty.Broadcast()
	q.mu.Unlock()
}

func forEachPair(buckets [][]int, visit func(pair)) {
	for b, ids := range buckets {
		for x := range ids {
			for y := x + 1; y < len(ids); y++ {
				visit(pair{b, x, y})
			}
		}
	}
}

// compareBuckets splits every hash bucket into groups of identical trees. workers == 1 runs
// in the main thread, workers <= 0 is one goroutine per comparison, otherwise a worker pool.
func compareBuckets(trees []*node, buckets [][]int, workers int) [][]int {
	// one adjacency matrix per bucket instead of n by n, since only same-hash trees can match
	same := make([][][]bool, len(buckets))
	for b, ids := range buckets {
		same[b] = make([][]bool, len(ids))
		for x := range ids {
			same[b][x] = make([]bool, len(ids))
		}
	}
	compare := func(p pair) {
		ids := buckets[p.b]
		if sameTrees(trees[ids[p.x]], trees[ids[p.y]]) {
			same[p.b][p.x][p.y] = true
		}
	}

	switch {
	case workers == 1:
		forEachPair(buckets, compare)
	case workers <= 0:
		var wg sync.WaitGroup
		forEachPair(buckets, func(p pair) {
			wg.Add(1)
			go func() {
				defer wg.Done()
				compare(p)
			}()
		})
		wg.Wait()
	default:
		q := newWorkQueue(workers)
		var wg sync.WaitGroup
		for w := 0; w < workers; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for p, ok := q.get(); ok; p, ok = q.get() {
					compare(p)
				}
			}()
		}
		forEachPair(buckets, q.put)
		q.close()
		wg.Wait()
	}

	// equality is transitive, so each unclaimed tree collects everything that matched it
	var groups [][]int
	for b, ids := range buckets {
		claimed := make([]bool, len(ids))
		for x := range ids {
			if claimed[x] {
				continue
			}
			group := []int{ids[x]}
			for y := x + 1; y < len(ids); y++ {
				if same[b][x][y] {
					claimed[y] = true
					group = append(group, ids[y])
				}
			}
			if len(group) > 1 {
				groups = append(groups, group)
			}
		}
	}
	return groups
}

func main() {
	hashWorkers := flag.Int("hash-workers", 1, "goroutines that hash the trees")
	dataWorkers := flag.Int("data-workers", 0, "goroutines that update the hash map")
	compWorkers := flag.Int("comp-workers", 0, "goroutines that compare trees, 0 for one per comparison")
	input := flag.String("input", "", "path to the input file")
	// both fine grained versions are kept for the writeup, the default is the faster one
	fineSync := flag.String("fine-sync", "lock", "fine grained map access: lock or channel")
	flag.Parse()

	given := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { given[f.Name] = true })

	trees := readTrees(*input)
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()

	if !given["data-workers"] && !given["comp-workers"] {
		start := time.Now()
		hashAll(trees, *hashWorkers)
		fmt.Fprintf(out, "hashTime: %f\n", time.Since(start).Seconds())
		return
	}

	// when the hash workers also fill the map the two steps overlap, so both times are the same
	var groups *hashGroups
	var hashTime time.Duration
	start := time.Now()
	i, j := *hashWorkers, *dataWorkers
	switch {
	case i <= 1:
		hashes := hashAll(trees, 1)
		hashTime = time.Since(start)
		groups = newHashGroups(1)
		for id, h := range hashes {
			groups.add(h, id)
		}
	case j <= 1:
		groups = groupByChannel(trees, i, 1)
	case j >= i:
		groups = groupByLock(trees, i, 1)
	case *fineSync == "channel":
		groups = groupByChannel(trees, i, j)
	default:
		groups = groupByLock(trees, i, j)
	}
	groupTime := time.Since(start)
	if hashTime == 0 {
		hashTime = groupTime
	}
	fmt.Fprintf(out, "hashTime: %f\n", hashTime.Seconds())
	fmt.Fprintf(out, "hashGroupTime: %f\n", groupTime.Seconds())
	groups.print(out)

	if !given["comp-workers"] {
		return
	}
	start = time.Now()
	treeGroups := compareBuckets(trees, groups.buckets(), *compWorkers)
	fmt.Fprintf(out, "compareTreeTime: %f\n", time.Since(start).Seconds())
	for k, ids := range treeGroups {
		fmt.Fprintf(out, "group %d:", k)
		printIds(out, ids)
	}
}

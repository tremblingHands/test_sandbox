package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	bolt "go.etcd.io/bbolt"
)

// Scenario bench approximating containerd metadata write pattern under
// concurrent RunPodSandbox: multiple short writable txns per round,
// optional NoSync / merged Update / Batch. See doc §17.

type roundTiming struct {
	total  time.Duration
	wait   time.Duration
	exec   time.Duration
	commit time.Duration
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	if p <= 0 {
		return sorted[0]
	}
	if p >= 100 {
		return sorted[len(sorted)-1]
	}
	idx := int(math.Ceil(p/100*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func mustUpdate(db *bolt.DB, fn func(*bolt.Tx) error) roundTiming {
	var rt roundTiming
	start := time.Now()
	var execStart, execEnd time.Time
	err := db.Update(func(tx *bolt.Tx) error {
		execStart = time.Now()
		err := fn(tx)
		execEnd = time.Now()
		return err
	})
	end := time.Now()
	if err != nil {
		panic(err)
	}
	rt.total = end.Sub(start)
	rt.wait = execStart.Sub(start)
	rt.exec = execEnd.Sub(execStart)
	rt.commit = end.Sub(execEnd)
	return rt
}

func mustBatch(db *bolt.DB, fn func(*bolt.Tx) error) roundTiming {
	var rt roundTiming
	start := time.Now()
	var execAcc time.Duration
	err := db.Batch(func(tx *bolt.Tx) error {
		es := time.Now()
		err := fn(tx)
		execAcc += time.Since(es)
		return err
	})
	end := time.Now()
	if err != nil {
		panic(err)
	}
	rt.total = end.Sub(start)
	rt.exec = execAcc
	// Batch may wait + commit around possibly multiple fn calls; attribute remainder to wait+commit.
	rem := rt.total - rt.exec
	if rem < 0 {
		rem = 0
	}
	rt.wait = rem / 2
	rt.commit = rem - rt.wait
	return rt
}

func putKV(tx *bolt.Tx, bucket, key, val []byte) error {
	b, err := tx.CreateBucketIfNotExists(bucket)
	if err != nil {
		return err
	}
	return b.Put(key, val)
}

func oneRound(db *bolt.DB, txMode string, id uint64, updatesPerRound, keySize, valueSize int) roundTiming {
	key := make([]byte, keySize)
	val := make([]byte, valueSize)
	binary.LittleEndian.PutUint64(key, id)
	for i := range val {
		val[i] = byte(i)
	}

	leaseB := []byte("lease")
	sandB := []byte("sandbox")
	snapB := []byte("snapshot")

	writeAll := func(tx *bolt.Tx) error {
		if err := putKV(tx, leaseB, key, val); err != nil {
			return err
		}
		if err := putKV(tx, sandB, append([]byte("c-"), key...), val); err != nil {
			return err
		}
		for u := 0; u < updatesPerRound; u++ {
			k := append([]byte{}, key...)
			k = append(k, byte(u))
			if err := putKV(tx, sandB, append([]byte("u-"), k...), val); err != nil {
				return err
			}
		}
		return putKV(tx, snapB, append([]byte("p-"), key...), val)
	}

	switch txMode {
	case "merged":
		return mustUpdate(db, writeAll)
	case "batch":
		return mustBatch(db, writeAll)
	case "update":
		var sum roundTiming
		add := func(rt roundTiming) {
			sum.total += rt.total
			sum.wait += rt.wait
			sum.exec += rt.exec
			sum.commit += rt.commit
		}
		add(mustUpdate(db, func(tx *bolt.Tx) error {
			return putKV(tx, leaseB, key, val)
		}))
		add(mustUpdate(db, func(tx *bolt.Tx) error {
			return putKV(tx, sandB, append([]byte("c-"), key...), val)
		}))
		for u := 0; u < updatesPerRound; u++ {
			u := u
			add(mustUpdate(db, func(tx *bolt.Tx) error {
				k := append([]byte{}, key...)
				k = append(k, byte(u))
				return putKV(tx, sandB, append([]byte("u-"), k...), val)
			}))
		}
		add(mustUpdate(db, func(tx *bolt.Tx) error {
			return putKV(tx, snapB, append([]byte("p-"), key...), val)
		}))
		return sum
	default:
		panic("unknown tx mode: " + txMode)
	}
}

func main() {
	var (
		goroutines      = flag.Int("goroutines", 32, "concurrent workers (G)")
		rounds          = flag.Int("rounds", 200, "rounds per worker")
		updatesPerRound = flag.Int("updates-per-round", 3, "sandbox.Update count per round (update mode)")
		syncMode        = flag.String("mode", "sync", "sync | no_sync")
		txMode          = flag.String("tx", "update", "update | merged | batch")
		dbPath          = flag.String("db", "", "db file path (default: temp)")
		keySize         = flag.Int("key-size", 16, "key bytes")
		valueSize       = flag.Int("value-size", 256, "value bytes")
		warmup          = flag.Int("warmup", 1, "warmup rounds per worker before timing")
	)
	flag.Parse()

	if *goroutines < 1 || *rounds < 1 || *updatesPerRound < 0 {
		fmt.Fprintln(os.Stderr, "invalid goroutines/rounds/updates-per-round")
		os.Exit(2)
	}
	switch *syncMode {
	case "sync", "no_sync":
	default:
		fmt.Fprintln(os.Stderr, "--mode must be sync or no_sync")
		os.Exit(2)
	}
	switch *txMode {
	case "update", "merged", "batch":
	default:
		fmt.Fprintln(os.Stderr, "--tx must be update, merged, or batch")
		os.Exit(2)
	}
	if *keySize < 8 {
		fmt.Fprintln(os.Stderr, "--key-size must be >= 8")
		os.Exit(2)
	}

	path := *dbPath
	if path == "" {
		dir, err := os.MkdirTemp("", "bbolt-meta-bench-*")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(dir)
		path = filepath.Join(dir, "meta.db")
	} else {
		_ = os.Remove(path)
	}

	opts := *bolt.DefaultOptions
	if *syncMode == "no_sync" {
		opts.NoSync = true
		opts.NoGrowSync = true
	}
	opts.NoFreelistSync = true

	db, err := bolt.Open(path, 0o600, &opts)
	if err != nil {
		panic(err)
	}
	defer db.Close()

	// Ensure buckets exist.
	_ = mustUpdate(db, func(tx *bolt.Tx) error {
		for _, name := range []string{"lease", "sandbox", "snapshot"} {
			if _, err := tx.CreateBucketIfNotExists([]byte(name)); err != nil {
				return err
			}
		}
		return nil
	})

	var seq atomic.Uint64
	var wg sync.WaitGroup
	timings := make([]roundTiming, 0, *goroutines**rounds)
	var mu sync.Mutex

	// Warmup
	wg.Add(*goroutines)
	for g := 0; g < *goroutines; g++ {
		go func() {
			defer wg.Done()
			for i := 0; i < *warmup; i++ {
				id := seq.Add(1)
				_ = oneRound(db, *txMode, id, *updatesPerRound, *keySize, *valueSize)
			}
		}()
	}
	wg.Wait()

	wall0 := time.Now()
	wg.Add(*goroutines)
	for g := 0; g < *goroutines; g++ {
		go func() {
			defer wg.Done()
			local := make([]roundTiming, 0, *rounds)
			for i := 0; i < *rounds; i++ {
				id := seq.Add(1)
				local = append(local, oneRound(db, *txMode, id, *updatesPerRound, *keySize, *valueSize))
			}
			mu.Lock()
			timings = append(timings, local...)
			mu.Unlock()
		}()
	}
	wg.Wait()
	wall := time.Since(wall0)

	n := len(timings)
	totals := make([]time.Duration, n)
	waits := make([]time.Duration, n)
	execs := make([]time.Duration, n)
	commits := make([]time.Duration, n)
	var sumTotal, sumWait, sumExec, sumCommit time.Duration
	for i, t := range timings {
		totals[i] = t.total
		waits[i] = t.wait
		execs[i] = t.exec
		commits[i] = t.commit
		sumTotal += t.total
		sumWait += t.wait
		sumExec += t.exec
		sumCommit += t.commit
	}
	sort.Slice(totals, func(i, j int) bool { return totals[i] < totals[j] })
	sort.Slice(waits, func(i, j int) bool { return waits[i] < waits[j] })
	sort.Slice(execs, func(i, j int) bool { return execs[i] < execs[j] })
	sort.Slice(commits, func(i, j int) bool { return commits[i] < commits[j] })

	roundsTotal := *goroutines * *rounds
	fmt.Printf("bbolt_metadata_bench\n")
	fmt.Printf("  db=%s\n", path)
	fmt.Printf("  mode=%s tx=%s goroutines=%d rounds/worker=%d updates/round=%d key=%d val=%d\n",
		*syncMode, *txMode, *goroutines, *rounds, *updatesPerRound, *keySize, *valueSize)
	fmt.Printf("  nosync=%v nogrowsync=%v\n", db.NoSync, db.NoGrowSync)
	fmt.Printf("  wall=%s rounds=%d throughput=%.1f rounds/s\n",
		wall, roundsTotal, float64(roundsTotal)/wall.Seconds())
	fmt.Printf("  round_total  avg=%s p50=%s p95=%s p99=%s\n",
		sumTotal/time.Duration(n), percentile(totals, 50), percentile(totals, 95), percentile(totals, 99))
	fmt.Printf("  round_wait   avg=%s p50=%s p95=%s p99=%s  (approx Begin→fn)\n",
		sumWait/time.Duration(n), percentile(waits, 50), percentile(waits, 95), percentile(waits, 99))
	fmt.Printf("  round_exec   avg=%s p50=%s p95=%s p99=%s\n",
		sumExec/time.Duration(n), percentile(execs, 50), percentile(execs, 95), percentile(execs, 99))
	fmt.Printf("  round_commit avg=%s p50=%s p95=%s p99=%s  (approx fn→Update return)\n",
		sumCommit/time.Duration(n), percentile(commits, 50), percentile(commits, 95), percentile(commits, 99))
}

/*
 * Userspace microbench mimicking kernel __netdev_has_upper_dev /
 * __netdev_walk_all_upper_dev (net/core/dev.c): DFS over adj_list.upper
 * with pointer-equality predicate.
 *
 * Build:  cc -O2 -o netdev_has_upper_bench netdev_has_upper_bench.c
 * Or:     ./netdev_has_upper_bench.sh ...
 */
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_NEST_DEV 8

/* Minimal list_head (kernel style). */
struct list_head {
	struct list_head *next, *prev;
};

static inline void INIT_LIST_HEAD(struct list_head *list)
{
	list->next = list;
	list->prev = list;
}

static inline void __list_add(struct list_head *new,
			      struct list_head *prev,
			      struct list_head *next)
{
	next->prev = new;
	new->next = next;
	new->prev = prev;
	prev->next = new;
}

static inline void list_add_tail(struct list_head *new, struct list_head *head)
{
	__list_add(new, head->prev, head);
}

#define list_entry(ptr, type, member) \
	((type *)((char *)(ptr) - offsetof(type, member)))

struct fake_netdev;

/* Mirrors netdev_adjacent layout fields used by the walk. */
struct fake_adjacent {
	struct fake_netdev *dev;
	bool master;
	bool ignore;
	uint16_t ref_nr;
	void *private;
	struct list_head list;
};

struct fake_netdev {
	int id;
	struct {
		struct list_head upper;
	} adj_list;
};

struct nested_priv {
	void *data;
};

static uint64_t nsec_now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static struct fake_netdev *next_upper(struct fake_netdev *dev,
				      struct list_head **iter,
				      bool *ignore)
{
	struct fake_adjacent *upper;

	upper = list_entry((*iter)->next, struct fake_adjacent, list);
	if (&upper->list == &dev->adj_list.upper)
		return NULL;
	*iter = &upper->list;
	*ignore = upper->ignore;
	return upper->dev;
}

/* Same control flow as __netdev_walk_all_upper_dev. */
static int walk_all_upper(struct fake_netdev *dev,
			  int (*fn)(struct fake_netdev *udev,
				    struct nested_priv *priv),
			  struct nested_priv *priv)
{
	struct fake_netdev *udev, *next, *now;
	struct fake_netdev *dev_stack[MAX_NEST_DEV + 1];
	struct list_head *niter, *iter;
	struct list_head *iter_stack[MAX_NEST_DEV + 1];
	int ret, cur = 0;
	bool ignore;

	now = dev;
	iter = &dev->adj_list.upper;

	for (;;) {
		if (now != dev) {
			ret = fn(now, priv);
			if (ret)
				return ret;
		}

		next = NULL;
		for (;;) {
			udev = next_upper(now, &iter, &ignore);
			if (!udev)
				break;
			if (ignore)
				continue;

			next = udev;
			niter = &udev->adj_list.upper;
			dev_stack[cur] = now;
			iter_stack[cur++] = iter;
			break;
		}

		if (!next) {
			if (!cur)
				return 0;
			next = dev_stack[--cur];
			niter = iter_stack[cur];
		}

		now = next;
		iter = niter;
	}
}

static int pred_has_upper(struct fake_netdev *upper_dev,
			  struct nested_priv *priv)
{
	struct fake_netdev *target = priv->data;

	return upper_dev == target;
}

static bool has_upper_dev(struct fake_netdev *dev, struct fake_netdev *upper)
{
	struct nested_priv priv = { .data = upper };

	return walk_all_upper(dev, pred_has_upper, &priv) != 0;
}

static void link_upper(struct fake_netdev *lower, struct fake_netdev *upper,
		       struct fake_adjacent *adj)
{
	adj->dev = upper;
	adj->master = false;
	adj->ignore = false;
	adj->ref_nr = 1;
	adj->private = NULL;
	INIT_LIST_HEAD(&adj->list);
	list_add_tail(&adj->list, &lower->adj_list.upper);
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"用法: %s [选项]\n"
		"  --n N           root 上 upper 个数（默认 450）\n"
		"  --iters N       完整 walk 次数（默认 10000）\n"
		"  --warmup N      计时前预热次数（默认 100）\n"
		"  --find miss|last  查不存在(默认 miss)或命中最后一个\n"
		"  -h, --help\n",
		argv0);
}

int main(int argc, char **argv)
{
	int n = 450;
	int iters = 10000;
	int warmup = 100;
	int find_last = 0;
	int i;
	struct fake_netdev *root, *uppers, *target, sentinel;
	struct fake_adjacent *adjs;
	uint64_t t0, t1, total_ns;
	volatile int sink = 0;
	int hits = 0;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--n") && i + 1 < argc) {
			n = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--iters") && i + 1 < argc) {
			iters = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--warmup") && i + 1 < argc) {
			warmup = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--find") && i + 1 < argc) {
			i++;
			if (!strcmp(argv[i], "miss"))
				find_last = 0;
			else if (!strcmp(argv[i], "last"))
				find_last = 1;
			else {
				fprintf(stderr, "错误: --find 须为 miss 或 last\n");
				return 2;
			}
		} else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			usage(argv[0]);
			return 0;
		} else {
			fprintf(stderr, "错误: 未知参数 %s\n", argv[i]);
			usage(argv[0]);
			return 2;
		}
	}

	if (n < 0 || iters < 1 || warmup < 0) {
		fprintf(stderr, "错误: 无效 --n/--iters/--warmup\n");
		return 2;
	}
	if (find_last && n < 1) {
		fprintf(stderr, "错误: --find last 需要 --n >= 1\n");
		return 2;
	}

	root = calloc(1, sizeof(*root));
	uppers = calloc((size_t)n, sizeof(*uppers));
	adjs = calloc((size_t)n, sizeof(*adjs));
	if (!root || (n > 0 && (!uppers || !adjs))) {
		fprintf(stderr, "错误: calloc 失败\n");
		return 1;
	}

	root->id = -1;
	INIT_LIST_HEAD(&root->adj_list.upper);
	for (i = 0; i < n; i++) {
		uppers[i].id = i;
		INIT_LIST_HEAD(&uppers[i].adj_list.upper);
		link_upper(root, &uppers[i], &adjs[i]);
	}

	memset(&sentinel, 0, sizeof(sentinel));
	sentinel.id = -2;
	INIT_LIST_HEAD(&sentinel.adj_list.upper);
	target = find_last ? &uppers[n - 1] : &sentinel;

	/* Sanity: miss → false; last → true */
	if (find_last) {
		if (!has_upper_dev(root, target)) {
			fprintf(stderr, "错误: sanity --find last 未命中\n");
			return 1;
		}
	} else if (has_upper_dev(root, target)) {
		fprintf(stderr, "错误: sanity --find miss 不应命中\n");
		return 1;
	}

	for (i = 0; i < warmup; i++)
		sink += has_upper_dev(root, target);

	t0 = nsec_now();
	for (i = 0; i < iters; i++) {
		if (has_upper_dev(root, target))
			hits++;
	}
	t1 = nsec_now();
	total_ns = t1 - t0;

	(void)sink;
	printf("n=%d iters=%d warmup=%d find=%s hits=%d\n",
	       n, iters, warmup, find_last ? "last" : "miss", hits);
	printf("total_ns=%" PRIu64 "\n", total_ns);
	printf("ns_per_walk=%.3f\n", (double)total_ns / (double)iters);
	if (n > 0)
		printf("ns_per_node=%.3f\n",
		       (double)total_ns / (double)iters / (double)n);
	else
		printf("ns_per_node=n/a\n");

	free(adjs);
	free(uppers);
	free(root);
	return 0;
}

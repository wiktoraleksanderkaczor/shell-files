#!/usr/bin/env python3
"""Grid-search scoring weights for ranked history.

Reads two TSV datasets from stdin (separated by '---' marker):
  Dataset 1 — commands:      id, last_used_ts, total_count, is_fragment, cmd_length
  Dataset 2 — command_dirs:  cmd_id, dir, dir_count, last_used_in_dir_ts

Tunes 5 parameters: W_RECENCY, W_PWD, W_FREQ, SIBLING_FACTOR, DIR_DEPTH_DECAY.
Two-pass grid: coarse then fine neighborhood refinement.
Optimizes mean reciprocal rank (MRR) weighted by dir_count.

Outputs one pipe-delimited line to stdout:
  w_recency|w_pwd|w_freq|sib_factor|depth_decay|tuned_mrr|current_mrr|n_events

Progress bars go to stderr.
"""
import sys
import multiprocessing
from collections import defaultdict

multiprocessing.set_start_method("fork")

now = float(sys.argv[1])
frag_pen = float(sys.argv[2])
len_thresh = float(sys.argv[3])
cur_sf = float(sys.argv[4])
cur_dd = float(sys.argv[5])
cur_wr = float(sys.argv[6])
cur_wp = float(sys.argv[7])
cur_wf = float(sys.argv[8])

# --- Load data ---
cmds = {}
cmd_dirs = defaultdict(dict)
dir_cmds = defaultdict(dict)

phase = 1
for line in sys.stdin:
    line = line.rstrip("\n")
    if line == "---":
        phase = 2
        continue
    parts = line.split("\t")
    if phase == 1:
        cid = int(parts[0])
        cmds[cid] = (float(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]))
    else:
        cid, d, dc, ludts = int(parts[0]), parts[1], int(parts[2]), float(parts[3])
        cmd_dirs[cid][d] = (dc, ludts)
        dir_cmds[d][cid] = (dc, ludts)

n_cmds = len(cmds)
n_dirs = len(dir_cmds)
print(f"Loaded {n_cmds} commands across {n_dirs} directories", file=sys.stderr)

# --- Index commands by position ---
all_cmd_ids = list(cmds.keys())
cmd_idx = {cid: i for i, cid in enumerate(all_cmd_ids)}

rec = [0.0] * n_cmds
frq = [0.0] * n_cmds
pen = [0.0] * n_cmds

for cid, (luts, tc, frag, clen) in cmds.items():
    i = cmd_idx[cid]
    rec[i] = 1.0 / (1.0 + (now - luts) / 86400.0)
    frq[i] = min(tc, 100) / 100.0
    fp = frag_pen if frag else 1.0
    lp = 1.0 / (1.0 + max(clen - len_thresh, 0) / 200.0)
    pen[i] = fp * lp


def parent_of(d):
    p = d.rsplit("/", 1)[0]
    return p if p else "/"


def ancestors(d):
    result = [(d, 0)]
    cur = d
    while "/" in cur and cur != "/":
        cur = cur.rsplit("/", 1)[0]
        if not cur:
            cur = "/"
        result.append((cur, len(d) - len(cur)))
    return result


parent_children = defaultdict(set)
for d in dir_cmds:
    parent_children[parent_of(d)].add(d)

BAR_W = 20
def bar(pct):
    filled = pct * BAR_W // 100
    return "█" * filled + "░" * (BAR_W - filled)

# --- Precompute raw components per dir ---
# For each dir, store per command:
#   pwd_raw[i] = list of (recency, depth_diff) for matching ancestors
#   sib_raw[i] = best sibling recency score
# These are combined with trial depth_decay and sib_factor in compute_mrr.

# To keep it fast: precompute the best ancestor recency and its depth_diff,
# plus a second-best at different depth. But the scoring takes MAX over ancestors
# with depth_decay applied — so we need all ancestor hits, not just the best.
# Compromise: store (best_recency_at_exact_dir, [(recency, depth_diff), ...]) per cmd.
# Actually, most commands match 0-2 ancestors. Store all matches as a flat list.

# For speed: precompute per-dir two arrays:
#   dir_pwd_hits[d] = dict: cmd_idx -> [(recency, depth_diff), ...]
#   dir_sib[d] = array of best sib recency per cmd (length n_cmds)

dir_pwd_hits = {}  # d -> {idx: [(rec, depth_diff), ...]}
dir_sib = {}       # d -> [float] * n_cmds
events = []

print("Precomputing directory scores...", file=sys.stderr)
dirs_list = list(dir_cmds.keys())
for di, d in enumerate(dirs_list):
    if di % max(1, n_dirs // 40) == 0 or di == n_dirs - 1:
        pct = (di + 1) * 100 // n_dirs
        print(f"\r  [{bar(pct)}] {pct:3d}%  ({di+1}/{n_dirs})", end="", file=sys.stderr)

    ancs = ancestors(d)
    parent = parent_of(d)
    siblings = parent_children.get(parent, set())

    pwd_hits = {}
    sib_arr = [0.0] * n_cmds

    for cid in all_cmd_ids:
        idx = cmd_idx[cid]
        c_dirs = cmd_dirs.get(cid)
        if not c_dirs:
            continue

        # Ancestor hits for pwd_score
        hits = []
        for anc, depth_diff in ancs:
            entry = c_dirs.get(anc)
            if entry:
                r = 1.0 / (1.0 + (now - entry[1]) / 86400.0)
                hits.append((r, depth_diff))
        if hits:
            pwd_hits[idx] = hits

        # Best sibling recency
        best_sib = 0.0
        for sib in siblings:
            if sib != d:
                entry = c_dirs.get(sib)
                if entry:
                    s = 1.0 / (1.0 + (now - entry[1]) / 86400.0)
                    if s > best_sib:
                        best_sib = s
        sib_arr[idx] = best_sib

    dir_pwd_hits[d] = pwd_hits
    dir_sib[d] = sib_arr

    for cid, (dc, _) in dir_cmds[d].items():
        events.append((d, cmd_idx[cid], dc))

print(file=sys.stderr)

n_events = len(events)
total_weight = sum(w for _, _, w in events)


# --- MRR computation with 5 params ---
def compute_mrr(combo):
    wr, wp, wf, sf, dd = combo
    weighted_rr = 0.0
    score_cache = {}

    for d, target_idx, weight in events:
        scores = score_cache.get(d)
        if scores is None:
            hits = dir_pwd_hits[d]
            sib = dir_sib[d]
            scores = [0.0] * n_cmds
            for i in range(n_cmds):
                # pwd_score: max over ancestor hits with depth_decay
                ps = 0.0
                h = hits.get(i)
                if h:
                    for r, depth_diff in h:
                        s = r * (1.0 / (1.0 + depth_diff * dd))
                        if s > ps:
                            ps = s
                scores[i] = (wr * rec[i] + wp * (ps + sf * sib[i]) + wf * frq[i]) * pen[i]
            score_cache[d] = scores

        target_score = scores[target_idx]
        rank = 1 + sum(1 for s in scores if s > target_score)
        weighted_rr += weight / rank

    return (combo, weighted_rr / total_weight)


def run_grid(combos, pool):
    if not combos:
        return None, -1.0
    total = len(combos)
    best_mrr = -1.0
    best_combo = combos[0]
    done = 0
    for combo, mrr in pool.imap_unordered(compute_mrr, combos):
        done += 1
        if done % max(1, total // 40) == 0 or done == total:
            pct = done * 100 // total
            print(f"\r  [{bar(pct)}] {pct:3d}%  ({done}/{total})", end="", file=sys.stderr)
        if mrr > best_mrr:
            best_mrr = mrr
            best_combo = combo
    print(file=sys.stderr)
    return best_combo, best_mrr


# --- Pass 1: coarse 5D grid ---
# Weights: wr, wp, wf in [0.05, 0.70] step 0.10 (coarser to keep 5D tractable)
# sib_factor: [0.1, 0.5] step 0.1
# depth_decay: [0.02, 0.10] step 0.02
coarse = []
for wr_i in range(5, 75, 10):
    for wf_i in range(5, 75, 10):
        wp_i = 100 - wr_i - wf_i
        if wp_i >= 5:
            for sf_i in range(10, 55, 10):
                for dd_i in range(2, 12, 2):
                    coarse.append((wr_i/100, wp_i/100, wf_i/100, sf_i/100, dd_i/100))

n_workers = min(multiprocessing.cpu_count(), max(len(coarse), 1))
print(f"Pass 1: coarse 5D grid — {len(coarse)} combos × {n_events} events ({n_workers} workers)...", file=sys.stderr)
with multiprocessing.Pool(n_workers) as pool:
    coarse_best, coarse_mrr = run_grid(coarse, pool)

# --- Pass 2: fine grid around winner ---
wr0, wp0, wf0, sf0, dd0 = coarse_best
fine = []
for wr_i in range(max(1, int(wr0*100)-8), min(96, int(wr0*100)+9), 2):
    for wf_i in range(max(1, int(wf0*100)-8), min(96, int(wf0*100)+9), 2):
        wp_i = 100 - wr_i - wf_i
        if wp_i >= 1 and abs(wp_i - int(wp0*100)) <= 8:
            for sf_i in range(max(5, int(sf0*100)-10), min(80, int(sf0*100)+11), 5):
                for dd_i in range(max(1, int(dd0*100)-3), min(20, int(dd0*100)+4)):
                    fine.append((wr_i/100, wp_i/100, wf_i/100, sf_i/100, dd_i/100))

print(f"Pass 2: fine 5D grid — {len(fine)} combos × {n_events} events ({n_workers} workers)...", file=sys.stderr)
with multiprocessing.Pool(n_workers) as pool:
    fine_best, fine_mrr = run_grid(fine, pool)

if fine_mrr >= coarse_mrr:
    best_combo, best_mrr = fine_best, fine_mrr
else:
    best_combo, best_mrr = coarse_best, coarse_mrr

# Evaluate current weights
print("Evaluating current weights...", file=sys.stderr)
cur_mrr = compute_mrr((cur_wr, cur_wp, cur_wf, cur_sf, cur_dd))[1]

wr, wp, wf, sf, dd = best_combo
print(f"{wr:.2f}|{wp:.2f}|{wf:.2f}|{sf:.2f}|{dd:.2f}|{best_mrr:.4f}|{cur_mrr:.4f}|{n_events}")

#!/usr/bin/env python3
"""Parse SeekdbStartup timeline + app-launch markers from captured logcat.

Usage:
  parse_startup.py /tmp/seekdb_<sha>_launch1_logcat.txt [/tmp/..._launch2_logcat.txt ...]

For each file prints (markdown-friendly):
  - ActivityTaskManager Displayed (UI first frame offset)
  - observer.init / observer.start totals and stage costs
  - seekdb_open summary (pre_init / init / start_and_wait / total)
  - sms_* sub-stage lines (server storage-meta replay split; present only in
    engines built with the ob_storage_meta_replay_timeline marks)

Verification keys for the startup-accel fix (62ede0f4 / 5d82fa65):
  - warm observer.start total should drop ~1666ms -> ~962ms
  - the `config_got_version` stage (mislabels the accel-destroy window under
    mark-before-step semantics) should drop ~884ms -> ~10ms
  - the `log_pool_start` stage (mislabels the storage-meta replay window)
    should stay ~770-830ms -> split by sms_* rows

Follow-up drill-down groups (mb_* / lson_*):
  - mb_construct + mb_init + mb_start sum to ~sms_runtime_apply (~621ms);
    the dominant mb_* phase is where per-module marks go next
  - lson_* rows sum to ~sms_online_ls (~161ms, LS online chain)

Per-module / inner drill-down groups (ms_* / lsl_*):
  - ms_* rows decompose mb_start (obs_start_modules, ~500ms warm on device)
    into per-module start costs; find the dominant module(s)
  - lsl_* rows decompose lson_local_log (online_local_log_) into its
    append/replay inner steps
"""
import re
import sys

STAGE_RE = re.compile(r"\[STARTUP_TIMELINE\]\s*(\S+)\s+cost_us=(\d+)")
DONE_RE = re.compile(r"\[STARTUP_TIMELINE\]\s+(observer\.\w+|seekdb_open)\s+done total_us=(\d+) stages=(\d+)")
OPEN_RE = re.compile(r"seekdb_open pre_init_us=(\d+) observer_init_us=(\d+) start_and_wait_us=(\d+) total_us=(\d+)")
# "Displayed <pkg>/.MainActivity for user 0: +321ms" -- the "for user 0:" sits
# between the activity and the ": +Nms", so match the trailing "+Nms" instead.
DISPLAYED_RE = re.compile(r"ActivityTaskManager.*Displayed.*\+(\d+)ms")
# sample: 09-07 14:37:54.399 15795 21755 W SeekdbStartup: ...
LINE_RE = re.compile(r"SeekdbStartup:\s*(\[STARTUP_TIMELINE\].*)$")

KEY_STAGES = ["config_got_version", "log_pool_start", "wait_metadata_ready",
              "wait_server_runtime", "runtime_dep_services", "storage_meta_service_start"]


def parse_file(path):
    dumps = {}            # scope -> {total_us, stages:[(name,cost)]}
    sms = []              # [(name, cost_us)] storage-meta replay sub-steps
    mb = []               # [(name, cost_us)] module-tree rebuild phases
    lson = []             # [(name, cost_us)] LS online chain sub-steps
    ms = []               # [(name, cost_us)] per-module start (obs_start_modules)
    mls = []              # [(name, cost_us)] ObLogService::start inner steps
    lsl = []              # [(name, cost_us)] online_local_log_ inner steps
    seekdb_open = None
    displayed_ms = None
    for line in open(path, encoding="utf-8", errors="ignore"):
        if "Displayed" in line:
            m = DISPLAYED_RE.search(line)
            if m and displayed_ms is None:
                displayed_ms = int(m.group(1))
        if "SeekdbStartup" not in line:
            continue
        m = LINE_RE.search(line)
        if not m:
            continue
        body = m.group(1)
        d = DONE_RE.search(body)
        if d:
            scope = d.group(1)
            dumps[scope] = {"total_us": int(d.group(2)),
                            "stages": int(d.group(3)), "rows": []}
            continue
        o = OPEN_RE.search(body)
        if o:
            seekdb_open = [int(x) for x in o.groups()]
            continue
        s = STAGE_RE.search(body)
        if s:
            name, cost = s.group(1), int(s.group(2))
            # Engine header formats "sms_%-28s" while every call site also
            # passes a "sms_<step>" name, so the raw log is "sms_sms_<step>".
            # Normalize to "sms_<step>" so the note table below matches.
            if name.startswith("sms_sms_"):
                name = "sms_" + name[len("sms_sms_"):]
            if name.startswith("sms_"):
                sms.append((name, cost))
                continue
            if name.startswith("mb_"):
                mb.append((name, cost))
                continue
            if name.startswith("lson_"):
                lson.append((name, cost))
                continue
            if name.startswith("ms_"):
                ms.append((name, cost))
                continue
            if name.startswith("mls_"):
                mls.append((name, cost))
                continue
            if name.startswith("lsl_"):
                lsl.append((name, cost))
                continue
            for scope in dumps:
                if len(dumps[scope]["rows"]) < dumps[scope]["stages"]:
                    dumps[scope]["rows"].append((name, cost))
                    break
    return dumps, sms, mb, lson, ms, mls, lsl, seekdb_open, displayed_ms


def fmt_row(name, cost):
    return f"| {name:<26} | {cost:>9,} us | {cost/1000:>7.1f} ms |"


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    print("| # | file | Displayed | init total | start total | seekdb_open total |")
    print("|---|------|-----------|------------|-------------|-------------------|")
    for i, path in enumerate(argv, 1):
        dumps, sms, mb, lson, ms, mls, lsl, opn, disp = parse_file(path)
        init_t = dumps.get("observer.init", {}).get("total_us")
        start_t = dumps.get("observer.start", {}).get("total_us")
        opn_t = opn[3] if opn else None
        disp_s = f"{disp} ms" if disp is not None else "-"
        f = lambda x: (f"{x/1000:,.1f} ms" if x is not None else "-")
        print(f"| {i} | `{path.split('/')[-1]}` | {disp_s} | {f(init_t)} | {f(start_t)} | {f(opn_t)} |")
    print()
    for i, path in enumerate(argv, 1):
        dumps, sms, mb, lson, ms, mls, lsl, opn, disp = parse_file(path)
        print(f"### {path.split('/')[-1]}")
        for scope in ("observer.init", "observer.start"):
            d = dumps.get(scope)
            if not d:
                continue
            print(f"- {scope}: total {d['total_us']/1000:,.1f} ms ({d['stages']} stages)")
            if scope == "observer.start":
                order = KEY_STAGES + [n for n, _ in d["rows"] if n not in KEY_STAGES]
                seen = set()
                for n in order:
                    if n in seen:
                        continue
                    seen.add(n)
                    cost = dict(d["rows"]).get(n)
                    if cost is None:
                        continue
                    if cost > 100_000 or n in KEY_STAGES:
                        print("  " + fmt_row(n, cost).replace("| ", "- ", 1))
        if opn:
            print(f"- seekdb_open: pre_init={opn[0]/1000:.1f}ms init={opn[1]/1000:.1f}ms "
                  f"start_and_wait={opn[2]/1000:.1f}ms total={opn[3]/1000:.1f}ms")
        if sms:
            print("- storage-meta replay split (sms_*):")
            print("  | sub-step | cost | note |")
            print("  |---|---:|---|")
            # Each sms_* mark is emitted AFTER the step it brackets (see
            # ob_storage_meta_replay_timeline.h call sites), so the printed
            # cost is the segment that ran just before the mark.
            notes = {"sms_begin": "entry (0)", "sms_slogger_start": "server slogger start",
                     "sms_replay_all": "replayer done (bookend)",
                     "sms_read_ckpt": "read checkpoint", "sms_replay_slog": "slog replay",
                     "sms_slog_fast": "embed server slog fast path (no incremental replay)",
                     "sms_start_log": "slogger start_log",
                     "sms_ckpt_replay": "replayer tail (get_replay_result copy-out)",
                     "sms_runtime_apply": "apply replay result (create runtime)",
                     "sms_first_mark": "do_post_replay_work (first-mark window)",
                     "sms_ls_finish_gc": "finish_storage_meta_replay (LS finish+gc)",
                     "sms_online_ls": "online LS", "sms_ckpt_timer_start": "ckpt handler start"}
            for name, cost in sms:
                print(f"  | {name} | {cost:>9,} us | {notes.get(name,'')} |")
        if mb:
            print("- module-tree rebuild (mb_*): construct+init+start phases")
            mb_notes = {"mb_construct": "obs_construct_modules (alloc+bind ~60 modules)",
                        "mb_init": "obs_init_modules (~70 serial module inits)",
                        "mb_start": "obs_start_modules (~70 serial module starts)"}
            for name, cost in mb:
                print(f"  | {name} | {cost:>9,} us | {mb_notes.get(name, '')} |")
        if lson:
            print("- LS online chain (lson_*, within sms_online_ls window):")
            lson_notes = {"lson_tablet_svr": "ls_tablet_svr_.online",
                          "lson_lock_table": "lock_table_.online",
                          "lson_tx": "online_tx_", "lson_block_tx": "ls_tx_svr_.block_tx",
                          "lson_ddl_log": "ls_ddl_log_handler_.online",
                          "lson_log_handler": "log_handler_.online (clog base+ckpt scn)",
                          "lson_wrs": "ls_wrs_handler_.online",
                          "lson_compaction": "online_compaction_",
                          "lson_local_log": "online_local_log_ (append/replay mode)",
                          "lson_ckpt_gc_shell": "checkpoint/tabtlet_gc/empty_shell (best-effort)",
                          "lson_advance_epoch": "online_advance_epoch_",
                          "lson_running": "running_state_.online + update_state_seq_"}
            for name, cost in lson:
                print(f"  | {name} | {cost:>9,} us | {lson_notes.get(name, '')} |")
        if ms:
            print("- per-module start (ms_*, decomposes mb_start / obs_start_modules):")
            total = sum(c for _, c in ms)
            print(f"  sum {total/1000:.1f} ms across {len(ms)} modules")
            for name, cost in ms:
                mark = " <-- dominant" if cost > total / 3 else ""
                print(f"  | {name:<28} | {cost:>9,} us | {cost/1000:>7.1f} ms |{mark}")
        if mls:
            print("- ObLogService::start inner steps (mls_*, within ms_log_service):")
            mls_notes = {"mls_palf": "palf_env::start total (legacy; see mls_palf_reload/threads)",
                         "mls_palf_reload": "palf_env reload_palf_handle_impl_ (disk scan+load)",
                         "mls_palf_threads": "palf_env cb/io/shared_queue/log_loop thread start",
                         "mls_apply": "apply_service start",
                         "mls_replay": "replay_service start",
                         "lms_slog_fast": "embed local slog fast path (no incremental replay)"}
            for name, cost in mls:
                print(f"  | {name:<28} | {cost:>9,} us | {mls_notes.get(name, '')} |")
        if lsl:
            print("- online_local_log_ inner steps (lsl_*, within lson_local_log):")
            for name, cost in lsl:
                print(f"  | {name:<28} | {cost:>9,} us | {cost/1000:>7.1f} ms |")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

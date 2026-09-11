# SeekDB Android 首查路径冷启动时间线 — 真机测量（修复后复采）

- 日期：2026-09-07
- 设备：`2510DRK44C`（Redmi/annibale），Android 16（API 36），arm64-v8a
- 被测对象：`examples/todo-app` debug APK（Room on SeekDB，`SeekdbCompat.factory()`），全新安装后首启 + 温启 ×2
- 引擎：`libseekdb.so`，仓库 HEAD = `3ebbab1f4c53a3c774cd67ac0c29d0f964ffc59d`（`fix(embedded): surface STARTUP_TIMELINE on Android via logcat`）
- 引擎版本核验：S3 zip sha256 `fe19875d…` → APK 内 `.so` sha256 `213b19c9…` == zip 内 `.so` `213b19c9…`（旧版 `cf31a85a…`），`strings` 确认含 `[STARTUP_TIMELINE]` 与 `SeekdbStartup` tag 打印

## 结论速览

1. **修复生效：细粒度 stage 已可直采**。logcat 下 tag `SeekdbStartup` 每轮输出 35 行（`observer.init done` + 13 stage、`observer.start done` + 19 stage、`seekdb_open` 汇总），全部带 `cost_us`。此前因 `SuppressLogStdoutScope` 丢日志的问题已解决。
2. **`seekdb_open` 总耗时**（含 pre_init + observer.init + observer.start/wait）：
   - 首启（全新 store，一次性 bootstrap）：**~909 ms**（init 86 ms + start 821 ms）
   - 温启 ×2（已有 store）：**1 720 / 1 725 ms**（init ~51 ms + start ~1 667 ms）
   - 与修复前用 seekdb.log DBA 阶段日志重建的估计（首启 876 ms、温启 1 806/1 721 ms）误差 <5%，交叉验证了重建方法；但 stage 归属此前只能猜（"store 打开/redo 恢复"），现在可精确到具体阶段，见下。
3. **成本归属（直接测量）**：
   - 温启 start 的 1 667 ms 中，**98.8% 集中在三个阶段**：`config_got_version` ~884 ms（53%）→ `log_pool_start` ~623 ms（37%）→ `wait_metadata_ready` ~142 ms（9%）。
   - 首启 start 的 821 ms 中 **96.3% 是 `ob_service_start`**（790 ms，一次性 cluster bootstrap / create schema）。
   - 温启 init 的 ~51 ms 中 **~70% 是 `clients_open_need_init`**（35 ms，引擎各 client/service 初始化）。

## 端到端时序（进程启动后偏移，logcat 对齐）

| 事件 | 首启(全新 store) | 温启 #1 | 温启 #2 |
|---|---|---|---|
| App 进程启动 | 0 ms | 0 ms | 0 ms |
| MainActivity 首帧（Displayed）| +282 ms（TotalTime 300）| +204 ms（TotalTime 220）| +191 ms（TotalTime 212）|
| `observer.init` 完成（13 stage）| +349 ms | +245 ms | +238 ms |
| `observer.start` 完成 / `seekdb_open` 返回 | **+1 171 ms** | **+1 911 ms** | **+1 911 ms** |

UI 首帧不等待引擎；首条数据（LiveData 首次发射）要等 `seekdb_open` 返回 ≈ 温启进程启动后 1.9 s、首启 1.2 s。

## 细粒度 stage 明细（`cost_us`，自 `SeekdbStartup` logcat）

### observer.init — 13 stages（温启均值 ≈ 50 818 us；首启 85 601 us）

| stage | 首启 cost_us（占比）| 温启均值 cost_us（占比）| 备注 |
|---|---|---|---|
| clients_open_need_init | 49 031（57.3%）| 35 543（70.0%）| 各 client/service open，两场景最大单项 |
| init_storage | 18 338（21.4%）| 1 604（3.2%）| 首启含 schema 相关存储初始化 |
| schema_proxy_init | 9 583（11.2%）| 6 176（12.2%）| |
| network_services_chain | 4 778（5.6%）| 4 267（8.4%）| |
| retry_mds_global_pre | 2 209（2.6%）| 1 296（2.6%）| |
| sql_static_init | 419 | 911 | |
| kvcache | 658 | 571 | |
| 其余 7 stage（logger/io/tx/…）| <200 each | <180 each | init_config、init_schema ≈ 0–2 us |

### observer.start — 19 stages（温启均值 ≈ 1 669 081 us；首启 821 255 us）

| stage | 首启 cost_us（占比）| 温启均值 cost_us（占比）| 备注 |
|---|---|---|---|
| ob_service_start | **790 692（96.3%）**| 4（~0%）| 首启时承载一次性 cluster bootstrap |
| config_got_version | 39 | **883 948（53.0%）**| 温启第一大头 |
| log_pool_start | 304 | **622 951（37.3%）**| 温启第二大头（log/redo 恢复相关）|
| wait_metadata_ready | 0 | **141 954（8.5%）**| 温启第三大头 |
| local_mgmt_start_service | 16 049（2.0%）| 114 | |
| net_frame_start | 11 098（1.4%）| 43 | |
| runtime_dep_services / wait_server_runtime | 19 / 557 | 10 453 / 6 645 | |
| 其余 stage | <800 each | <1 800 each | timer、listener、io 等 |

**温启成本归属小结**：`config_got_version` + `log_pool_start` + `wait_metadata_ready` ≈ 1 649 ms，占温启 start 阶段 98.8%。与修复前 DBA 日志两处大块头（"8/14→9/14 开库+恢复" ~800 ms、"9/14→10/14 wait runtime" ~820 ms）总量吻合，现可定位到具体 stage；这几个 stage 内部在等什么（配置获取 / redo 恢复 / 元数据就绪的隐式等待）如需进一步优化，属引擎侧待查项。

## 修复前问题回顾（e0a886a 构建）

- 现象：`.so` 含 `[STARTUP_TIMELINE]` 字符串；logcat 与 seekdb.log 均不可见（文件只到 `observer start success`）。
- 根因：`seekdb.cpp` 的 `seekdb_open`（Android JNI 入口）把整个 `do_seekdb_open_inner`（含 `OBSERVER.init/start` 与全部 STARTUP_TIMELINE 打印）包在 `SuppressLogStdoutScope` 内 —— stdout/stderr 重定向到 `/dev/null`，FLOG_WARN console 输出被丢弃。DBA 级启动日志走文件不受影响。
- 修复（seekdb 仓，commit `3ebbab1f4c5`，已推送 `feat/embedded-mode`）：
  - `src/observer/ob_server.cpp`：`startup_timeline_dump` 增加 `#ifdef __ANDROID__` 分支，逐行 `__android_log_print(ANDROID_LOG_WARN, "SeekdbStartup", ...)`。
  - `src/include/seekdb.cpp`：`seekdb_open` 汇总同样镜像到 logcat。
  - 桌面/服务端保持原 FLOG_WARN 不变；oblib CMake 在 Android 下已链 `-llog`。

## 原始数据文件（/tmp）

- 修复后复采（本次）：`/tmp/seekdb_3eb_launch1_logcat.txt`（首启）、`/tmp/seekdb_3eb_launch2_logcat.txt` / `seekdb_3eb_launch3_logcat.txt`（温启 #1/#2）
- 修复前（e0a886a）：`/tmp/seekdb_engine.log` / `seekdb_engine_warm.log` / `seekdb_engine_warm2.log`、`/tmp/seekdb_todo_logcat.txt` / `seekdb_warm2_logcat.txt`
- 引擎 zip：`/tmp/3ebbab1f4c5-libseekdb.zip`、`/tmp/e0a886a-libseekdb.zip`

## 引擎侧下钻（同日补记）：stage 标签归属更正 + 温启两大块根因

> 本节对上面"成本归属小结"做**更正**。上方表格的 stage 数值（884/623/142 ms）本身没错，但
> `startup_timeline_mark` 的记账语义是：每次 mark 记的是"距上一次 mark 的耗时"，而 mark 位于其
> 命名的步骤**之前**——因此每个 stage 名称下记的其实是对应 mark **前一段**代码的耗时，标签整体
> 与真实代码段错位。用 DBA 14 步日志时间戳（device seekdb.log，pid 21755/22038）逐段锚定后，
> 真实归属如下（误差到 µs 级，锚点：entry1–13 求和 = 6/14→9/14 窗口 622.58 ms，精确吻合）。

温启 observer.start（≈1 666 ms）的真实代码段耗时：

| 真实代码段（按执行序） | 耗时 | 对应错误标签 | DBA 锚点佐证 |
|---|---|---|---|
| `SERVER_STORAGE_META_SERVICE.start()`（server slog 回放：`replayer_.start_replay()` → finish slog replay → online LS，logcat/文件可见 "enable replay clog"）| **≈620 ms** | 打印为 `log_pool_start` | 6/14→9/14 窗口 622 ms（9/14 = instance start success）|
| `startup_accel_handler_.destroy()`（join startup accel 池 worker）| **≈889 ms** | 打印为 `config_got_version` | 9/14→10/14 空窗 885 ms（10/14 在 `wait_for_server_runtime` 内）；`mark("config_got_version")` 位于 destroy 之后 |
| `local_management_service_.start_runtime_dependent_services()` | **≈136 ms** | 打印为 `wait_metadata_ready` | 11/14→12/14 间隔 136 ms（12/14 在 `check_if_schema_ready` 内，经 standby `wait_metadata_ready`→host 回调链）|
| 其余（got_version ≈7 ms、log_block_mgr.start ≈1 µs、wait_for_server_runtime ≈10 ms、schema/timezone、net_frame…）| ≈30 ms | — | — |

**根因①（889 ms，纯浪费，已修复）**：`startup_accel_handler_.destroy()` → `ObSimpleThreadPoolBase::destroy()`
置 `stop_` 后 join worker，但**没有唤醒**阻塞在队列 `pop(QUEUE_WAIT_TIME=1 s)` 上的空闲 worker
（`Threads::stop()` 只置位、不唤醒队列）。tablet 回放任务（`ObTabletReplayCreateTask`）由
`concurrent_replay()` 同步等待全部执行完（`inflight_task_cnt_` 在任务执行完才递减），故 destroy 时
队列已空——889 ms 是 worker 空等队列超时的纯闲置。修复：destroy() 中补 `notify_stop()`（即
`queue_.wake_all()`），空闲 worker 立即感知 `stop_` 退出（在途任务仍会被 join 等完）。
改动：seekdb 仓 `src/oblib/lib/thread/ob_simple_thread_pool.ipp`。

**根因②（620 ms，真实回放）**：server slog 回放（server 级 storage meta slog）占 instance-start 主体。
此为真实恢复工作，需进一步拆分（slog 体量/IO/串行度）才能定向优化，属后续待查项。

**下一步建议**：触发 Build libseekdb CI → 真机复采温启（`config_got_version` 标签应从 889 ms 掉到 ~10 ms
级，总 start 应 ≈780 ms）；随后下钻 620 ms slog 回放；并考虑把 timeline 记账改成"延迟命名"使标签
与代码段对齐。

---

## 5d82fa6 终验（2026-09-07 晚间）：修复确认 + sms_* 子步归属更正

- CI：`github.com/oceanbase/seekdb/actions/runs/34107354136`（workflow_dispatch，`feat/embedded-mode`
  @ `5d82fa6538c`，Build libseekdb）**success**；S3 zip 可访问，与本地复采使用的 zip 一致。
- 被测引擎：`5d82fa6538c`（`fix(oblib): make ObLightyQueue::wake_all abort in-flight timed pops`，
  含前一 commit `ebd95681383` 的 sms_* 子步标记）。注意 **`62ede0f4eb9`（第一次修复尝试）无效**——
  它只在 destroy() 里补 `notify_stop()`，但 `wake_all()` 只 poke futex，`pop(timeout)` 仍睡到绝对
  超时（5d82fa6 的 commit message 自述"the 62ede0f4 notify_stop() wake was a no-op"）。实测佐证见下。
- 复采：`/tmp/seekdb_5d82fa6_launch{1,2,3}_logcat.txt`（launch1 全新 store / launch2/3 温启），
  Displayed 用 am `-W` TotalTime（417/321/306 ms）。

### 修复效果（温启 start 逐 commit 演进，config_got_version 标签=accel destroy 空窗）

| 引擎 commit | 温启 observer.start | config_got_version | 结论 |
|---|---|---|---|
| `3ebbab1f`（修复前）| ~1 666 ms | ~884 ms | 基线 |
| `62ede0f4`（第一次修复尝试）| ~1 786 ms（1 810/1 761）| **~837/816 ms（仍在）** | **未生效**：wake 是 no-op |
| `5d82fa65`（本次，wake_all 真正 abort）| **~962 ms（928/996）** | **~0.3/0.2 ms** | **修复确认**：889 ms 空窗消失 |

> 即上一节"根因①已修复（62ede0f4）"的表述需修正：真正生效的是 `5d82fa65`。
> 修复后温启 start ≈ 962 ms，比预期 ~780 ms 多 ~180 ms——差异来自 storage-meta replay 窗口实测
> 更大（~770–830 ms 而非此前按 DBA 锚点估的 ~620 ms），sms_* 子步已直接拆出，见下。

### sms_* 子步归属（源码位置 + 实测，mark 位于步骤之后 → 打印的是该步耗时）

三个调用文件（引擎仓）：

- `src/storage/meta_store/ob_server_storage_meta_service.cpp` `start()`（L75/81/86/91）：
  `sms_begin` → slogger start → `sms_slogger_start`；`replayer_.start_replay()` → `sms_replay_all`；
  `ckpt_slog_handler_.start()` → `sms_ckpt_timer_start`。
- `src/storage/meta_store/ob_server_storage_meta_replayer.cpp` `start_replay()`（L63/68/73/78/83）：
  `sms_ckpt_replay`（get_replay_result 拷贝）→ `apply_replay_result_()` → `sms_runtime_apply` →
  `do_post_replay_work()` → `sms_first_mark` → `finish_storage_meta_replay_()` → `sms_ls_finish_gc` →
  `online_ls_()` → `sms_online_ls`。
- `src/storage/slog_ckpt/ob_server_checkpoint_slog_handler.cpp` `start_replay()`（L114/119/124）：
  `sms_read_ckpt` → `replay_server_slog()` → `sms_replay_slog` → `server_slogger_->start_log()` →
  `sms_start_log`。

温启均值（launch2/launch3，ms；全窗口 ≈ log_pool_start 标签 ~770–830 ms）：

| sms 子步 | 耗时 | 真实代码段 |
|---|---:|---|
| sms_runtime_apply | **~621（587/656）** | `apply_replay_result_` → `create_runtime` → `ObServerRuntime::init`→`create_modules` |
| sms_online_ls | **~161（165/158）** | `online_ls_`（LS online）|
| sms_replay_slog | **~19（18.6/18.7）** | `replay_server_slog`（**真正的 slog 回放**）|
| 其余（slogger start/read_ckpt/start_log/…）| ~0.3 | — |

**更正上一节"根因② ≈620 ms 真实 slog 回放"**：slog 记录回放本身只有 **~19 ms**。storage-meta
replay 窗口主体是 `apply_replay_result_`（重建 server runtime 模块树，~620 ms）与 `online_ls_`
（~160 ms）——两者都是把**上一进程持久化下的 runtime/LS 状态在内存里重建**，属下一步优化靶点
（可拆 create_modules 各子模块 / online_ls 内部，方向是"少建、延迟建、或与首帧并行"），不再是
"slog 回放"。

### 备注（解析/工具侧）

- 引擎 timeline header 用 `"sms_%-28s"` 格式串且各调用点也传 `"sms_xxx"`，日志实为
  `sms_sms_begin`（双前缀）。纯命名冗余，cost 不受影响；`parse_startup.py` 已做归一化，
  后续可在引擎侧随手清理（header 去掉 `sms_` 前缀）。
- `parse_startup.py` 的 Displayed 正则已适配 `for user 0:` 行格式（本次起可解析）。

---

## mb_*/lson_* 打点（提交于 2026-09-07 晚，commit `6086f6ac7bb`，已复采见下节）

> 本节为当时（2026-09-07 晚）"已提交但未复采"的 instrumentation 说明，现已成为历史：
> `6086f6ac7bb` 已构建并完成真机 + 模拟器复采（见下节）。目标是把上一节两个大窗口继续拆开：
> - `sms_runtime_apply` ~621 ms → `mb_construct` / `mb_init` / `mb_start`（模块树 construct /
>   init / start 三段）
> - `sms_online_ls` ~161 ms → `lson_*`（`ObLS::online_without_lock_` 逐子步）

### 改动文件（seekdb 仓）

1. `src/storage/meta_store/ob_storage_meta_replay_timeline.h`：重构为单一共享 delta 链
   `ob_startup_substep_mark()`（inline 函数内 static，ODR 保证所有 TU 共链），原有
   `storage_meta_replay_timeline_mark`（sms_*）与新 `startup_substep_timeline_mark`（通用）
   都走这条链——因此新 mark 的 cost 与 sms_* 窗口**直接对齐**（无需绝对时间戳对齐）。
2. `src/observer/omt/ob_server_runtime.cpp` `create_modules()`：三段各成功结束后打
   `mb_construct` / `mb_init` / `mb_start`（mark 在步骤后 → cost 即该段耗时；错误处理语义不变，
   errsim/init/start 失败路径与原来一致）。
3. `src/storage/ls/ob_ls.cpp` `online_without_lock_()`：原 else-if 链改写为顺序守卫步
   （`if (OB_SUCC(ret) && OB_FAIL(...)) {} else if (OB_SUCC(ret)) { mark; }`，语义等价），
   每子步后打 `lson_tablet_svr` / `lson_lock_table` / `lson_tx` / `lson_block_tx` /
   `lson_ddl_log` / `lson_log_handler`（clog handler online，最可能的 LS 级恢复大头）/
   `lson_wrs` / `lson_compaction` / `lson_local_log` / `lson_ckpt_gc_shell`（原 FALSE_IT
   三连，best-effort）/ `lson_advance_epoch` / `lson_running`。

### 解析

`parse_startup.py` 已扩展：新前缀 `mb_` / `lson_` 按组输出（与 sms_ 并列），旧日志
（无新前缀）解析不受影响（已用 `/tmp/seekdb_5d82fa6_launch2_logcat.txt` 回归验证）。

### 复采验收标准

- 温启 observer.start 应仍 ≈ 930–960 ms（本批只是加打点，不改行为）。
- `mb_construct + mb_init + mb_start` ≈ `sms_runtime_apply`（~587–621 ms）；
  三个里最大的那个即为下一轮 per-module 打点/优化入口。
- `lson_*` 求和 ≈ `sms_online_ls`（~162–165 ms）；若 `lson_log_handler` 偏大，
  说明 LS 级 clog handler online（起恢复/回放）是大头，需再下钻其内部。
- 引擎侧 timeline header 的 `sms_sms_` 双前缀未动（保持日志格式与 parse 归一化兼容）；
  若本批顺手清理，需同步 `parse_startup.py` 的归一化分支。


---

## 32ee789 下钻准备（2026-09-08 午间，静态核对 + 预判，待复采）

CI `34187120138` 构建中（12:28 触发，~1.5-2h）。复采前在引擎源码侧做的核对与预判：

### 记账核对（代码路径，mark 均在步骤后 → cost = 该步）

- `ob_server_runtime.cpp create_modules()`：`mb_init` 在 `obs_init_modules()` 后、`mb_start` 在
  `obs_start_modules()` 后；`ms_*`（32 个）在 `obs_start_modules()` 每模块 start 成功后。
  ⇒ **ms_* 合计 ≈ mb_start（~540 ms）**；`ms_shared_timer`（首个）cost 含 obs_start_modules
  入口缝隙，其余即为各自模块 start。
- `ob_ls.cpp online_local_log_()` REPLAY 分支两句的底层实现已核对：
  - `log_handler_.set_local_append_enabled(false)` = 原子 store（ob_log_handler.h）→ `lsl_set_append_disabled` 预期 ~0；
  - `local_log_handler_set_.deactivate()` = spinlock + 遍历 handler 逐个 `deactivate()`
    （ob_local_log_handler_set.cpp），每个 handler 的 deactivate 各模块各异（部分 TODO/no-op）。
  ⇒ **若 `lsl_deactivate` 大 → 下一轮在 deactivate() 内逐 handler 打点；若两者都小 → ~150 ms
  属调用缝隙/调度噪声，需复核 lson_local_log 区间口径。**

### 静态预判（待 ms_* 证实，勿当结论）

- `obs_init_modules`（32 模块 init）合计仅 ~7 ms，而 `obs_start_modules`（32 个 start）合计
  ~538 ms——这种不对称指向**单个/少数模块 start 内做重活**（线程池/同步等待/IO），而非均摊开销。
- 结构性最可疑（按启动实体数/代码量）：`log_service`（palf_env start + apply/replay service）、
  `io_service`（callback_mgr 起线程池）、`change_stream_mgr`（fetcher/dispatcher/worker）、
  `tmp_file_manager`（sn_file_manager.start）、`check_point_service`（4 timer + freeze 线程）。
  已目检的其余 start 均为 ObTimer init+schedule（各建 1 线程），单模块应 <1 ms。
- 复采环境：模拟器 `Medium_Phone_API_36.1` 在线（结构预验用）；**真机 `2510DRK44C` 未连接**，
  权威数值待设备接回后补采。`parse_startup.py` 已支持 `ms_*`/`lsl_*` 分组与 dominant 标注。

---

## 32ee789 复采（2026-09-08 下午）：ms_* + lsl_* 真机验收 — 三大头钉死

- CI：`github.com/oceanbase/seekdb/actions/runs/34187120138`（workflow_dispatch，`feat/embedded-mode`
  @ `32ee789be66`，Build libseekdb）**success**；S3 zip sha256 `85a938ba…`（APK 内 `.so` `8e97f4ac…` 同值）。
  （上一批 `6086f6a` CI `34125929444` 亦 success，见 mb_*/lson_* 节。）
- 环境：真机 `2510DRK44C`（Android 16 / API 36, arm64-v8a）；`gradle.properties`
  `LIBSEEKDB_URL_PREFIX` 已 bump 至 `32ee789` 前缀。
- 原始数据：`/tmp/seekdb_32ee789_launch{1,2,3}_logcat.txt`（launch1 全新 store / launch2/3 温启）。

### 端到端（温启 launch2/3）

| launch | Displayed | observer.start | seekdb_open |
|---|---:|---:|---:|
| #2 温启 | 323 ms | **884 ms** | 1 024 ms |
| #3 温启 | 282 ms | **869 ms** | 926 ms |

与 `6086f6a` 温启（observer.start 899/956 ms）同量级，纯打点未改行为。

### 温启大头分解（launch2/3 均值）

| 窗口（6086f6a 标签） | 32ee789 实测 | 归属（源码） |
|---|---:|---|
| `mb_start` ~538 ms | **ms_* 合计 ~563 ms** | `obs_start_modules()` 32 模块串行 start |
| ↳ 模块 #1 | **ms_log_service ~438 ms（77%）** | `ObLogService::start()` → `palf_env_->start()` + apply/replay service start |
| ↳ 模块 #2 | **ms_local_storage_meta_service ~123 ms（22%）** | `ObLocalStorageMetaService::start()` → slogger + ckpt + `replayer_.start_replay()` |
| `lson_local_log` ~151 ms | **lsl_append_start ~101 ms** | `online_local_log_()` **APPEND 分支** `start_local_log_()`（温启非 recovery → append 模式） |
| `sms_runtime_apply` ~621 ms | **~0.1 ms**（记账转移） | 真实耗时已拆入 `mb_*`/`ms_*`；`sms_runtime_apply` 标签现只记 mark 后缝隙 |

**记账闭合**：`mb_construct(~5 ms) + mb_init(~9 ms) + ms_* 合计(~563 ms) ≈ log_pool_start 窗口(~708 ms)` 扣除 slog 回放等小段后吻合；温启 timeline 行数增至 ~94 行（+32 ms_* +1 lsl_*），无崩溃。

### lsl_* 结论（更正 REPLAY 假设）

温启走 **APPEND 模式**（`boot_append_mode_ = !recovery_mode`），`online_local_log_()` 只打
`lsl_append_start`（`start_local_log_()` 后），**未出现** `lsl_set_append_disabled` /
`lsl_deactivate`（REPLAY 分支）。6086f6a 记的 `lson_local_log` ~151 ms 实际落在
`start_local_log_()`，非 deactivate 循环。

### 下一轮优化靶点（按收益排序）

1. **`ms_log_service` ~438 ms** — 下钻 `ObLogService::start()` 三段（palf_env / apply / replay），
   方向：懒启动线程池、合并 start、或与首查并行。
2. **`ms_local_storage_meta_service` ~123 ms** — 下钻 `replayer_.start_replay()`（温启 slog 回放 ~20–29 ms
   之外仍有 ~90 ms 在 local meta service start 链），方向：延迟 local meta replay、与 server meta 去重。
3. **`lsl_append_start` ~101 ms** — 下钻 `start_local_log_()`（APPEND 温启路径），方向：推迟到首写前、
   或轻量化 local log handler 激活。

### 备注

- 首启 launch1：`ob_service_start` ~822 ms 仍占 start 96%+（一次性 bootstrap，与温启无关）。
- `parse_startup.py` ms_* 组已附合计与 dominant 标注；`sms_runtime_apply` 在 ms_* 存在后仅作闭包检查。

---

## abb19e 挂起复盘 + 79fc4c 真机验收（2026-09-08 晚）

### 提交与数据

| 提交 | 说明 | 真机温启 seekdb_open |
|------|------|---------------------:|
| `32ee789` | ms_* / lsl_* 打点基线 | **926–1,024 ms** |
| `abb19e0` | Phase 1–4 全量优化 | ❌ 挂起（无 `seekdb_open`） |
| `79fc4c7` | 回滚 Phase 2 + 危险 Phase 3；保留 Phase 1/4 + 512 桶 | **997–1,142 ms**（≈基线，略慢） |

原始 log：`/tmp/seekdb_79fc4c7_launch{1,2,3}_logcat.txt`（真机 `2510DRK44C`）；abb19e 对照
`/tmp/seekdb_abb19e0_launch{2,3}_logcat.txt`。

### abb19e 挂起位置（按 launch 类型）

| 场景 | 最后 timeline 标记 | 推断阻塞点 |
|------|-------------------|------------|
| Bootstrap launch1 | `lson_running` | `post_create_ls_()` → `set_start_work_state()` 或之后 |
| 温启 launch2/3 | `sms_sms_ckpt_timer_start` | `SERVER_STORAGE_META_SERVICE.start()` 返回后 → `log_pool_start` / `initialize_server_runtime` 链 |

与 CI 一致：darwin/windows `smoke-vsag.js` 在 `seekdb_open` 挂起 >300s。

### 子项效果（温启 launch2，真机）

| 子项 | 32ee789 | abb19e（挂起前） | 79fc4c | 结论 |
|------|--------:|-----------------:|-------:|------|
| `ms_local_storage_meta_service` | 103 ms | **38 ms** | 108 ms | 快路径有效但未兑现（已回滚） |
| `lsl_append_start` | 101 ms | **0.5 ms** | 156 ms | Phase 1 未兑现，79fc4c 更慢 |
| `mls_palf` | ~455 ms* | 204 ms† | 502 ms | deferred 扭曲计时；79fc4c ≈基线 |
| `wait_metadata_ready` | ~141 ms | — | ~145 ms | Phase 4 无感 |

\* 32ee789 无 `mls_*` 标签，取 `ms_log_service` 合计。† abb19e 未跑完 `log_loop`，不可与终态对比。

**结论**：当前 79fc4c 的价值是**修复挂起**；端到端温启**未加速**。有潜力的改动在 abb19e 的 **Phase 2/3 激进路径**，需拆分、二分、加守卫后重试。

---

## 可安全重试的 Phase 2/3 方案（下一轮实现清单）

原则：**一次只动一个变量**；每步 CI（含 darwin smoke）+ 真机 `remeasure.sh` 温启 #2/#3；必须出现完整 `seekdb_open` 汇总行方可合并。

### Phase 2-R1：只 defer `block_gc_timer`，保留 `log_loop_thread`（低风险）

**动机**：abb19e 将 `block_gc_timer_` 与 `log_loop_thread_` **一并**推迟到 `SS_SERVING` 之后。
`log_loop` 负责 `check_and_switch_state` / `period_freeze_last_log`（见 `log_loop_thread.cpp`），
温启 `post_create_ls_` 与 `initialize_server_runtime` 可能隐式依赖其进度；`block_gc` 仅为周期回收，可晚启。

**改动**（`palf_env_impl.cpp`，仅 `#ifdef OB_BUILD_EMBED_MODE`）：

```text
PalfEnvImpl::start():
  reload_palf_handle_impl + cb/io/shared_queue 不变
  + log_loop_thread_.start()          // 立即
  is_running_ = true
  // block_gc_timer_task_.start() 不在这里调

start_embed_deferred_block_gc():     // 新函数，名字区别于旧 start_embed_background_threads
  仅在 block_gc 未启动时 schedule/start
```

**启动时机**（二选一，推荐 A）：

- **A（推荐）**：`ObLogService::start()` 返回后、仍在 `obs_start_modules` 的 `ms_log_service` 窗口内，
  由 `ObLogService` 调 `start_embed_deferred_block_gc()` —— 早于 `online_ls` / `log_pool_start`。
- **B**：`log_block_mgr_.start()` 之后、`initialize_server_runtime()` 之前（`ob_server.cpp` 打
  `log_pool_start` mark 之后）—— 若 A 仍挂起再试。

**不要**：在 `GCTX.status_ = SS_SERVING` 之后才启动任何 palf 后台线程（abb19e 做法）。

**预期收益**：小于 abb19e 全 defer（`mls_palf` 仍含 `log_loop` 成本），主要省 block GC 定时器初始化；
需实测，可能仅数 ms～数十 ms。

**验收**：darwin smoke + 真机温启 seekdb_open < 1.2s 且三次均闭合。

---

### Phase 2-R2：`mls_palf` 内部分解打点（无行为变更）

在 `reload_palf_handle_impl_()` 内增加 `mls_palf_reload` / `mls_palf_threads` 等 2–3 个
`startup_substep_timeline_mark`，把当前 ~500 ms 桶拆开，**指导后续是否值得优化 reload 本身**
（与 defer 无关的结构性优化）。

---

### Phase 3-R1：local slog 快路径 — 加严守卫（中风险，单独 PR）

**动机**：abb19e 在 `active_cursor == start_point` 时 `return`，跳过 `replayer.replay()` +
`ObTabletReplayCreateHandler.concurrent_replay()` + `replayer.replay_over()`，温启
`ms_local_storage` 38 ms vs 103 ms，但导致挂起。

**安全条件**（全部满足才 skip redo replay）：

1. `OB_BUILD_EMBED_MODE` && 温启（`!recovery_mode` 或 runtime 已 `CREATED`）。
2. `start_point.is_valid() && active_cursor.is_valid() && start_point.equal(active_cursor)`。
3. **新增**：`start_point.file_id_ == active_cursor.file_id_` 且 `log_id_` 相等（防 `equal()` 语义过宽）。
4. **新增**：checkpoint 回放已成功（`replay_checkpoint` 返回 OK）且 `replay_tablet_disk_addr_map_` 在
   slog 段之前已处理完（map 仅来自 ckpt/snapshot，无未决 slog 条目）。
5. **仍执行**：`slogger_->start_log(replay_finish_point)`；**显式调用** `replay_over()` 等价逻辑
   （若 `ObStorageLogReplayer::replay_over` 有副作用则必须调用空 replay 的 `replay_over`）。
6. **禁止**：在 `snapshot_cnt > 0` 且 snapshot replay 刚完成的同一轮里走快路径（先测 snapshot 路径）。

**实现策略**：先加条件 (1)(2)(3) + 保留完整 `replay_over` / tablet handler 空操作路径；
真机通过后再加 (4)(5) 收紧。

**回滚开关**：`GCONF` 或 compile-time `EMBED_LOCAL_SLOG_FAST_PATH` 默认 **off**，真机验证后默认 on。

**预期收益**：温启 `ms_local_storage_meta_service` 向 abb19e 的 ~40 ms 靠拢（目标 **< 60 ms**）。

---

### Phase 3-R2：embed ckpt timer 推迟（低风险，可与 3-R1 分开）

**动机**：abb19e 在 embed 下 `ObLocalStorageCheckpointSlogHandler::start()` 不 schedule
`write_ckpt_timer_`，改在 `SS_SERVING` 后 `start_embed_deferred_background()`。

`ObWriteCheckpointTask` 已检查 `SERVER_STORAGE_META_SERVICE.is_started()`，与 slog 回放不冲突。

**安全做法**：

- 仅推迟 **local** `write_ckpt_timer_`（`ob_local_storage_checkpoint_slog_handler.cpp`）。
- **server** 侧 `ObServerCheckpointSlogHandler::task_timer_` 保持原样（init 时 schedule）。
- 推迟启动点：**`SERVER_STORAGE_META_SERVICE.start()` 返回后**（`sms_ckpt_timer_start` 之后），
  而非 `SS_SERVING` 之后 —— 避免 abb19e 与 Phase 2 叠加时的长窗口。

**预期收益**：数 ms；主要减少 embed 温启 timer 线程竞争，非大头。

---

### Phase 1 / Phase 4 处置建议

| Phase | 建议 | 理由 |
|-------|------|------|
| **Phase 1** 自适应轮询 | **回滚 embed 改动**，恢复 `ob_usleep(50ms)` / `1ms` 固定值 | 真机 `lsl_append_start` 101→156 ms |
| **Phase 4** schema/timezone | **保留代码，降低优先级** | `wait_metadata_ready` ~140 ms 无变化；首启可能略有收益 |

保留无争议项：**512 桶** `replay_tablet_disk_addr_map_`、`snapshot_cnt==0` 跳过 `replay_snapshot`。

---

### 推荐落地顺序（二分）

```text
Step 0  79fc4c 基线已确认（本节后文）
Step 1  回滚 Phase 1 embed 轮询 → 真机复采（目标 lsl ≤ 110 ms）
Step 2  Phase 2-R1（仅 defer block_gc）+ 启动点 A → CI + 真机
Step 3  Phase 3-R2（ckpt timer 推迟到 sms 之后）→ CI + 真机
Step 4  Phase 3-R1（快路径 off-by-default → on）→ CI + 真机
Step 5  若 Step 2–4 均稳定，再评估 Phase 2-R2 下钻后的 reload 优化
```

每步合并前对比表：

| 指标 | 目标 |
|------|------|
| `seekdb_open` 温启 | ≤ 32ee789 + 50 ms（约 **1,050 ms**） |
| `ms_local_storage_meta_service` | Step 4 后 **< 60 ms** |
| `lsl_append_start` | Step 1 后 **≤ 110 ms** |
| 挂起 | 三次 launch 均有 `observer.start done` |

### 复采命令（固定）

```bash
export ANDROID_SERIAL=98305968
bash docs/seekdb-android/measure/remeasure.sh \
  <full_sha> fresh /path/to/libseekdb-android-arm64-v8a.zip
python3 docs/seekdb-android/measure/parse_startup.py \
  /tmp/seekdb_<short>_launch{1,2,3}_logcat.txt
```

CI：`gh workflow run build-libseekdb.yml -f ref=<full_sha>` → `gh run download <run> -n libseekdb-android-arm64-v8a`.

---

## 7434440 vs ccfc8d39 交叉 A/B（2026-09-11）：revert 未恢复基线，温启慢 ~170 ms

### 动机与被测对象

`68bb2c5`（slog 快路径）→ `7434440`（增量 PALF tail scan）后温启一度落到 **~800 ms**；
`a302cc4887f`（periodic warm manifest timer + 收紧 replay wait）引入 **3 s 定时器导致复采空窗期
slog replay storm**，`ccfc8d39` 回滚该定时器并回滚 "disabled replay 视为 done" 的跳过 drain 缺陷，
同时保留 single-pass 增量 tail load。本轮 A/B 要回答：**回滚后能否回到 7434440 的温启水平**。

| 项 | 7434440（pre-regression 参考） | ccfc8d39（revert 候选） |
|---|---|---|
| CI artifact | run `34551030955` | run `34568307509` |
| APK 内 `.so` sha256 前缀 | `120e97ee8fa91bb8…` | `0cb250d71177a41c…` |
| 两者净 diff | — | 仅 3 文件：`log_storage.h`(43 行)、`ob_ls.cpp`(9 行)、`palf_env_impl.h`(注释 1 行) |

> `log_storage.h`：7434440 先用 `has_embed_warm_snapshot_new_data_()` 门控，无新数据时走
> `apply_embed_warm_snapshot_()` 纯 apply；ccfc8d39 去掉门控，**无条件**走
> `locate_log_tail_incremental_from_warm_snapshot_()`。
> `ob_ls.cpp`：`replay_wait_sleep_us` 1000→500、`embed_replay_busy_spin_rounds` 2000→8000，
> 并在 `is_submit_task_clear` 循环前补一次前置检查。

### 方法（交叉 A/B，抹掉次序偏差）

`/tmp/ab_cross.sh`（首批 ab01–ab04）+ `/tmp/ab_cross2.sh`（第二批 ab05–ab10，带起始序号以免覆盖
首批产物）：交替跑 7434440 / ccfc8d39，**每轮跑前 `run-as <pkg> rm -rf databases files shared_prefs`
清空 store**，每次 `FLAVOR=baseline remeasure.sh <sha> keep <zip>`，共 5 轮 = 10 次 remeasure
= 30 次 launch。原始产物 `/tmp/abNN_<short>_{run,launch1..3_logcat}.txt`，日志 `/tmp/ab_cross_log{,2}.txt`。

### 结果：温启（launch2/3，n=10）

| 指标 | 7434440 | ccfc8d39 | Δ |
|------|--------:|---------:|---:|
| `seekdb_open` 均值 / 中位 | **802.8 / 799.8** | **973.0 / 941.5** | **+170 ms** |
| `seekdb_open` 区间 | 681.2–938.8（sd 103.3） | 856.5–1119.0（sd 97.5） | 两分布几乎不重叠 |
| `observer.start` | 747.2 | 903.0 | +156 ms |
| `observer.init` | 52.4 | 67.0 | +15 ms |
| `log_pool_start` 标签（=`SERVER_STORAGE_META_SERVICE.start()` 窗口） | **595.7**（482.7–722.3，sd 100.1） | **751.4**（685.8–858.5，sd 63.3） | **+156 ms** |
| `wait_metadata_ready` | 136.2 | 136.0 | 0 |
| `sms_replay_slog`（真实回放） | 36.4 | 51.0 | +15 ms |
| `lsl_append_start` | 124.5 | 122.6 | −2 ms |
| `ms_local_storage_meta_service` | 128.6 | 128.9 | 0 |

原始 `seekdb_open` 排序值：

```text
7434440 : 681.2 699.4 708.1 708.1 747.8 851.7 868.7 895.3 928.5 938.8
ccfc8d39: 856.5 884.3 888.4 894.9 938.9 944.1 1057.3 1060.0 1086.8 1119.0
```

**结论：回滚没有恢复基线**，ccfc8d39 温启比 7434440 慢 ~170 ms（≥5 个标准误），差量几乎全部落在
`log_pool_start` 标签窗口内；`lsl_*`、`ms_local_storage_meta_service`、`wait_metadata_ready`
三项无差异，说明 Phase 1/3 相关路径本轮没有回归。

### 结果：首启（launch1，全新 store，n=5）

| 指标 | 7434440 | ccfc8d39 | Δ |
|------|--------:|---------:|---:|
| `seekdb_open` 均值 | 909.2（862.3–972.6） | 1032.4（905.1–1265.1） | +123 ms |

首启同样偏慢，但 ccfc8d39 侧有两个高离群点（1165.0 / 1265.1，对应 `observer.init` 187.0 / 113.9 ms），
样本少、方差不低，**只作方向性参考**。

### DBA 14 步锚点交叉验证（最后一批 ab09 / ab10）

`8/14 → 9/14`（`observer instance start`，即 `log_pool_start` 标签对应的真实代码段）：

| run | launch2 | launch3 |
|-----|--------:|--------:|
| ab09（7434440） | 668.2 ms | 506.8 ms |
| ab10（ccfc8d39） | **820.6 ms** | **860.6 ms** |

两侧 `observer.init`(4/14)、`wait_server_runtime`(10–11/14)、`wait_metadata_ready`(12/14)
耗时基本一致（`observer.init` 仅 +10 ms），差异几乎全部集中在 `observer instance start`
一个窗口内，与 logcat 侧结论自洽。

### 正确性未受影响（本轮同一批数据的附带结论）

- **30/30 launch 均打印完整 `seekdb_open` 汇总行**，两臂都无挂起（对比 abb19e 的挂起）。
- `ccfc8d39` 数据持久化探针通过：`DataPersistSeedTest` OK（1.107 s）、`DataPersistVerifyTest`
  OK（1.012 s），原始输出 `/tmp/persist_seed_ccfc8d39.txt`、`/tmp/persist_verify_ccfc8d39.txt`。

即 ccfc8d39 **修掉了挂起与丢数据风险，但把温启性能退回 ~973 ms**（≈ 32ee789 的 926–1,024 ms 水平），
7434440 曾经拿到的 ~130–170 ms 收益被交回。

### 下一步（建议按此二分）

1. **先拆 `log_storage.h` 的门控**：在 ccfc8d39 之上恢复 `has_embed_warm_snapshot_new_data_()`
   分支（无新数据走 `apply_embed_warm_snapshot_()`），只保留 `last_load_used_embed_warm_snapshot_`
   记账，CI + 真机复采一次 —— 预期直接拿回 ~150 ms。这是与 A/B 差量最吻合的单一变量。
2. 若第 1 步不足，再单独回退 `ob_ls.cpp` 的 `embed_replay_busy_spin_rounds` 2000→8000
   （8000 轮 PAUSE 自旋在 4 核移动端会挤占 replay worker，需单独验证）。
3. 两变量均单独验证过之后再考虑合并；验收沿用本文档的目标表（温启 `seekdb_open` ≤1,050 ms、
   三次 launch 均有完整汇总行）。

> 执行结果见下一节：第 1 步已复采验证通过（温启从 ~970 ms 回到 ~847 ms），
> 第 2 步（`ob_ls.cpp` 自旋参数）的剩余差量在噪声内，暂不需要。

### 复现方式

已把本轮临时脚本固化为 `docs/seekdb-android/measure/compare_ab_interleaved.sh`：

```bash
export ANDROID_SERIAL=98305968
# <rounds> 轮，每轮先跑 sha_a 再跑 sha_b，跑前清空 store；<start_index> 用于追加批次不覆盖旧产物
bash docs/seekdb-android/measure/compare_ab_interleaved.sh \
  7434440e0e0e11319782fd768a9cd45eccc63ad1 \
  ccfc8d39c4d454c812adb44f34c50d8803a9b76d \
  5 1
```

产物 `/tmp/abNN_<short>_{run.txt,launch1..3_logcat.txt,launch1..3_engine.log}`，
日志 `/tmp/ab_cross_<sha_a>_vs_<sha_b>.log`。

> 与 `compare_ab_emulator.sh` 的分工：后者把 baseline / optimized 两个 flavor 同时装上、
> 一次启动内对比；本脚本**每轮重建重装同一 flavor 并清空 store**，适合回答"B 相对 A 是否回归"。

---

## d248c8e（恢复温启门控）真机复采（2026-09-11 18:40–20:20）：温启回到 7434440 水平

### 本轮变更

`d248c8ece53`（`fix(embedded): restore warm manifest gate to skip log tail scan on warm start`）在
ccfc8d39 之上恢复 `has_embed_warm_snapshot_new_data_()` 门控：manifest 之后没有新日志时直接
`apply_embed_warm_snapshot_()`，不再扫 tail；同时新增 `found_new_entry` 记账，让"扫了 tail 但没扫到
新条目"也标记 `mls_palf_warm_fast`。

CI：run `34587159752`（`android-arm64-v8a` job success），APK 内 `libseekdb.so` sha256 前 16 位
`8936c42e78dd13cd`（`7434440` 为 `120e97ee8fa91bb8`，`ccfc8d39` 为 `0cb250d71177a41c`，三者互不相同）。

### 样本

同一台真机 98305968、baseline flavor，`compare_ab_interleaved.sh` 交叉 A/B（每轮重建重装 + 清空 store）。

| 臂 | commit | 完成的 run | 温启样本 n |
|---|---|---:|---:|
| A | `7434440` | ab11 / ab13 / ab15 / ab23 / ab25 / ab27 | 10 |
| B | `d248c8e` | ab12 / ab14 / ab16 / ab18 / ab20 / ab22 / ab24 / ab26 | 13 |
| C | `ccfc8d39` | ab17 / ab19 / ab21 | 4 |

### 结果：温启 seekdb_open（launch2/3）

| commit | n | 均值 | 中位 | 区间 | sd |
|---|---:|---:|---:|---|---:|
| `7434440` | 10 | 813.9 | 851.1 | 665.0 – 903.0 | 89.2 |
| `d248c8e` | 13 | 846.9 | 860.2 | 678.1 – 1078.2 | 120.4 |
| `ccfc8d39` | 4 | 972.0 | 963.9 | 817.6 – 1142.6 | 158.4 |

同窗口完全交叉的三个批次单独看（可比性最强）：

| 批次 | 臂 | n | 均值 | 中位 |
|---|---|---:|---:|---:|
| ab11–16 | `7434440` | 5 | 803.4 | 862.8 |
| ab11–16 | `d248c8e` | 5 | 831.7 | 878.0 |
| ab17–22 | `ccfc8d39` | 4 | 972.0 | 963.9 |
| ab17–22 | `d248c8e` | 5 | 885.8 | 860.2 |
| ab23–28 | `7434440` | 5 | 824.4 | 839.5 |
| ab23–28 | `d248c8e` | 3 | 807.4 | 809.3 |

分项（温启均值，ms）：

| 指标 | `7434440` | `d248c8e` | `ccfc8d39` |
|---|---:|---:|---:|
| `log_pool_start`（=`SERVER_STORAGE_META_SERVICE.start()` 窗口） | 602.7 | 624.3 | **751.9** |
| `wait_metadata_ready` | 136.0 | 135.3 | 138.8 |
| `sms_replay_slog` | 43.4 | 51.5 | 55.3 |
| `lsl_append_start` | 134.2 | 149.5 | 122.9 |

### 结论

1. **门控恢复生效**：温启从 `ccfc8d39` 的 ~970 ms 回到 `d248c8e` 的 ~847 ms（均值 972.0 → 846.9，
   Δ≈125 ms；中位 963.9 → 860.2），中位已与 `7434440` 的 851.1 重合，均值差 33 ms（< 0.3 个 sd）。
   三个批次各自交叉看：批 ab11–16 里 `7434440` 略快（803.4 vs 831.7），批 ab23–28 里 `d248c8e`
   略快（807.4 vs 824.4），方向不一致，说明两者已经落在同一水平。
2. **差量位置自洽**：Δ 仍然全部落在 `log_pool_start` 窗口（751.9 → 624.3），`wait_metadata_ready`
   三个 commit 几乎相同（136.0 / 135.3 / 138.8），说明恢复门控没有把别的路径带慢；这与
   "`LogStorage::load` 少扫一次 tail" 的机制一致。
3. **上一轮回归结论可复现**：本轮 `ccfc8d39` 的 4 个样本均值 972.0，与上一轮 10 个样本的 973.0 一致；
   合并 14 个样本后 `d248c8e` 相对 `ccfc8d39` 的 ~126 ms 差量约 2.8 个标准误（Welch t=2.81，
   df≈24，p≈0.01）。
4. **不建议继续回退 `ob_ls.cpp` 自旋参数**：只取样本最齐的 launch3，`7434440` 均值 760.9（n=6）、
   `d248c8e` 788.2（n=8），差 27 ms，远小于两者 sd（≈90–120 ms）；且 `lsl_append_start` 这一项
   `d248c8e` 反而偏慢（149.5 vs 134.2），继续动的风险大于收益。

### 本轮暴露的两个环境问题（影响样本完整性，非引擎结论）

1. **磁盘写满**：第 3 批 ab19–ab22 全部失败，原因是 `unzip libseekdb.so: write error (disk full?)`
   （当时 `/System/Volumes/Data` 仅剩 ~180 MB）；清理 `/tmp` 下的重复引擎包与
   `examples/todo-app/app/build` 后重跑通过。第 6 批的收尾一轮 ab28 又栽在同一处（批末只剩 330 MB
   可用）。**根因是测量脚本自身的临时目录泄漏**，已在文末「空间问题根因 + 加宽窗口复验」定位并
   修复（跑批前自动清理 + ≥5 GB 空间门禁），ab28 也已补齐。另注：每轮 Gradle 构建会长回约
   1.2 GB（`app/build` + `seekdb-android/build`），删掉这两个目录可立即回收。
2. **真机掉线**：第 5 批 ab25–ab27 曾整体失败于 `adb: device '98305968' not found`（USB 掉线）；
   重新插上后重跑 ab25–ab27 全部通过，本轮实际只缺 ab28 一轮。

另外，本轮 17 次 launch2 中有 7 次在 12 s 窗口内没有走完（设备侧 `seekdb.log` 停在
`[server_start 11/14] wait for server runtime success`，连 `seekdb_open` 汇总行都没打印），三个
commit 都有（`d248c8e` 丢 5/8、`7434440` 丢 2/6、`ccfc8d39` 丢 2/3）。丢失的是偏慢的样本，方向对
`d248c8e` 不利，所以"门控恢复有效"的结论只会更保守。已在真机上单独复现并定位，原因见本节末尾
的「附带发现」：卡在 `wait_metadata_ready`（schema-ready 等待），与本次门控改动无关。

### 附带发现：温启偶发 16.6 s 级停顿（原来是批次丢样本的真凶）

批次跑完后用同一台真机复测，确认批次里 7/17 次 launch2 丢样本不是"日志丢了"，而是**启动真的卡住了**。

- 复现配方：`wipe store → launch1 等 18 s → force-stop → launch2`。命中率约 1/3（探针 1：8 次中第 2 次；
  探针 2：3 次中第 3 次；探针 3：第 1 次；探针 4：第 1 次）。对照组"不清 store 直接
  force-stop + launch"连续 11 次一次都没命中。
- 卡的位置（一次完整抓到，设备侧 `seekdb.log` + logcat 时间线）：

  ```text
  [20:27:30.956] [server_start 11/14] wait for server runtime success.      ← ob_server.cpp:1514
  [20:27:47.606] [server_start 12/14] wait schema ready begin.             ← ob_server.cpp:1539（过了 16.65 s）
  [20:27:47.607] [server_start 14/14] observer start success.
  ```

  logcat 侧对应：`wait_metadata_ready cost_us=16650819`（正常约 136,000），
  `seekdb_open … start_and_wait_us=17552192 total_us=17631323`（即这次启动 17.6 s）。

- **不是本次门控改动引入的**：复现时设备上装的是 `7434440`（sha `120e97ee8fa91bb8`）的 APK。
- 严重程度不一致：上面这次是 16.65 s 后自己恢复；另外至少抓到 1 次等满 120 s 仍未打印
  `seekdb_open` 汇总行（`/tmp/stall_engine.log` 停在 11/14，`/tmp/stall_logcat.txt` 时间线停在
  `sms_sms_ckpt_timer_start`），所以存在"很久"和"更久"两种量级。
- 证据：`/tmp/stall_engine.log`、`/tmp/stall_engine2.log`、`/tmp/stall_engine3.log`（16.65 s 那次）、
  `/tmp/stall_logcat{,2}.txt`、`/tmp/stall_stack_logcat.txt`、`/tmp/stall_threads.txt`。

代码定位（读码推断，未验证）：16.65 s 全部落在 logcat 的 `wait_metadata_ready` 窗口，对应
`wait_primary_metadata_ready()` → `ObServer::check_if_schema_ready()`（`ob_server.cpp:1524`）。
该函数在 schema 未 ready 时是 `while (!stop_ && !schema_ready)`，embedded 模式每次 `ob_usleep(1 ms)`
自旋（`SLEEP_INTERVAL_US = 1000`），所以 16.65 s ≈ 1.6 万次轮询——即"schema 迟迟不 ready"，
不是死锁（进程内 100 个线程全是 `S`，`T1_ReplaySrv0/1` 空闲，没有自旋线程）。

下一步建议（这是一条独立的、比剩下 ~30 ms 更重要的线）：

1. 在 `check_if_schema_ready()` 的循环里加临时日志（每 100 ms 打一次 baseline / current schema
   version 和 `is_replay_done`），先确定它到底在等谁：schema refresh 任务，还是 replay drain。
2. 重点怀疑 replay/schema 的串联依赖：`ObReplayStatus::is_replay_done()` 在 `!is_enabled_` 时返回
   `is_done = false`（`ob_replay_status.cpp:814` 附近 "replay is not enabled"），而
   `ObLS::start_local_log_`（`ob_ls.cpp:453`）的等待循环依赖这个信号。a302cc4 当初正是把
   "replay disabled 也算 done" 当作 replay skip bug 处理、随后被 ccfc8d39 回退的，这条
   "等不到信号" 的窗口因此一直存在。
3. 验收：连续 20 次 `wipe → launch1 → launch2`，`wait_metadata_ready` 全部 < 500 ms。

### 复现命令

```bash
export ANDROID_SERIAL=98305968
bash docs/seekdb-android/measure/compare_ab_interleaved.sh \
  7434440e0e0e11319782fd768a9cd45eccc63ad1 \
  d248c8ece53fc775e8ae9a4a5ccbe3fb1fe8efd3 3 23
```

产物：`/tmp/ab{11..28}_<short>_{run.txt,launch1..3_logcat.txt,launch1..3_engine.log}`；
批次日志 `/tmp/ab_batch{3,4,5,6}_log.txt`、`/tmp/ab_cross_*.log`。


## 空间问题根因 + 加宽窗口复验（2026-09-11 20:40–21:15）

### 根因：`remeasure.sh` 每次运行泄漏 2 × 148 MB 临时目录

上一节的 `disk full` 不是偶发：`extract_so_from_zip()` 用 `mktemp -d` 解包 148 MB 的
`libseekdb.so`，APK 内 `.so` 校验又用一次 `mktemp -d`，两处都从不删除。`$TMPDIR` 里因此积了
**123 个 `tmp.*` 目录、共 16.4 GB**（指纹：目录内含 `lib/arm64-v8a/libseekdb.so`），
6 轮一批约 1.8 GB —— 正是 ab19–ab22 / ab28 失败的来源。清掉后 `/System/Volumes/Data`
从 417 MB 回到 ~17 GB 可用（同时清掉 Chrome 缓存的 1.2 GB）。

修复已落地：

- `remeasure.sh`：改为一个 `WORK_TMP="$(mktemp -d)"` + `trap cleanup EXIT`（与原有的
  `restore_manual_so` 合并），zip 解包与 APK 校验共用它；新增 `require_free_space`，默认要求
  ≥5 GB，不足时直接退出并打印回收命令。
- `compare_ab_interleaved.sh`：跑批前 `sweep_stale_temp`，只删「15 分钟窗口之外」且
  「内部含 `libseekdb.so`」的 `$TMPDIR/tmp.*`（指纹判定，不会碰到其他程序的临时目录），并在
  批前/批后打印磁盘水位。

验证：ab29–ab34 一批跑完磁盘从 25 GB 升到 26 GB（旧行为是每批净减 ~3 GB），批后只剩 2 个
未过 15 分钟保护期的 `tmp.*` 目录。

### 补记（21:25）：同一根因下还漏掉三处，已一并修掉

上面只覆盖了 `remeasure.sh` 的两个 `mktemp -d` 和"目录"型残留，收尾复验时在 `$TMPDIR` 里
又找到一枚 **141 MB 的裸文件** `tmp.Ofi6ldYdXL`（`file` 判定：ELF 64-bit ARM aarch64 shared
object，`sha256` 前缀 `295c627a…`，mtime 今早 10:25），说明泄漏面比上一节写的更大：

1. **`remeasure.sh` 的 manual-.so 备份**用独立 `mktemp` 建了个 148 MB 的临时**文件**
   （不在 `WORK_TMP` 里）：trap 正常跑完时会被 `mv` 消费掉，但进程被 kill 就整枚留下。
   已改为 `JNI_BACKUP="${WORK_TMP}/libseekdb.so.orig"`，由同一个 `trap cleanup EXIT` 兜底
   （`cleanup` 先 `restore_manual_so` 再 `rm -rf WORK_TMP`，顺序不变）。
2. **`compare_ab_emulator.sh` 完全没做清理**：`extract_so_from_zip()` 每次调用都 `mktemp -d`
   解一份 148 MB 的 `.so`，一次运行至少调 4 次（两臂各 1 次 + 两次 APK 校验），
   `verify_apk_so()` 自己再建一个临时目录——单次运行泄漏约 600 MB。已改为统一
   `WORK_TMP="$(mktemp -d)"` + `trap cleanup EXIT`，zip 解包/APK 校验的临时目录都挂在
   `WORK_TMP` 下，并复用 `require_free_space`（≥5 GB 门禁）。
3. **同一脚本的备份会被第二臂覆盖**：`GP_BACKUP`/`JNI_BACKUP` 原本在 `stage_engine_zip()` 里
   每次 stage 都重新赋值，第二臂覆盖掉第一臂的备份，EXIT 时 `mv` 回去的是"已被清空前缀"的
   `gradle.properties` —— 即脚本跑完后跟踪文件里的 `LIBSEEKDB_URL_PREFIX` 会留空
   （正是 `remeasure.sh` 头部注释里记录过的"仓库文件被改脏"事故）。已把备份提到首臂构建之前
   做一次（新增 `backup_repo_state()`，早于任何 stage）。
4. **`sweep_stale_temp` 只删目录**，删不掉上面那枚裸文件。已扩展为：`tmp.*` 目录内部含
   `libseekdb.so`，或 `tmp.*` **裸文件** ≥100 MB 且 `file` 判为 aarch64 shared object；
   15 分钟保护期与"只认自家指纹"的原则不变。

自测（构造样本 + 单独 eval 出 `sweep_stale_temp`，`TMPDIR` 指向沙箱）：

```text
swept 142 MB of stale engine temp leftovers under /tmp/sweeptest.aQX02I
KEEP ok: tmp.keepdir   （旧目录、无 libseekdb.so）
KEEP ok: tmp.freshdir  （含 libseekdb.so，但未过 15 分钟保护期）
KEEP ok: tmp.smallfile （旧的小文件，1 KB）
SWEPT ok: tmp.staledir （旧目录、含 libseekdb.so）
SWEPT ok: tmp.stalefile（旧的 148 MB aarch64 .so）
```

`restore_manual_so` + 新 `cleanup` 的还原逻辑也单独跑过：备份放在 `WORK_TMP` 时，
`cleanup` 后 `jniLibs` 内容回到 ORIGINAL、`WORK_TMP` 整个消失、无残留 `.orig` 文件。

真机上的三处历史残留（1 枚 141 MB 裸文件 + 2 个 142 MB 目录）已手工回收，磁盘从 26 GB
回到 27 GB；`$TMPDIR` 里剩下的 8 个 `tmp.*` 全是其他程序的小文件（合计 24 KB），不在指纹内。

### 复验：ab28 补齐 + launch2 采集窗口 12 s → 30 s

- ab23–ab28 重跑通过，`ab28`（先前只剩 `run.txt`）已补全 launch1/2/3 日志；重跑前的旧产物
  存 `/tmp/ab_batch6_pre_reverify/`。
- launch2 窗口 12 s → 30 s（`remeasure.sh` 的 `capture_launch 2 30`）：命中 schema-ready 停顿的
  run 不再被静默丢弃。ab29–ab34 里 launch2 丢失从 6/6 降到 2/6，保留下来的样本
  `wait_metadata_ready` 全在 90–156 ms（正常区间）。
- 仍然丢失的 `ab33` / `ab34` 的 launch2，设备日志停在 `[server_start 11/14]`（ab34 停在 8/14），
  即超过 30 s 仍未走出该窗口 —— 与「附带发现」同一处，属独立于门控改动的引擎侧问题。
  单独复现一次（wipe → 冷启 18 s → 强杀 → 温启，窗口放宽到 25 s）是正常的 1.16 s，
  `wait_metadata_ready=176 ms`，说明它是间歇性的。

### 合并统计（launch2+3 温启，ab11–16 + ab23–28 + ab29–34）

| commit | n | 均值 | 中位 | sd |
|---|---:|---:|---:|---:|
| `7434440` | 13 | 805.2 | 819.0 | 99.1 |
| `d248c8e` | 13 | 759.3 | 716.4 | 107.6 |

差 45.9 ms，Welch t=1.09（df≈24），不显著；方向仍略偏 `d248c8e`，与上一节「两者落在同一水平、
门控恢复未引入回归」一致。两臂各丢 5 个样本（丢失的都是偏慢样本，方向对 `d248c8e` 不利）。

逐批方向：ab11–16 差 −28.3 ms（`7434440` 快，t=−0.39）、ab23–28 差 +71.7 ms（t=0.74）、
ab29–34 差 +104.5 ms（t=1.78）。

### 复验命令（加宽窗口批次）

```bash
export ANDROID_SERIAL=98305968
bash docs/seekdb-android/measure/compare_ab_interleaved.sh \
  7434440e0e0e11319782fd768a9cd45eccc63ad1 \
  d248c8ece53fc775e8ae9a4a5ccbe3fb1fe8efd3 3 29
```

产物：`/tmp/ab{29..34}_<short>_{run.txt,launch1..3_logcat.txt,launch1..3_engine.log}`，
批次日志 `/tmp/ab_cross_7434440_vs_d248c8e.log`（上一批的副本：
`/tmp/ab_batch6_reverified_cross.log`）。



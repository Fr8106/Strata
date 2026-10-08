# 加固行动计划（2026-10-08）—— 注册边界故障类，执行版

> **输入链**：`docs/HARDENING-HANDOFF-2026-10-08.md`（我方交接）→ 专家审核 `HARDENING_PLAN_REVIEW.md`（外部文件，T0 归档入 `docs/reviews/`）→ 本轮对代码逐条裁决（10 处"待核实"全部核实，结论见 §2）。
> **原则**：先核代码再造轮子——本轮已发现 3 处专家建议的机制**代码里已存在**（§2），照单实施会白干。
> **纪律不变**：窗口闭环脚本 + dead-man + kill -9 兜底 + 孤儿显存 ABORT；停 swift15/动服务前先征得用户同意；`strata.service` 由 systemd 托管（`sudo systemctl stop/start strata`）。

---

## 1. 任务总览

| ID | 任务 | 优先级 | 需要 GPU/窗口 | 规模 | 依赖 |
|----|------|--------|---------------|------|------|
| T0 | 归档专家审核 + 逐条核对文档 + 旧文档修正 | P0 | 否 | ~1 h | 无 |
| T1 | 基线测量（decode、noalias 命中、bounce 现状） | P0 | 窗口 | 半天 | 用户放行 |
| T2 | fill bounce 可见化修正包（含 staging 竞态实锤修复） | P0 | 编译即可，验证在窗口 | ~25 行 | 无 |
| T3 | 启动期几何校验 + 布局不变量单测 | P0 | 单测无需 GPU | ~200 行 | 无 |
| T4 | 探针矩阵 t18（关键新增：**仅 Portable** 情形） | P1 | GPU（可与 swift15 共存，小分配） | ~200 行 | 无 |
| T5 | R1 构建侧页对齐填充（前提已核，见 §3-T5） | P1 | 窗口验证 | ~60 行 | T4 结果、T1 |
| T6 | ~~R8 fail-fast~~ → **已存在，只记录** | — | — | 0 | — |
| T7 | noalias 遥测 + `STRATA_FORCE_NOALIAS_PCT` 注入 + 浸泡 + teardown 顺序 | P2 | 窗口（夜间浸泡需放行） | ~60 行 | T1–T3 |
| T8 | R7 `HostRangeTable` 封装 | **暂缓** | — | — | T2–T5 落地后重新评估 |

分支：`hardening/2026-10-08`，一任务一 commit；任何一步崩了 `git revert` 单提交即可回退。

---

## 2. 先于一切的核实结论（纠正双方文档）

**已存在、不必再造**（照专家清单实施会重复建设）：

1. **R8 fail-fast 已在两处自旋里**：`verify.cpp:1458-1466`（window）与 `:1996-2004`（batch）——每 1024 spin / ~2 ms `cudaStreamQuery(cs_)`，seq 落后且流报非 NotReady → 立即 `never rang (<err>)` 退出。**毫秒级 fail-fast 已经在了**；专家建议的示意代码与现行实现几乎逐行同形。剩余只有可选的 NVML Xid watcher（P3，YAGNI：现机制已覆盖本类）。
2. **R4 释放取整已两端向内**：`release_fixed_tier`（`expert_source.cpp:3015-3021`）只 DONTNEED `[ceil4k, floor4k)` 内部，边页显式保留（注释 3002-3004）；per-expert `release()`（`:2991-2992`）同规则。生产形态 arena 为匿名/pinned 选择性注册，`release()` 在 selective 模式返回 0（`:2984`）。
3. **R5 "静默坏数据"路径已封**：释放时别名全部置空（`:3028-3029`）；`fixed_released_` 武装 `blob()` 守卫（`:3323-3339`，"never silent zeros"，warn-once + 落 CPU 路）；`release_fixed_tier` 唯一调用点在**启动期 fill 之后、serving 之前**（`generate.cpp:4523`）——生产流程无运行时窗口。状态机留给未来动态释放，本轮不做。

**R3 裁决（别名只查头？）**：不是半漏。`bo >= ns && bo < end`（`:3162`）中 end=层逻辑末端，blob 按 `per` 连续平铺（布局保证 `bo+per ≤ end`），run 注册到 `ne = ceil4k(end) ≥ end` → 尾自动被包含。但保护来自平铺不变量而非显式检查——**T3 的校验器把它显式化**。

**实锤的潜伏 bug（本次审核最值钱的一条，专家 H1.4）**：`fill_slot_queued` 重试分支（`expert_cache.cpp:675-676`）——重试先 CPU `memcpy` 写 `blocking_staging_`，而**上一笔**从该 staging 出发的 `cudaMemcpyAsync`（legacy stream 0）可能仍在飞；CPU 写不与流排序 → 覆盖在飞数据。今天因 gap 修复该分支几乎不触发所以未爆。T2 一并修。

**降级为"待复测"的旧断言**：交接文档 §4-1 的"内存压力下未注册区 HtoD 被拒"（9ad8c44 时代，混杂 per-blob 注册/THP/内存压力）——措辞降级为"现场观察，隔离复测未做"；隔离复测折进 T4（t18 加一臂：全不注册 + 内存压力 + pageable）。

---

## 3. 各任务细则

### T0 归档与文档修正（无风险，先做）
1. 专家审核原文复制为 `docs/reviews/HARDENING-PLAN-REVIEW-2026-10-08.md`（沿用 `P4A-REVIEW-*` 惯例）。
2. 新增 `docs/reviews/HARDENING-PLAN-REVIEW-ANALYSIS-2026-10-08.md` = §2 的逐条裁决表（对代码引用带行号）。
3. `docs/HARDENING-HANDOFF-2026-10-08.md`：§4-1 措辞降级（见上）；§3-H1 的"次数必须为 0"改为"**几何类 == 0**、其它类计数上报"；补"R8 已存在"事实。
4. `docs/HANDOFF-VERIFY-TIMEOUT-2026-10-07.md` 顶部加横幅："根因已由 `64ff01e` 确认修复（别名负偏移）；本文的 KV 饱和/超时放宽路线已被证伪或取代"，并修正 Xid 因果一行（别名越界读 → Xid 31 → flag 停 → 超时）。
5. 假设登记表（专家 §6 表）作为附录挂到 handoff 末尾，每行配探针与退路。

### T1 基线测量（改代码**之前**）
- 复用 `ab-win.sh` 形态：1K/8K/32K prefill + decode tok/s，3 次取中位（上次基线：32K 4417–4506，decode 104–198）。
- 新增一行读数：每层 `rank == nfix`（骑边界）专家的路由命中次数——现遥测无此计数，**先读 usage/请求日志近似**（T7 加正式计数器）。
- 产物 `tools/repro/hardening-baseline.txt`；窗口闭环（systemd 停/启 + dead-man）。**需用户放行窗口。**

### T2 bounce 可见化修正包（`src/core/expert_cache.cpp`）
位置：`:641-647`（blocking 重试）、`:671-677`（queued 重试）。改动：
1. 重试分支入口：限流日志（前 5 条逐条：`fill bounced a rejected copy: <bytes> B, src=<ptr>, pending=<err>`；此后每 256 次汇总一行）+ 成员计数 `bounces_`（getter，T7 挂进 serve 遥测）。
2. **staging 竞态修复**：queued 重试在第二次 `cudaMemcpyAsync` 之后 `cudaStreamSynchronize(0)`（该分支罕见，同步代价可忽略；blocking 路径本就同步）。
3. 重试成功后 `(void) cudaGetLastError();` 清掉那次 InvalidValue——否则下一个调用者的 stale-error 探针（`:617-622`）会报假现场。
4. 分类（InsideRun/SpansGap/…）不在这里做：本层没有 run 表；日志带 `src` 地址，离线对 `STRATA_PCIE_REGLOG` 分类即可得出"几何类 == 0"。
- 冒烟：重建后跑 `seq-160k-win.sh` 形态三连，确认 `bounces=0`。

### T3 启动期几何校验 + 布局单测
1. `register_tier_runs`：把 `alias_runs_`（现在只有偏移）扩成 `runs_ = {(off, size, kind)}`，并记下每 run 的 device 基址（`GetDevicePointer` 已调过，零额外成本）。
2. 新增 `ArenaExpertSource::validate_geometry(std::string&)`：在 canary L0 之后、serving 之前调用——
   - run 页对齐、互不重叠；
   - 每个 blob：`blob_dev_ != null ⇒ run_start ≤ bo && bo + per ≤ run_end`，且 `blob_dev_ == dev_base + (bo - run_start)`（**把 R3 的尾部包含从隐式变显式**）；
   - 汇总一行 `geometry: runs=96 aliased=… noalias=… bad=0`；`bad > 0` → 启动失败（不静默）。
3. 单测（无 GPU）：`tests/core/expert_layout_test.cpp` 增段——随机 `per`/`nfix`/层数合成布局，断言 `expert_off` 平铺、`bo>=ns` 规则、边界对齐；ctest 已挂（`CMakeLists.txt:441-444`）。
4. 边界 blob 校验和（专家 R4.3）：装载时对每 run 首/末 blob 记 64-bit 和，`release_fixed_tier` 后复核**非固定侧**外沿 blob（~96 个，微秒级），不一致 → 报错不静默。并入 validate 函数。

### T4 探针矩阵 t18（`tools/repro/t18.cu`，t17 的表驱动扩展）
维度：标志 {`Portable|Mapped`，**仅 `Portable`**} × 大小 {4 KiB, 64 KiB, ~2 MiB, 2.66 MiB} × 页内偏移 {0,1,2048,4095} × 形状 {run 内、恰至末端、越界 1 B、越界 1 页、gap 中、相邻跨界}。
- **关键臂**：仅 Portable 的相邻跨界——若**接受**，则 fixed run 可去 Mapped（R12 成立），gap 设计也可简化；
- 附带臂（隔离复测 R11）：全不注册 + `cudaHostRegister` 前 touch + 内存压力上下文，验证"未注册源被拒"是否复现；
- 小分配（MB 级），可与 swift15 共存（t16 先例），无需停 LLM。
- 产物 `tools/repro/probe-matrix-results.txt`；结果回填 handoff 假设登记表。

### T5 R1 构建侧页对齐填充
- **前提已核**（推翻我方此前否决）：tier 序只存在于内存 `expert_off` 表（`load_experts_tier` 把 experts.bin 规范序拷成 tier 序；`expert_layout.hpp:90`：层起点不变、只有 `blob_offset` 动）→ **填充只进偏移表，文件格式不动**。
- 实施：`expert_layout_tier_order` 给每层 fixed 前缀后加 pad，使 `非固定块起点` 4K 对齐（≤4095 B/层，全 arena ≤192 KiB；层内步长 `layer_bytes += pad`，PinnedArena 层界随之走）。
- 效果：`bo >= ns` 恒真、跨界拷贝不存在、**每层 0 个** CPU-path 专家（顺带解决 R6 的"最热非驻留被降级"）；gap/别名规则/bounce 保留为纵深防御。
- 验证：T3 校验器全绿 + T1 基线对照（prefill/decode 不降）+ `expert_layout_test` 合成段。
- 若 T4 表明仅-Portable 相邻已被接受：gap 逻辑可进一步简化——**先测后改**，本任务默认保守版（只加 pad）。
- **2026-10-08 设计结论（实施前核查）**：pad 只进 `expert_off` 表不够——层跨度数学假设 arena==file：
  `register_tier_runs` end（:3117）、`validate_geometry`（:3220）、`fixed_runs_`（:3274）、canary（:3327）、
  load bounds（:2813）、`experts.bin` 尺寸核对（`got != want`，:2717）、pack hash（:2430）都要改，
  改动落在装载器/包一致性这一最高风险面。收益=每层 1 个跨界 blob（48/24576≈0.2%）少走一次非零拷贝。
  **门**：T7-1 `noalias_reads` 遥测（已入库 61f3cb2）+ T4/t18；遥测显示边界专家基本不被热取 → 本任务关闭。

### T7 P2 包
1. `noalias_hits` 计数：`blob()`/`pinned()` 返回 null 的 CPU-path 分支计数，进 serve 遥测行（R6 正式化）。
2. `STRATA_FORCE_NOALIAS_PCT=N`：注册时随机 N% blob 不发别名（仅调试构建路径，warn-once），跑 `seq-160k` 全链——压所有 `pinned()==false` 消费者（verify/prefill/loan/adapt）。
3. 浸泡：夜间 `≥30` 序列或 ≥8 h（复用 `aprime-win.sh` 闭环 + dead-man，systemd 托管），指标=验收表 §4。
4. teardown（R10）：`close()`（`expert_source.cpp:2930`）现无条件二次注销——在 `release_gpu_waits` 后若设备同步失败（卡死）则跳过 unregister/munmap，让内核回收，避免次生 Xid 污染取证（`generate.cpp:7317` #224 注释是旁证）。

**状态（2026-10-08）**：1/2/4 代码已入库（61f3cb2，实现注：1 的漏斗是 `blob()` 里 `blob_dev_[idx]==null`——CUDA 路 noalias 时 `blob()` 本身不返回 null；2 是注册后置一遍确定性抽样（g%100<pct），geometry 行/edge hash 反映注入后状态）。3（浸泡）与 `seq-160k` 注入跑挂窗口。

### 窗口实测（10-08 11:50，`tools/repro/hardening-win.sh`，记录 `tools/repro/hardening-win-results.txt`）
- **T4 完成**：t18 全矩阵落 `tools/repro/probe-matrix-results.txt`（含裁决段）。规则：flags 无关（Mapped 只买到
  `cudaHostGetDevicePointer`）；跨两个注册 run＝拒（gap 与相邻同矩阵）；**run→gap 方向拒、gap→run 方向收**（不对称）。
  引擎每层 ≤2 个 no-alias blob：非固定侧边界 blob 拷贝方向被收（64ff01e 只撤它的别名——GPU 读越映射才是 #267）；
  固定侧末 blob 拷贝方向被拒 → 走 T2 bounce（实测每次启动 ≥5 次，全是这个方向；T2 之前它就是 B 臂"静默跳过"形态）。
- **T1 完成**（加固版基线，seq 32K/100K/160K，3/3）：prefill 4697.8/4645.5/4599.1 tok/s（参照 4468 → 101–105%，不降）；
  decode 169.4/149.3/183.3 tok/s（带 104–198 内）；verify 超时 0；geometry `bad=0`（三次冷启动逐位一致）；
  MemAvailable 谷 14.3 GiB（安全线 8）。
- **T7-2 注入臂完成**（`STRATA_FORCE_NOALIAS_PCT=5`，+897 个撤别名）：3/3 完成、超时 0、bounce 形态不变——
  所有 `pinned()==false` 消费者（verify/prefill/loan/adapt）在 CPU 路上无一崩。
  性能代价定标 T5：noalias 25.8%→29.5% 对应 160K prefill −3.4% ⇒ 线性外推 48 个边界 blob（0.2%）≈ **0.03%**，
  装载器不变式手术不值——**T5 按遥测门关闭**（决策记录见 T5 节）。
- 恢复后 :8088 服务即加固版（geometry 行是代码指纹），注入臂日志与基线臂一致，无残留。

### T8 暂缓（明示）
R7 封装：T2–T5 后调用点仍只有 3 处 + 校验器一处，抽 `HostRangeTable` 收益未证明；且**禁止**建第二份 run 表（#267 本身就是两份视图不同步的病）。T5 落地后重评。

---

## 4. 验收判据（最终口径）

| 判据 | 目标 | 来源 |
|---|---|---|
| `geometry: … bad=0` 启动行存在 | 必须 | T3 |
| `noalias` 计数 | T3/T1 实测（≈48）→ T5 后 ==0 | T3/T5 |
| bounce 计数（任何类） | 浸泡期 ==0；>0 按 reglog 离线分类，**几何类必须 0** | T2 |
| `fetch_dma` 失败行 | 0 | 已实现 |
| dmesg Xid 31 | 0 | 观察 |
| verify 超时 / never-rang | 0 | 已实现 |
| 32K prefill | ≥4417–4506 带（基线 99–101%） | T1 |
| decode tok/s | 不劣于 T1 基线带 | T1 |
| MemAvailable 峰值 / 归还 | >8 GiB / 11.19 GiB 不变 | 已有不变量 |
| ctest（含新合成布局测试） | 全绿，无 GPU 可跑 | T3 |

## 5. 风险与退路

| 风险 | 缓解 / 退路 |
|---|---|
| T2 同步语句拖慢罕见路径 | 分支触发即异常状态，慢无所谓 |
| T3 校验器误杀启动 | 首周 `bad>0` 只 FAIL 合成测试；引擎侧先 WARN + 计数，两个 soak 夜无假阳后升为 fail-closed（改一行） |
| T5 改动触碰层步长 → 回归 | 校验器 + ctest + 基线对照；单 commit revert |
| T4 发现仅-Portable 语义不同 | 只是信息，不改代码；假设登记表更新 |
| 浸泡撞孤儿显存 | 既有 ABORT 守卫；重启兜底（10-08 已验证流程） |
| 窗口占用影响用户使用 | 全部窗口需用户放行，夜间执行 |

## 6. 执行顺序

```
T0 ──► T2 ──► T3 ──► (T4 ‖ 编译测试) ──► T1窗口 ──► T5 ──► T7(含夜间浸泡) ──► 复审/提交main
                 └────────── 单测无GPU可并行 ──────────┘
```

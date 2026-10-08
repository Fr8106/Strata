# 交接文档：零拷贝注册边界故障类 —— 加固方案求助人类专家

**日期**：2026-10-08　**机器**：RTX 5090 32 GiB + 62 GiB RAM + Ryzen 9 5900X，Ubuntu 24.04，驱动 610.57.04，CUDA 13.0
**模型**：Qwen3.8-Flash-Next（48 层 × 512 专家 = 24576 个，IQ3_S，arena 46.84 GiB，`strata-iq3_s.json`）
**状态**：故障类的结构性修复（`64ff01e`）**已落地并验收**（100K→160K 序列 5/5 失败 → 3/3 通过）。本文交接的是**下一步加固方案**——三处改动已在代码里定位到行、方案已自我审核过一轮（两处原方案被撤回），请专家复核风险、回答 §5 的驱动语义问题。

---

## 0. 一句话求助

引擎把 46.84 GiB 的专家 arena 按层用 `cudaHostRegister` 注册成 ~48–96 段，其中固定半区（~50%）服务中会**整段释放**。同类故障已修过 **3 次、落在 4 处代码**（§1）。根因修复已就位（§2），准备做的加固是"**给兜底重试加一行吵的日志 + 修正一条写错的不变量 + 用脚本探针守几何**"（§3），并明确**不做**两件事（§4）。
请专家确认：§1 表格里 B/C/D 三行的驱动行为（相邻注册被拒 / gap 页可过 / bounce 可过）是**有文档保证的语义**还是**610.57.04 的实现现状**——我们的整个安全网按"后者"设计，若是前者可以简化；若驱动升级会收回，需要知道往哪迁（VMM？）。

---

## 1. 故障类与三次修复（历史）

**故障类定义**：GPU 侧对 host 内存的零拷贝访问（`cudaMemcpy(Async)` HtoD 的 Mapped 源、或设备指针别名解引用）落到了**注册段边界之外**——要么跨两段相邻注册（驱动拒绝），要么指向已释放映射的页（MMU fault）。

| # | 提交 | 代码位置 | 当时的症状与修法 |
|---|------|----------|------------------|
| 1 | `c976960` canary L0 | `src/core/expert_source.cpp:3249-3253` | canary 的 64 KiB 采样落在 fixed run 末页 → 源跨两段相邻 Mapped 注册，被拒（`invalid argument`），96 段形状误降级到 L2。改采样 non-fixed run 开头 |
| 2 | `beb9deb` fill bounce | `src/core/expert_cache.cpp:641-647`（blocking）、`:671-677`（queued） | tier 有序 arena 里 fixed/non-fixed 边界不 4K 对齐，首个非 fixed blob 起点骑在 fixed run 内 → profile fill 在 L9 pair 5898 死。改 `cudaErrorInvalidValue` 时经 pinned staging 重试（实测 ~48/24576 个 blob 跨界） |
| 3 | `64ff01e` #267 根因 | `src/core/expert_source.cpp:3115-3124, 3154-3165` + `src/core/verify.cpp:1630-1637` | 别名 `blob_dev_ = d + (bo - ns)` 中 `bo < ns`，负偏移 → GPU-direct 路径解引用到注册区外（fixed 半区释放后该页连映射都没有）→ dmesg `Xid 31 MMU Fault FAULT_PTE VIRT_READ` → 该层 flag 永不置位 → verify 20 s 超时、请求死（issue #267）。见 §2 |

**注意区分**：早期还有两次症状同为 `invalid argument` 但根因不同的修复——`9ad8c44`（fill 源在未注册区：内存压力下从"已 mmap 未注册"区拷贝也被拒；顺带实测**驱动注册段数上限 ~5300**：4628 段全过、9256 段 ~3900 被拒）和 `4255b29`（4424 个 `Mapped` 注册耗尽驱动资源，改 plain pin）。它们**不属于**本类，但 §5-Q1(c) 与 Q2 就是问它们的行为。

### 1.1 独立复现（t16/t17，均在本机 610.57.04 上实测）

`tools/repro/t16.cu`（同步）与 `tools/repro/t17.cu`（异步）把情形隔离到最小：

| 情形 | 结果 |
|---|---|
| A 单个 run 内拷贝 | OK |
| B 跨相邻两注册（引擎现行布局） | `cudaMemcpyAsync` 直接返回 `invalid argument`（`fetch_dma` 不检查 → 静默跳过，故障远离现场） |
| C 边界留一页未注册的 gap | **OK**（拷贝实际形态 = registered \| pageable \| registered） |
| D 经 pinned bounce | OK，数据一致 |

#267 的触发概率（修复前）：每 verify 窗口约 4/42（随机层恰为含边界专家的层），所以"有时好有时坏"；同尺寸 162,776 通过 / 163,108 失败也是这个竞态（`docs/HANDOFF-VERIFY-TIMEOUT-2026-10-07.md` §1 的时间线即当时的现场证据）。

---

## 2. 已落地的结构性修复（`64ff01e`，已验收）

1. **注册几何**：fixed run 只注册到 `floor4k(off+nfix)`，non-fixed run 从 `ceil4k(off+nfix)` 开始——共享页**永不注册**。任何跨界拷贝都变成情形 C 的形态，驱动接受（t17 C）。`expert_source.cpp:3115-3124`。
2. **别名规则**：`bo >= ns`——只有完全落在注册 run 内的 blob 才发设备别名；每层 ≤1 个骑边界的专家走 CPU 路（`pinned()` 报 false）。`expert_source.cpp:3154-3165`。**这条必须保留**：别名是 GPU 解引用，不是拷贝，gap 救不了负偏移指针。
3. **失败可见化**：`Verifier::fetch_dma` 的 `cudaMemcpyAsync` 失败现在打 stderr 并清 sticky（`verify.cpp:1630-1637`）；引擎死亡路径统一 `release_gpu_waits`（`pool.cpp:512/535`、`generate.cpp:6036`），不留自旋核。

**验收**（本机，2026-10-08）：曾经 5/5 必死的 100K→160K 序列（`tools/repro/reg-sequence.txt`）3/3 通过，160K 在 39–40 s，零 verify 超时、零拷贝失败，Option B 启动不变量完好（11.19 GiB 归还、prefill 99–101%）。

---

## 3. 准备进行的加固（未实施，请复核）

### H1. bounce 重试加一行吵的日志（唯一的新增代码，+2 行）
- 位置：`expert_cache.cpp:642` 与 `:672` 的 `if (e == cudaErrorInvalidValue)` 分支——目前**静默**重试。
- 内容：进入重试分支时打一行，例：
  `strata: fill bounced a rejected <n>-byte copy (slot <s>, pending: <pending>)`
- 理由：修复后几何里**不应再有跨界拷贝**，此分支触发 = 几何回退或驱动行为变了，必须当场可见（#267 教训：静默的 `fetch_dma` 让故障死在 20 s 之外）。happy path 零开销。
- **验收判据：几何类（SpansAdjacentRuns）触发必须为 0**；其余分类（压力/生命周期）单独计数上报——它们可能来自未文档化的驱动行为或竞态，不是几何 bug（10-08 按专家 H1.1 修正，原"总数必须为 0"过宽）。分类可离线做：日志带 src 地址，对照 `STRATA_PCIE_REGLOG` 的注册区间表。

### H2. 几何探针走脚本，不进生产 canary
- 把 `t17.cu` 的情形 B/C 做成启动前/CI 探针（每次驱动升级后跑一次）：验证"相邻注册被拒、gap 可过"仍是现状。
- 生产 canary（`expert_source.cpp:3290-3319` L0/L1/L2 阶梯）保持现状不动（理由见 §4-2）。

### H3. 修正不变量的表述（文档/注释，零代码）
- 此前口径"相邻 run 之间至少隔一页未注册"**不总是成立**：若 `off+nfix` 恰好 4K 对齐，`floor4k == ceil4k`，两段**紧邻、gap=0**。它安全只因为此时没有任何 blob 骑边界。
- 真正成立、可断言的不变量（`bo >= ns` 构造保证）：
  > **每个 blob 要么完全在其注册 run 内（有设备别名），要么无别名、走 CPU 路。**
- 若将来给这段加断言，请按上式写，勿断言 gap≥1 页。

---

## 4. 明确**不做**的两件事（自我审核后撤回，请勿顺手做）

1. **不删 bounce 兜底**（`expert_cache.cpp:641-647`、`:671-677`）。它覆盖的比跨界类宽：
   - `9ad8c44` 时代**现场观察**：内存压力下从"已 mmap 未注册"区直接 HtoD 曾报 `invalid argument`（当时混杂 per-blob 注册/THP/未发现的别名越界等因素；隔离复测未见——列入 t18 探针臂，见 `HARDENING-PLAN-REVIEW-ANALYSIS` R11）；
   - fill 与 fixed run 释放是 check-then-copy、非原子——`cudaHostUnregister` 撞在飞拷贝时它是唯一兜底；
   - 情形 C 的"接受"是实测性质（Q1），驱动收回时 bounce 就是降级垫。
2. **不还原 canary 采样点**（不回到"fixed run 末页"）。那会让 L0 健康检查重新依赖"跨界被接受"这条未文档化性质；驱动一变 → L0 误判 → 降到 L1/L2，prefill 从 99–101% 直接跌到 pageable 速度，误判代价远大于收益。

**镜像树提醒**：`sycl/` 是 P4 之前的旧镜像（无 tier 几何、无 InvalidValue 分支），本次不波及；若日后 sycl 采用 tiered arena，`64ff01e` + `beb9deb` + `c976960` 三个修复需一并 backport，否则必踩同坑。

---

## 5. 请专家回答的问题

1. **cudaMemcpy(Async) HtoD 的源与 `cudaHostRegister` 区的关系，有无文档化语义？** 具体三条（全部本机 610.57.04 + CUDA 13.0 实测）：
   (a) 源跨 registered | **未注册页** | registered → **接受**；
   (b) 源跨两段**相邻**注册 → `invalid argument`；
   (c) 源为已 mmap 但**未注册**的匿名区，内存压力高时被拒，而 fresh pageable buffer 可过（驱动内部 staging）。
   这是实现现状还是有契约？哪些驱动版本会不同？有无 `cudaMemcpyBatchAsync`/新 API 对 (b) 的处理？
2. **注册段数上限（实测 ~5300）有无文档或查询接口？** 按层注册（48 段）离上限远，但若层数/分段策略变化，需要知道边界是否会随驱动挪。
3. **`cudaHostUnregister` 与在飞 DMA 的语义**：它阻塞到拷贝完成吗？有文档吗？我们现在靠 bounce 兜这个竞态，如果有正式保证可以删兜底。
4. **这个模式有没有更正统的做法？** 需求：46.84 GiB arena 在系统 RAM，GPU 零拷贝按段读，其中固定半区服务中整段**释放**（归还 ~11.19 GiB 可回收性）且主机副本保留。VMM（`cuMemCreate/cuMemMap`）是否适用？代价/前提？
5. **Xid 31 FAULT_PTE 能否作为更早的故障信号？** 现在 illegal device read 的表现是 verify 20 s 超时 + dmesg Xid；有无办法（不付出 compute-sanitizer 的代价）让这类越界读当场 fail-fast？
   *（10-08 补核：引擎**已有** never-rang fail-fast——`verify.cpp:1458-1466/1996-2004` 每 1024 spin ~2 ms 查一次 `cudaStreamQuery`，流报错立即退出；"kernel 已 fault 时 20 s 才死"不再成立。剩问仅：NVML Xid watcher 是否值得加。）*
6. **HIP/AMD 侧**：同样的注册几何在 HIP 上是否等价（`expert_cache.cpp` 的 HIP 分支一直无条件经 staging）？port 时 §1 表格是否成立？

---

## 6. 加固落地后的验证计划

1. `tools/repro/t16`、`t17` 编译重跑：A/C/D OK、B 仍 `invalid argument`（驱动未变则应不变）。
2. 100K→160K 序列（`tools/repro/reg-sequence.txt`）×3：3/3，160K ≈39–40 s，零 verify 超时。
3. **新增 bounce 日志计数 == 0**（H1 的核心判据）；`fetch_dma` 失败行 == 0；dmesg 无 Xid 31。
4. 启动不变量：11.19 GiB 归还、`canary passed (L0)`、prefill 99–101%。

## 7. 复现与证据索引

| 材料 | 位置 |
|---|---|
| 最小复现 | `tools/repro/t16.cu`（同步、相邻注册）、`tools/repro/t17.cu`（异步、A–D 四情形） |
| gap 窗口实验 | `tools/repro/gapwin.sh` + `gapwin-results.txt` + `gapwin-server.log` |
| 判别实验 | `tools/repro/discrim.sh` + `discrim-results.txt` |
| verify 追踪 | `tools/repro/verifytrace.sh` + `verifytrace-results.txt` |
| 回归序列 | `tools/repro/reg-sequence.txt`、`reglog-run1/2.txt`、`cuda-log.txt` |
| 取证记录 | `tools/repro/optionb-forensic-results.txt`、`docs/HANDOFF-VERIFY-TIMEOUT-2026-10-07.md`（#267 现场时间线） |
| 全程记录 | `docs/PROJECT-REVIEW-2026-10-07.md`、`docs/EXPERT_SPLIT_PLAN.md` §9.6 |

**操作提示（铁律）**：本助手会话跑在 8088 本地 LLM 上——停/拉 LLM 必须同一脚本闭环、停前先征得同意；`ninfer` 容器与 `strata.service`（systemd）互斥不共存；窗口脚本用 `kill -9` 兜底、拒绝在孤儿显存上起 LLM。

---

## 8. 决策点汇总（给专家的勾选表）

| 决定 | 我们的默认 | 什么答案会改变它 |
|---|---|---|
| 保留 bounce + 加日志 | ✅ 做 | Q1(a) 有文档保证 + Q3 有正式保证 → 可考虑删 |
| canary 采样点 | 不动 | — |
| 别名规则 `bo >= ns` | 保留 | 无（根因） |
| 迁移到 VMM | 不做 | Q4 专家明确背书且收益 > 工作量 |
| sycl backport | 暂缓 | sycl 采用 tiered arena 时 |

---

## 9. 假设登记表（10-08，应专家 §6 要求；每行＝一条承重假设 + 探针 + 退路）

| 假设 | 证据 | 若不成立的后果 | 探针 | 退路 |
|---|---|---|---|---|
| (a) 源跨 registered\|gap\|registered 被接受 | t17 C（610.57.04） | 骑边界拷贝失败 | t18 矩阵 + 每次驱动升级后重跑 | bounce（T2 后带日志）；T5 后该形态不再出现 |
| (b) 跨相邻两 Mapped 注册被拒 | t16/t17 B | 几何 bug 被误当能过 | t18（含**仅 Portable** 臂，决定 R12/gap 简化） | T5 对齐填充 = 构造性消除 |
| (c) 未注册区 HtoD 在压力下被拒 | 9ad8c44 现场观察，**混杂未隔离** | 设计前提之一不成立 | t18 隔离臂（全不注册+压力） | 无承重：bounce 只是纵深防御 |
| 别名只能指 run 内部 | #267（t17 复现） | Xid 31/超时 | T3 启动校验（显式含尾部包含） | 无别名走 CPU 路；fail-fast 已在 verify 两处 |
| DONTNEED 只及内部、边页保留 | 代码 `:3015-3021` + 内核 pinned/匿名语义 | 相邻 blob 被清 | T3 边界 blob 校验和 | 已构造保证；T5 后共享页消失 |
| `cudaHostUnregister` 不等待在飞 DMA | 文档未承诺（待 NVIDIA） | 注销撞拷贝 | T2 bounce 计数 + 分类 | 现行流程释放发生在 serving 前（无窗口）；未来动态释放才需状态机 |
| 注册段数上限 ~5300（上下文相关） | 9ad8c44 实测 | 注册失败 | 启动日志打印 runs/bytes（T3） | 每层 2 段=96，余量大；再降可按层合并 |

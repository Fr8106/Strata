# 零拷贝注册边界故障类：加固方案审核意见

- 被审文档：`HARDENING-HANDOFF-2026-10-08.md`（修复 `64ff01e` 已落地，本次审核对象是 §3 的三项加固、§4 的"不做"清单、§5 的六个问题）
- 审核日期：2026-10-08
- 方式：纯文档审核，**未读代码、未跑实验**。行号与几何细节均取自交接文档；凡依赖代码实际行为的判断标"待核实"，汇总在 §8。
- 关于驱动语义：我手头没有能证明这些行为被文档保证的依据，下文凡涉及"是否有契约"，一律按"未保证，按实现现状对待"处理，并建议向 NVIDIA 提问（§5）。

---

## 0. 结论摘要

**总体评价：方向正确，结论可采纳，但加固偏被动，建议升级。**

`64ff01e` 的根因修复（别名只发给完全落在注册 run 内的 blob）是对的，t16/t17 把问题隔离得很干净，"两处原方案被撤回"也体现了自我审核的质量。三项加固（H1 日志、H2 脚本探针、H3 不变量表述）都可以做，但它们本质上是**"出事后能看见"**。同类故障已出现 3 次、落在 4 处代码，说明靠"每处各自小心"不可持续。我建议把重点从"看见"转向"**构造性消除 + 启动期确定性自检**"：

1. **用 4 KiB 对齐填充消除跨界 blob**（§4-R1）。每个 run 起止都落在页边界，则不存在骑边界的 blob，也就不再依赖"跨 gap 被接受"、"bounce 可过"、"每层 ≤1 个专家走 CPU 路"这三条未文档化的性质。填充总量上限约 96 × 4 KiB ≈ 384 KiB。
2. **启动期做确定性几何校验 + 全量 blob 扫描**（§4-R2）。24576 个 blob 全部逐个校验（对齐、包含关系、别名越界），可选地各发一次真实 H2D 和一次别名读。这样不再靠"随机 verify 窗口碰到才发现"，#267 这类问题会在启动时当场暴露。
3. **别名规则只检查了起点**（§4-R3）。`bo >= ns` 只防负偏移，**尾部是否越出注册 run 末端**需要确认，否则同类故障会换一个方向再来。
4. **fixed 区释放的取整方向与时序**（§4-R4、R5）。释放范围必须是注册范围的子集（两端都向内取整），且释放前必须有明确的屏障。否则可能静默清零相邻 non-fixed blob，或让 bounce 读到零页。**这类错误不会报错，只会让输出质量悄悄变差。**
5. **Q5 有现成答案**（§4-R8）：在 verify 自旋循环里穿插 `cudaStreamQuery`，或用 NVML 订阅 Xid 事件，即可把"20 s 超时"变成"毫秒级 fail-fast"。

另有两点需要在 H1 的设计里修正：日志的"必须为 0"判据会混入压力类触发（§2-H1），以及验收样本量对"残留概率"没有说服力（§4-R9）。

---

## 1. 做得好的地方

- **根因而非症状**：修的是别名负偏移这个真正的越界读，而不是放宽超时（对比 `HANDOFF-VERIFY-TIMEOUT` 里提出的"verify 自适应放宽/跳过"方案，那会把真实的显存故障掩盖掉）。
- **最小复现完备**：t16/t17 的 A/B/C/D 四情形把"单 run / 跨相邻注册 / 带 gap / bounce"拆得很清楚，是可以直接发给 NVIDIA 的材料。
- **可见化补齐**：`fetch_dma` 失败不再静默、死亡路径统一 `release_gpu_waits`，吸取了"故障远离现场"的教训。
- **自我审核**：撤回"删 bounce"和"还原 canary 采样点"两项，理由写得具体（见 §3 我基本同意）。
- **镜像树提醒**：`sycl/` 需要 backport 三个修复，这类"别处会再踩一次"的提醒很有价值。
- **验收有对照**：5/5 必死序列 → 3/3 通过，并附启动不变量（11.19 GiB 归还、prefill 99–101%）。

---

## 2. 对三项加固的审核

### H1 bounce 重试加日志 —— 同意，需要修改设计

**应当做**，成本低，且正对症。但原设计有四处需要调整：

1. **"日志次数必须为 0"的判据会误报。** 交接文档自己在 §4-1 说明 bounce 还覆盖"内存压力下从未注册区拷贝被拒"和"fill 与 fixed 释放的竞态"。这两类触发在**几何完全正确**时也可能出现，所以"出现次数 > 0 ⇒ 几何回退"不成立。久而久之告警会被习惯性忽略。
   **建议**：日志里带上**分类**。引擎自己持有 run 表，写一个 `classify(src, len)`，返回 `InsideRun / SpansGapOK / SpansAdjacentRuns / Unregistered / Released`。然后：
   - 分类为 `InsideRun` 或 `SpansGapOK` 却被拒 ⇒ **驱动行为变了或压力类**（高优先报警）；
   - 分类为 `SpansAdjacentRuns` ⇒ **几何 bug**（最高优先）；
   - 分类为 `Unregistered`/`Released` ⇒ 生命周期问题（见 R5）。
   验收判据改为"**几何类触发 == 0**"，压力类单独计数、单独阈值。
2. **限流与汇总。** 如果驱动行为改变，profile 预填的 24576 次拷贝可能全部 bounce，会刷屏。建议：前 N（如 5）次逐条打印，之后只累加计数，预填结束和服务运行中定期打印汇总（"bounced K of N, by class: …"），并暴露为统计项。
3. **清 last-error。** 重试成功后调用 `cudaGetLastError()` 清除那次 `invalid argument`。这类非 sticky 错误仍会留在"最后一次错误"槽里，会被后面不相干的探针当成"fresh error"——这正是之前排障时反复被误导的现象。
4. **queued 变体的暂存缓冲生命周期。** `cudaMemcpyAsync` 重试经 pinned staging 时，暂存块必须保持到该流上的拷贝完成（事件）后才能复用。请核实 `:671-677` 的重试没有复用在飞的 staging 块。

### H2 几何探针走脚本 —— 同意，建议扩展用例

脚本化 t17 并在每次驱动升级后跑一遍，是对的。建议再做两件事：

1. **扩展用例矩阵**（t17 目前是 A–D 四情形）：
   - 拷贝大小：4 KiB / 64 KiB / 2,176,000 B / 2.66 MB（驱动内部对小拷贝和大拷贝可能走不同路径）；
   - 起点页内偏移：0 / 1 / 2048 / 4095；
   - **恰好等于 run 末端/起点**、**越界 1 字节**、**越界 1 页**三种边界；
   - 注册标志：`Portable|Mapped` 与**仅 Portable（不带 Mapped）**。我怀疑情形 B 的"相邻被拒"与 `Mapped` 标志有关（Mapped 注册会被驱动当成设备映射的整体）。若仅 Portable 的相邻注册可过，则 fixed run **根本不需要 Mapped**（见 R12）。
2. **除了脚本，也在引擎启动时做一次"特性探针"。** 用两小块私有缓冲（不是 arena）测 B/C 两种形态，约 1 ms，结果写进启动日志并决定运行策略（例如 C 被拒则对所有骑边界拷贝强制 bounce）。它与"生产 canary 保持不动"并不冲突：canary 检查的是 arena 健康，特性探针检查的是驱动语义，二者分离，不会让 L0 因驱动语义变化而误降级。

### H3 修正不变量表述 —— 同意，但应该升级为代码断言

对不变量的修正是正确的：`floor4k == ceil4k` 时两段紧邻、gap 为 0，此时安全是因为没有任何 blob 骑边界。可成立的表述是"每个 blob 要么完全在其注册 run 内（有设备别名），要么无别名走 CPU 路"。

**不建议停在"文档/注释"层。** 这个不变量只需要一次 24576 次循环（毫秒级）就能在启动期全量验证。写成断言后，#267 这类问题会在启动时确定性暴露，而不是在运行中以约 4/42 的概率随机命中。见 R2。

---

## 3. 对"不做"清单的审核

| 决定 | 我的意见 |
|---|---|
| 不删 bounce 兜底 | **同意**，但论据要调整。"驱动收回 C 时 bounce 是降级垫"成立；"`9ad8c44` 实测过未注册区被拒"这条**证据是混杂的**（见 R11），不宜作为主要理由。更扎实的理由是：兜底成本为零、且 R1 做完之后它只是纵深防御。 |
| 不还原 canary 采样点 | **同意**。canary 健康检查不应依赖未文档化的"跨界被接受"。 |
| 不迁移到 VMM | **同意**。代价大、收益未证。见 §5-Q4，但有更便宜的结构改进（R1、R12）。 |
| sycl 暂缓 | **同意**，并建议在 `sycl/` 目录放一个醒目的 `README` 或 CI 标记，写明"采用 tiered arena 前必须 backport `64ff01e`/`beb9deb`/`c976960`"，避免依赖人的记忆。 |

---

## 4. 方案之外的风险与建议

### R1（高）用对齐填充构造性消除跨界 blob

**现状**：靠"共享页不注册 + 别名只发给完全在 run 内的 blob + bounce 兜底"三层来处理骑边界的 blob（每层约 1 个，共约 48/24576）。三层都依赖未文档化的驱动行为（Q1 的 a/b）或需要额外代码路径。

**建议**：在构建 arena 布局时，让**每个 run 的起点和终点都落在 4 KiB 边界**（run 之间插入 ≤ 4095 字节的填充）。则：

- 不存在共享页，不存在骑边界的 blob，`bo >= ns` 条件对所有 blob 恒真；
- 情形 B（跨相邻注册）与情形 C（跨 gap）都不会发生，不再依赖任何一条驱动行为；
- 不再有"≤1 个专家被降级到 CPU 路"（见 R6）。
- 额外代价：最多约 96 个 run × 4 KiB ≈ 384 KiB，相对 46.84 GiB 可忽略。

**前提（待核实）**：arena 是装载时在内存里按偏移表构建的（`experts.bin`/GGUF 的文件布局不需要同样的填充）。若 `experts.bin` 的布局是直接按 arena 顺序映射的，则需要同步调整。

该方案做完后，现有的 `floor4k/ceil4k` 取整、`bo >= ns` 分支和 bounce 都可以保留为纵深防御，但**不再是承重结构**。

### R2（高）启动期几何校验 + 全量 blob 扫描

**问题**：现有验证是概率性的：#267 修复前约 4/42 个 verify 窗口命中，几何错误只在"路由到该专家"时才暴露。5/5 → 3/3 的结果说明了根因被修掉，但并不能说明**没有别的 blob 还有同类问题**。

**建议分两档**：

1. **几何校验（默认开启，毫秒级）**——遍历全部 24576 个 blob 和 96 个 run：
   - 每个注册 run：起点、终点 4 KiB 对齐；run 之间不重叠；
   - 每个 blob：要么满足 `run_start <= bo && be <= run_end`（有别名），要么标记为无别名；
   - 每个别名指针：位于其设备映射区间 `[d, d + run_size)` 内（即 `blob_dev_ - d + size <= run_size`）；
   - 打印一行汇总：`geometry: runs=96 registered=… noalias=… validated=24576`。
   违反即启动失败或降级，**不要静默继续**。
2. **全量 blob 扫描（可选，几秒）**——对每个 blob 各发一次真实 H2D 到小暂存缓冲，并对有别名的 blob 发一次真实的别名读 kernel，核对校验和。按 46.84 GiB 以 ~25 GB/s 估算约 2–5 s。可以在 CI、每次驱动升级后、`STRATA_SELFTEST=full` 时跑；有别名读越界则当场暴露为 Xid，进程失败退出，这在启动期是想要的行为。

同时给**布局构建器写无 GPU 的单元测试**：随机 blob 大小序列 × 随机 `nfix` × 随机层数，断言上述不变量。它可以在任何机器上跑，覆盖面远大于 3 次序列回放。

### R3（高）别名规则是否也检查了尾部？

交接文档写的是"只有完全落在注册 run 内的 blob 才发设备别名"，但引用的条件是 `bo >= ns`（只检查起点）。#267 是起点偏到注册区之前；对称的故障是**blob 的终点越过注册 run 的末端**（run 末端向内取整到页边界时，末尾 blob 的尾部可能在未注册页里）。请核实 `expert_source.cpp:3154-3165` 是否同时检查 `be <= run_end`（或等价条件）。若没有，这是同一类故障的另一半。R2 的校验会自动覆盖它。

### R4（高）fixed 区释放的取整方向，且要检查"所有"run 边界

1. **释放范围必须是注册范围的子集，两端都向内取整。** fixed run 的**起点**同样可能与上一层 non-fixed 尾部 blob 共页，交接文档只讨论了 fixed 末端/non-fixed 起点这一侧。
2. **匿名内存上 `MADV_DONTNEED` 会清零内容。** 若释放范围向外取整，会把共享页清零，相邻 non-fixed blob 的开头部分被静默破坏。之后该专家被换入 VRAM（adapt 换入、prompt loan 恢复）就是**错误权重**，不会报错，只会让输出质量变差；而 "prefill 99–101%"、"Option B 启动不变量完好"都检测不到。
3. **建议**：释放后立即对每个 run 边界附近的首/末 blob 做**主机侧校验和复核**（与装载时记录的校验和比较，约 96 个 blob，毫秒级）；R1 的对齐填充会让这个风险整体消失。
4. 另外请确认**层与层之间**（non-fixed(l) → fixed(l+1)）以及每个 run 的**起点**取整方向同样被处理，不止 fixed 末端。

### R5（高）fixed 区释放的生命周期与屏障

交接文档承认"fill 与 fixed 释放是 check-then-copy、非原子"，并把 bounce 当作唯一兜底。这里有两个隐患：

- bounce 是 **CPU memcpy 经 pinned staging**。若此时 fixed 区已被 `DONTNEED`，memcpy 读到的是**零页**，再 H2D 到槽里——**静默坏数据**，而不是报错。
- 依赖"`cudaHostUnregister` 是否等待在飞 DMA"（Q3）是依赖未文档化语义。

**建议改成显式状态机**，不再依赖驱动对在飞拷贝的处理：

```
Registered → (drain queued fills) → (event/stream sync on all streams touching fixed run)
          → Releasing (原子标志，新 fill 命中 fixed 区直接拒绝并报错)
          → cudaHostUnregister → madvise(DONTNEED) + mprotect(PROT_NONE)
          → Released   (任何命中 Released 的 fill/alias 都 assert/fail-loud)
```

要点：释放后用 `mprotect(PROT_NONE)` 保留虚拟地址，主机侧的任何误读都会**当场 SIGSEGV**，而不是读到零；GPU 侧误读仍是 Xid 31，因此还需要在主机侧发 kernel 前检查别名的状态位（决定哪个专家用哪个指针本来就在主机侧完成，几乎免费）。这是把"静默坏数据"类缺陷转成"当场失败"类缺陷。

### R6（中）被降级到 CPU 路的专家可能恰是最热的非驻留专家

按 tier 有序排布，若 non-fixed run 内部也按热度排序，则"每层第一个 non-fixed blob"恰是**该层最热的非驻留专家**。每层强制它走 CPU 路，意味着它每次被路由到都不能零拷贝，可能影响 decode。交接文档只给了 prefill 99–101%，没有 decode tok/s 与"强制 CPU 路次数"。

- 请补测 decode tok/s（修复前后对比）和 `noalias` 专家的路由命中次数；
- R1 做完后此问题自然消失；若暂时不做 R1，可以在布局时让每层第一个 non-fixed blob 选用**最冷**的专家（顺序微调，不影响其他逻辑）。
- **用故障注入覆盖 `pinned()==false` 路径**：加开关 `STRATA_FORCE_NOALIAS_PCT=N`，把 N% 的 blob 强制标记为无别名，跑完整回归并与基线逐 token 比较。目前该路径每层只有 1 个专家在用，覆盖率很低；所有消费者（verify、prefill 零拷贝、loan、adapt）是否都遵守 `pinned()` 需要被真实压一遍。

### R7（中）把 GPU 面向 host 的访问集中到一个封装

故障类 3 次、4 处代码（canary、fill blocking、fill queued、别名/`fetch_dma`），说明每个调用点各自判断边界不可持续。建议新增一个小封装：

```
HostRangeTable::classify(src, len) → {InsideRun, SpansGapOK, SpansAdjacent, Unregistered, Released}
h2d_from_arena(dst, src, len, stream, ctx)   // 内部 classify → 直接拷贝 / bounce，统一日志、统一计数
alias_for(blob)                              // 唯一产生设备别名的地方，内含包含关系检查
```

此后新增调用点只能走封装，**代码审查只需要盯封装**。H1 的日志也自然落在封装里，而不是散在两处 `if (e == cudaErrorInvalidValue)`。

### R8（高）Q5 的答案：fail-fast 越界读

目前越界读的表现是"flag 永不置位 → 20 s 超时"。因为 GPU 侧 kernel 已经 fault，**流上的 query 通常会立刻返回错误**。建议：

- 在 `Verifier::run` 的自旋等待循环里，每隔若干微秒穿插一次 `cudaStreamQuery(verify_stream)`。返回 `cudaErrorNotReady` 继续等，返回其它错误码则**立即**记录并终止（毫秒级而不是 20 s）。查询开销为微秒级，1 kHz 即可；
- 可选：起一个 watcher 线程，用 NVML 订阅 Xid 严重错误事件（`nvmlEventTypeXidCriticalError`，待核实当前 NVML 版本的可用性），事件驱动，不占主路径；
- 开发期另用 `compute-sanitizer` 跑 t17 与小型合成用例，而不是整引擎。

这既回答了 Q5，也让"死亡现场"离故障点更近。

### R9（中）验收的统计力度

修复前每个 verify 窗口约 4/42 ≈ 9.5% 命中，所以"5/5 失败 → 3/3 通过"对**根因已被消除**很有说服力（概率性的 9.5% × 数百个窗口）。但对**残留概率**几乎没有信息量（3/3 的 95% 置信上界按"三法则"约为 100%）。

- 把 R2 的确定性校验作为**主要验收**，而不是回放次数；
- 另外跑一次 ≥ 30 个序列或一次 ≥ 8 h 长跑作为浸泡（可夜间进行），记录 verify 超时、`fetch_dma` 失败、bounce 分类计数、dmesg Xid；
- 验收里加 **decode tok/s**，不只 prefill。

### R10（中）teardown 顺序

故障现场混淆（"Xid 31 是原因还是后果"）的一个来源是：引擎死亡时先拆映射而 GPU 图仍在跑，会产生**次生 Xid**。建议死亡/退出路径：先 `release_gpu_waits`，再带超时地同步设备；**同步失败（GPU 已卡死）就不要去 unregister/munmap**（进程马上退出，由内核回收），避免制造次生 fault 污染取证。

### R11（中）Q1(c) 的证据是混杂的

"内存压力下从已 mmap 未注册区拷贝被拒"来自 `9ad8c44` 时代，当时同时存在：4628 段 per-blob 注册、相邻注册、THP、尚未发现的别名越界等多个混杂因素，而且后来的修复（按层注册）是否也顺带消除了这条现象并不清楚。**请在隔离条件下单独复测**（不注册任何东西，只做匿名 mmap + 内存压力 + `cudaMemcpyAsync`）。如果不能复现，就不要把 (c) 写成"驱动事实"，以免后续基于一个未经证实的前提做设计。

### R12（中）fixed run 也许不需要 `Mapped`

fixed 区的专家只需要在启动时一次性拷贝进 VRAM（H2D），**不需要被 GPU 以设备指针别名直接解引用**；别名只服务 non-fixed 区。因此 fixed run 用 `cudaHostRegisterPortable`（不带 `Mapped`）就够：

- 减少 `Mapped` 注册的数量（历史上 4424 个 Mapped 注册耗尽过驱动资源，见 `4255b29`）；
- 如果 H2D 对"相邻的 plain pin"没有 B 情形的拒绝（见 H2 用例矩阵），fixed 区与 non-fixed 区的边界问题也进一步简化；
- fixed 区本来就要释放，没有理由长期占用 Mapped 资源。

### R13（低）后续配置和文档清理

- **配置复核**：`HANDOFF-VERIFY-TIMEOUT` 里的 `--kv-resident 131072`（方案 A）是在"显存紧贴地/KV 流式饱和"的假设下做的止血。真正的根因已经是别名越界，该假设已不成立。请据此重新评估 `--kv-resident`，原来为此挤掉的专家槽（32K 时 11797 槽，131K 时 11199 槽）和 298 MiB 的显存余量可能值得换回，视长上下文的实际需要用数据决定。
- **旧文档标记**：在 `docs/HANDOFF-VERIFY-TIMEOUT-2026-10-07.md` 顶部加"已被 `64ff01e` 取代"，并注明其中"Xid 31 是后果""KV 流式饱和""verify 自适应放宽"的判断已被证伪，避免后来者沿用。其中"Xid 31 是后果"恰恰是反的：这次的因果顺序是别名越界读 → Xid 31 → flag 永不置位 → 超时。
- **驱动版本策略**：锁定驱动版本（如 `apt-mark hold`），升级前先跑 H2 探针；记录在文档里。
- **可观测性**：启动日志加一行几何汇总；运行期统计暴露 `bounce_count{class}`、`noalias_blobs`、`fixed_state`、`fetch_dma_failures`。

---

## 5. 对 §5 六个问题的回答与建议

以下是我的判断，不是权威答案；凡涉及驱动契约，建议发给 NVIDIA（开发者论坛）确认。t16/t17 现在是真正意义上的最小复现，**这次可以发了**（之前"驱动 bug"的结论缺少最小复现，现在有）。

| # | 我的看法 |
|---|---|
| Q1 拷贝源与注册区的关系 | 我不知道有文档化的保证。(a) 跨"注册\|未注册\|注册"被接受、(b) 跨两段相邻注册被拒，从表现看像是驱动按"整个源区间是否落在**一个**注册对象内"决定走哪条路径：落在内 → pinned/mapped 路径；完全不在 → pageable 路径；部分在内且分属两个对象 → 拒绝。这是推测，且可能受 `Mapped` 标志影响（见 H2）。**按"实现现状"设计，不依赖它**，即 R1。(c) 的证据见 R11。 |
| Q2 注册段数上限 | 我不知道有查询接口。此前的数据自相矛盾（3900/4628/5300/8192），说明它并不是单纯的段数上限，更可能与上下文状态或总映射量共享预算。96 段离任何已观测到的上限都很远；建议在启动日志里打印注册段数与总字节，并在 CI 里用探针测"注册 N 段是否成功"，驱动升级时能看到趋势。 |
| Q3 `cudaHostUnregister` 与在飞 DMA | 不要依赖。按我所知文档没有承诺它会等待在飞拷贝；标准做法是调用方先对所有可能引用该内存的流/事件做同步再注销。用 R5 的状态机把这条依赖显式化，bounce 就不再承担这个职责。 |
| Q4 更正统的做法 / VMM | VMM（`cuMemCreate/cuMemMap`）的主要卖点是**可按块创建/释放物理内存并映射**。较新的 CUDA 里有 host 物理分配类型，但我无法在不查文档的情况下确认它对"零拷贝别名 + 部分释放"的语义和限制，需要小实验确认。**先不迁移**：R1（对齐填充）+ R5（状态机）+ R12 已经能用很低代价消除当前故障类。若将来要做，也建议先做一个独立小原型验证。 |
| Q5 越界读 fail-fast | 见 R8：`cudaStreamQuery` 穿插在自旋等待里、NVML Xid 事件订阅、开发期 `compute-sanitizer` 跑小型合成用例。 |
| Q6 HIP/AMD | 我没有可靠依据判断等价。建议把 t17 hipify 后在目标 AMD 机器上重跑一遍，**§1 表格里的每一行在 HIP 上都按"未验证"处理**；`expert_cache.cpp` HIP 分支"一直无条件经 staging"本身是安全的，port 时优先保持这一点，R1 的对齐方案对 HIP 同样有益（不依赖驱动对边界的处理）。 |

---

## 6. 假设登记表（建议加入仓库文档）

把所有依赖的驱动/内核行为集中登记，每一项配"探针 + 失败后的退路"，驱动升级前后只需要看这张表。

| 假设 | 证据 | 若不成立的后果 | 检测 | 退路 |
|---|---|---|---|---|
| 源跨 registered\|gap\|registered 被接受（C） | t17 C | 骑边界拷贝失败 | H2 脚本 + 启动特性探针 | bounce；R1 后不再出现 |
| 跨相邻注册被拒（B）——即几何必须避免 | t16/t17 B | 几何 bug 被误当作"能过" | 脚本 + 分类日志 | R1 对齐填充 |
| 别名指针只能指向注册 run 内部 | #267 | Xid 31 / 超时 | R2 启动校验 + R8 fail-fast | 无别名走 CPU 路 |
| 对 pinned 页 `madvise(DONTNEED)` 会清零内容 | 内核行为 | 释放范围外扩 ⇒ 静默坏数据 | 释放后边界 blob 校验和 | 两端向内取整；R1 |
| `cudaHostUnregister` 不保证等待在飞 DMA | 文档未承诺（待核实） | 注销撞在飞拷贝 | 无（靠设计） | R5 状态机 + 显式同步 |
| 注册段数上限（未知，实测 ~5300 附近且与上下文有关） | 历史实测 | 注册失败 | 启动日志打印段数/字节 | 减少段数 |

---

## 7. 建议的行动清单

| 优先级 | 事项 | 估算 | 说明 |
|---|---|---|---|
| P0 | R3 核实别名尾部检查；R4 核实释放取整方向与全部 run 边界 | 数小时 | 纯读代码，若发现缺陷则是同类故障的另一半 |
| P0 | R2 启动几何校验 + 布局构建器单元测试 | ~1 天 | 取代 H3 的"仅文档"；确定性验证 |
| P1 | R1 对齐填充 | 0.5–1 天 | 构造性消除跨界；之后降低对 bounce/gap 的依赖 |
| P1 | H1（按 §2 修改：分类、限流、清 last-error、staging 生命周期） | 数小时 | 封装到 R7 的 `h2d_from_arena` 更佳 |
| P1 | R8 `cudaStreamQuery` fail-fast | 数小时 | 回答 Q5 |
| P1 | R5 释放状态机 + `mprotect(PROT_NONE)` | ~1 天 | 消除静默坏数据与对 Q3 的依赖 |
| P2 | H2 脚本探针 + 用例矩阵 + 启动特性探针 | ~0.5 天 | 含仅 Portable 的 B 用例 |
| P2 | R6 `STRATA_FORCE_NOALIAS_PCT` 故障注入 + decode 对比 | 数小时 | 压 `pinned()==false` 路径 |
| P2 | R9 浸泡（≥30 序列或 ≥8 h 夜间） | 夜间 | 看残留概率 |
| P2 | R12 fixed run 改 Portable-only（视 H2 结果） | 数小时 | 减少 Mapped 资源占用 |
| P3 | R7 封装重构；R10 teardown 顺序；R13 文档/配置清理 | 1–2 天 | 长期维护成本 |
| P3 | 向 NVIDIA 提问（带 t17 最小复现与 Q1 的三条表现） | 数小时 | 确认契约 |

**验收口径（修订）**：几何类 bounce == 0、`fetch_dma` 失败 == 0、dmesg 无 Xid 31、启动几何汇总一行、decode tok/s 无回退、释放后边界 blob 校验和一致、浸泡无超时。

---

## 8. 待核实问题清单

1. `expert_source.cpp:3154-3165` 的别名条件是否同时检查了 blob 终点不越过注册 run 末端？
2. 释放（`release_fixed_tier` 一类函数）使用的范围是否与注册范围一致？两端取整方向？是否覆盖 non-fixed(l) → fixed(l+1) 以及 fixed run 起点？
3. 每层的实际布局是 `[fixed][non-fixed]` 逐层连续，还是 fixed/non-fixed 各自成一整块？"96 段"如何构成？
4. 骑边界 blob 每层是 1 个还是最多 2 个（fixed 末尾 blob 尾部、non-fixed 首个 blob 头部可能都在共享页）？"~48/24576"是怎么统计的？
5. 每层第一个 non-fixed blob 是否恰为最热的非驻留专家？
6. 所有 `pinned()==false` 的消费者（verify、prefill 零拷贝、loan、adapt）是否都有 CPU 路 fallback？
7. bounce 的 queued 变体使用的 staging 块何时回收？
8. `experts.bin` 的布局是否与 arena 布局耦合，从而影响 R1 的填充？
9. 引擎死亡/退出路径中，unregister/munmap 与 GPU 是否同步？
10. t17 使用的注册标志是 `Portable|Mapped` 吗？仅 Portable 下 B 的结果？

---

## 9. 附：参考片段

**启动几何校验（示意）**

```cpp
bool verify_geometry(const Layout& L) {
  size_t bad = 0, noalias = 0;
  for (const Run& r : L.runs) {
    bad += (r.reg_begin % 4096) || (r.reg_end % 4096) || r.reg_begin > r.reg_end;
  }
  for (size_t i = 1; i < L.runs.size(); ++i)
    bad += L.runs[i].reg_begin < L.runs[i-1].reg_end;          // 重叠
  for (const Blob& b : L.blobs) {
    const Run& r = L.run_of(b);
    bool inside = r.reg_begin <= b.off && b.off + b.size <= r.reg_end;
    if (!inside) { ++noalias; bad += b.has_alias; continue; }  // 无别名的不得有别名
    bad += !(b.has_alias);                                     // (或按策略允许缺省)
    bad += (b.dev_alias < r.dev_base) || (b.dev_alias + b.size > r.dev_base + (r.reg_end - r.reg_begin));
  }
  log("geometry: runs=%zu noalias=%zu validated=%zu bad=%zu", L.runs.size(), noalias, L.blobs.size(), bad);
  return bad == 0;
}
```

**fail-fast 自旋（示意）**

```cpp
for (uint64_t spin = 0; !flag_ready(); ++spin) {
  if ((spin & 0x3ff) == 0) {                       // 每 ~1k 次查询一次
    cudaError_t e = cudaStreamQuery(verify_stream);
    if (e != cudaSuccess && e != cudaErrorNotReady) return fail_fast(e);  // 越界读 → 毫秒级暴露
  }
  if (now() > deadline) return timeout();
}
```

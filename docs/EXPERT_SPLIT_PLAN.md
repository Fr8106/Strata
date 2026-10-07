# 专家缓存 50/50 固定/自适应分层改造计划（魔改）

状态：计划（未实施）。创建：2026-10-07。目标机型：本机（Linux，RTX 5090 32 GB，64 GB RAM，IQ3_S，pack `/home/ai/Strata-data/packs/iq3_s`）。

## 1. 目标

把 VRAM 专家缓存（`--expert-cache auto` → 12045 槽 / 22.87 GiB）拆为：

- **固定区 50%**（前 6022 槽，profile 排名最热的专家）：启动载入后**不再保留 RAM 副本**、服务重启前**不被换出显存**；
- **自适应区 50%**（后 6023 槽）：沿用现有自适应层（`--adapt-every`/`--adapt-swaps`）按热度交换。

热度统计沿用现有 `usage` 机制（verify window 路由计数，每轮 ×`--adapt-decay` 衰减）；profile 保存/重载循环（`--expert-profile-save`，#477）使**重启时固定区自动替换为上一轮排名最靠前的热门专家**。

预期收益（验收口径，修订 #1 + P0 实测修正）：**不可回收内存显著下降**。⚠ 2026-10-07 实测：`cudaHostRegister` 的 46.84 GiB arena **不出现在 `VmPin`/smaps `Pinned`/`VmLck`/`Unevictable` 任何计数器里**（全部实测 ≈0，NVIDIA 锁页不走 `pin_user_pages`）——有效判据是：smaps 里 **46.84 GiB 匿名大映射 → 变为 `experts.bin` 文件映射**、**`AnonPages` 降 ~46.8 GiB**、**压力下 `MemAvailable` 明显抬升**（当前基线 MemAvailable 仅 3.5 GiB）；固定区 source 字节（约 11.4–11.6 GiB，**预期值，P0 验证**——native blob 变长故 50% 槽 ≠ 50% 字节）进一步 `MADV_DONTNEED`（只摘进程 PTE：RSS 降、page cache 保留；要真让页退出 page cache 需 `MADV_PAGEOUT`/`posix_fadvise`，见 P2-11）。口径是"可回收内存增加"，**不是"11.6 GiB RAM 永久不占"**。

固定区的价值假设（可检验，P4 逐项验证）：

- **H-F1 重启冷启动免疫**：重启后 `usage` 从 0 开始（`generate.cpp:7858`，不播种），前几个 adapt 轮所有常驻专家并列"最冷"，victim 退化为最小索引者——固定区保护 top 50% 热门专家不被误换出（无固定区时全槽自适应会发生）
- **H-F2 换入总量下降**：固定区不参与 swap，PCIe/CPU 内存带宽流量降低
- **H-F3 尾延迟稳定**：最热专家不再被换入换出

三条假设若全部不成立，停在 P1+P1.5（全槽自适应），P2 不做。

## 2. 主机软硬件背景（2026-10-07 实测）

| 项 | 值 |
|---|---|
| CPU | AMD Ryzen 9 5900X，12 核 24 线程，**仅 AVX-2（无 AVX-512**，引擎日志确认：expert kernels 跑 AVX-2 路径） |
| 内存 | 62 GiB DDR（64 GB）+ **8 GiB swap**（`/swap.img`，采样时已用 715 MB）；2026-10-07 采样（**引擎未运行**）：used 22 GiB / available 40 GiB |
| 其他服务 | `ninfer-serve`（端口 8080，27B 模型，RSS ~20 GiB，`--host-kv-mib 16384`）——**与 Strata 互斥、不共存**（跑 Strata 时停掉它），不计入本方案的并发内存占用 |
| GPU | NVIDIA GeForce RTX 5090，32607 MiB（32 GB），compute capability 12.0，驱动 610.57.04 |
| 系统 | Ubuntu 24.04.5 LTS，内核 6.8.0-146-generic |
| CUDA | 13.0（`/usr/local/cuda-13.0`，serve 配置 `lib_dirs` 指向其 bin/lib64） |
| 磁盘 | `/dev/nvme1n1p2` 1.9 TB NVMe，`/` 与 `/home` 同分区，**余 596 GB** |
| 模型文件 | `/home/ai/strata-gguf/`：`Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-0000{1,2}-of-00002.gguf`（专家在 GGUF 分片里）+ `mmproj-Qwen3.8-Flash-Next-BF16.gguf`（图像编码器） |
| pack | `/home/ai/Strata-data/packs/iq3_s`（1.5 GB：`dense.bin` 1.5 GB + `native_experts.txt` 指向 GGUF 分片；**无 `experts.bin`**，P1 首次启动会写出 ~46.8 GiB） |
| MTP 草稿头 | `/home/ai/Strata-data/mtp/rt`（~950 MiB VRAM，experts 675 + dense 111） |
| serve | `strata-iq3_s.json`：端口 8088，host 0.0.0.0 + api_key，`--max-context 262144`，`--kv int8`，`--kv-resident 32768`，`--spec 4` |

对方案的关键约束：

- **内存余量**：62 GiB 中 46.84 GiB 是 pinned 专家 arena（不可回收）→ 改造前 available 被压到 ~15 GiB 量级（62 − 46.84 − 引擎开销，**推算值，P0 以引擎运行态快照验证**），KV 缓存（262K 上下文）争抢内存，这是"内存不足"的假设根源；P1 后专家页变为可回收文件缓存页
- **盘余 596 GB** → `experts.bin`（~46.8 GiB）写入无压力
- **单 GPU**（`gpu: 0`）→ 不涉及 `peer_experts`/多卡路径
- **Linux + CUDA** → `STRATA_ARENA_MMAP` 可用（HIP/Windows 不适用，见 §8 风险表）

## 3. 现状依据（本机日志 `strata-iq3_s.log`，engine 0.1.39）

```
strata generate: expert arena read through the file cache (buffered (not Windows))
strata generate: expert arena: cudaHostRegister PORTABLE ok; MAP_HUGETLB unavailable ...
strata generate: loaded 46.84 GiB at 4.11 GiB/s        ← 全量专家进入 pinned RAM arena
strata generate: expert cache 12045 slots, 22.87 GiB of VRAM
strata generate: pre-filled 12045 of 12045 slots from the profile
```

- 配置 `strata-iq3_s.json` 无 `--mmap-experts`/`--resident-experts`/`--adapt-every` → 默认 arena 模式 + 静态驻留（无淘汰、无自适应层）。
- RAM 布局：46.84 GiB 全量专家（pinned，不可回收）+ 显存 22.87 GiB 是其中最热的副本（`ArenaExpertSource::release()` 对非 mmap arena 返回 0，`src/core/expert_source.cpp:2944` → 显存专家的 RAM 副本不释放）。
- pack 无 `experts.bin`（native pack，GGUF 分片），盘上 596 GB 空闲。
- 数字来源标注：本节均为 `[日志]`（采集于 2026-10-06 23:58，见日志 mtime）；"46.84 GiB 为 pinned 锁页"是日志推断（`cudaHostRegister PORTABLE ok`），**`VmPin` 读数待 P0 实测确认**；§2 的 used/available 是引擎未运行时的 `[实测]`。

## 4. 现有机制对照（大部分已存在）

| 需求 | 现有机制 | 位置 |
|---|---|---|
| 固定区 = 排名前半 | profile 预填按排名顺序填槽（排名 i → 槽 i） | `src/program/generate.cpp:3470` |
| 自适应层 victim 选取 | 每层最冷常驻专家；候选 = miss 且 usage ≥ 2.0，需 > victim + 1.5 | `generate.cpp:7915-7935` |
| 释放 RAM 副本 | `ExpertSource::release()`（mmap arena 下 = `MADV_DONTNEED`） | `expert_source.hpp:143`，`expert_source.cpp:2944` |
| 热度排名 + 保存重载 | `--expert-profile-save`（#477）：QUIT + 每 10 分钟原子写回，常驻按热度在前 | `expert_cache.hpp:54-70`，`generate.cpp:5581` |
| 文件后端 arena | `STRATA_ARENA_MMAP=1`（Linux）：arena 只读映射 `experts.bin`，首次启动自动写出 | `expert_source.cpp:2739, 2865`，`docs/DETAILS.md:153` |
| serve 传环境变量 | 配置 `env` 段 → 引擎 env | `serve/server.py:1569` |
| 交换时 RAM 交换缓冲 | `resident_stage_swaps`（resident 模式下生效；arena 模式 `complement_ready()` 为 false 直接跳过） | `generate.cpp:212-241` |

## 5. 阶段计划

**前置：LLM 服务切换脚本** `tools/switch-llm.sh strata|ninfer|status`（2026-10-07 已往返实测通过）。要点：Strata 必须用 `.venv/bin/python` 起且显式 `--port 8088`（server.py 不读 config 的 port）；就绪判据 `/health`；起前检测引擎残留、失败时连引擎子进程一起清理（防孤儿占显存/内存）。

### P0 基线（0.5 天）

记录改造前对照数字（填入 §9 基线表）：

- RAM：引擎日志 `memory:` 行（`generate.cpp:972`）+ `ps -o rss` + `pmap` 拆分（locked / file / anon）+ `/proc/<pid>/smaps_rollup`（Rss / Locked / Anonymous）+ `/proc/meminfo`（MemAvailable / Unevictable / Cached）
- **运行态内存快照**（§2 约束验证）：引擎启动预热后采 `free -m` + smaps_rollup + meminfo，验证 "~15 GiB available" 推算；记录 swap in/out 速率
- **内存计数口径实测**（P0 已完成，推翻审核 #2 的 VmPin 判据）：`VmPin`=0、smaps `Pinned`=0、`VmLck`=0、`Unevictable`=0.05 GiB——`cudaHostRegister` 46.84 GiB 不记入任何锁页计数。有效口径 = smaps 匿名大映射（实测 46.8409 GiB）+ `AnonPages`（52.6 GiB）+ `MemAvailable`（**3.5 GiB**，即内存压力的直接证据）
- 吞吐：tokens/s 日志 + `--stats` 的 `expert tiers` 行 + p95 延迟
- **噪声基线**：同配置重复 5–10 次，得 tok/s 与 p95 的自变异幅度（P4 的 5%/10% 阈值必须在噪声之上才有意义）
- **带压场景**：长 prompt + 262K 上下文 KV 填满 + 吃内存进程（`stress-ng --vm 8G`），测 p95/p99 + major fault——P1 的可回收性收益与尾延迟风险的对照基线
- **KV 主机占用实测**：`--kv int8 --kv-resident 32768` @ 262K 的 host 内存占用（内存压力的另一半，量化后填 §9）
- 命中：`hit_rate`、`cache_hits/admitted/refused`
- I/O：`vmstat` pgmajfault 速率 + SSD read MiB/s（P1 后 mmap 路径的诊断基线）
- **profile 快照**：复制当前 `/home/ai/Strata-data/packs/iq3_s/expert-profile.bin` 为只读快照（P4 各臂统一输入，见 P3）
- **tier 字节**（修订 #2）：profile 前 6022（未来固定区）source 字节求和 vs 全量 46.84 GiB——native blob 变长（max 2.66 MB），50% 槽 ≠ 50% 字节，必须实测，填入 §9 基线表
- **各层固定比例离线分析**（修订 #8，M1）：按当前 profile 算各层 top 6022 命中分布（均值/方差/min/max）；若某层 >90% 或 <10%，P2 实施前调设计。`adapt()` 已有 `vict.empty() → continue`（该层无 victim 跳过，不死循环，`:7931`），只需加计数
- VRAM：`strata serve: ... MiB of VRAM free` 行

### P1 专家层切文件后端（零代码，独立可上线，先拿大头收益）

- `strata-iq3_s.json` 加 `"env": {"STRATA_ARENA_MMAP": "1"}` + **`--pcie-frac 0`**（mmap arena 下 GPU 无映射别名，代码注明 "GPUs then get no mapped alias: run with --pcie-frac 0"，`expert_source.cpp:2733`；显式写 0 避免默认 0.55 失效的歧义，verify window 的 PCIe 份额全部让给 CPU）
- 效果：46.84 GiB 锁页匿名内存 → 可回收文件缓存页；显存专家从不读 RAM，无额外缺页
- 首次启动写 `experts.bin`（~46.8 GiB，约 12 s @4 GiB/s；失败走已有 `NOT writing` 兜底，`expert_source.cpp:2865`）。注意：**写前先把全部 46.84 GiB 读进 pinned arena 再写 `.tmp` + rename**（非流式，`:2840-2877`）——首启内存峰值 = 现状 + page cache 写入，62 GiB 机器有 8 GiB swap 兜底，首启观察内存压力
- 验证：日志 `mapped read-only from ... (not locked, not pinned)`；`pmap` locked 段消失；吞吐 A/B 无回退；**冷启动计时**：重启后（含机器重启后 page cache 冷）"启动 → ready" 耗时 + 首 token 延迟（12045 槽 prefill 全走文件页）；必要时 `MADV_WILLNEED` 预热评估
- **补充（修订 #5，pageable staging 风险）**：mmap arena 不再 `cudaHostRegister`（note 明确 "not locked, not pinned"，`expert_source.cpp:2761`）→ H2D 拷贝走 driver pinned staging。必须测：cold（磁盘）/ hot（page cache）单专家 refill 端到端耗时分布 + H2D 带宽。影响面限于 adapt swap 与 prompt loan 两条 DMA 路径；热路径**仅在 page cache 热时不受影响**（条件陈述）——51% 专家（不在 VRAM 的）由 CPU 池从文件映射页读，内存压力下这些页可被回收 → major fault 直接进 p95/p99。P1 本质是**用尾延迟风险换整体可用内存**
- **门 1（P1 通过标准）**：`VmPin` ~46.8 GiB → ~0；tok/s 回退 < 噪声上限 + 5%；带压场景 p99 回退 ≤ P0 带压基线 +10%；major fault 不持续增长；冷启动在可接受范围（P0 计时对比）。不达标 → 关开关 A 回滚

### P1.5 自适应层隔离 + 全槽对照臂（零代码，新增）

- 配置：A on（mmap）、B=0（无固定区）、C on（`--adapt-every 4 --adapt-swaps 64`）
- 目的：
  - ① 自适应层 + arena/mmap 组合**本机从未跑过**（现配置无 `--adapt-*`；arena 模式下 `resident_stage_swaps` 因 `complement_ready()` 为 false 直接跳过，swap 读路径是 `blob()` → 文件映射页 → driver staging）——P1.5 是这条路径的首次实测
  - ② "全槽自适应"是固定区最天然的对照臂：若 P1.5 的 hit rate / 尾延迟不差于 P2 的 50/50，固定区就没有独立价值
- **门 2（P1.5 通过标准）**：自适应层在 arena+mmap 下稳定（无 CUDA 错误、无 swap 停摆）；且对 P1 有可见收益（drift workload 下 hit rate 提升，或 swap 对 p95 贡献 < Z%——Z 由 P0 噪声基线定）。不达标 → 停在 P1.5（或 P1），P2 降级为"可选"
- **P1.5 实测（2026-10-07）**：同一漂移负载 X×8→Y×12→Z×4（生物→内核→生物，450 tok/请求，thinking off），两臂对比：

  | 臂 | hit rate 中位 X/Y/Z | decode 中位 tok/s X/Y/Z | swap/refill/CUDA 错误 |
  |---|---|---|---|
  | C on（`--adapt-every 4 --adapt-swaps 64`） | 96.5 / 95.7 / 96.8（min 84.7） | 147.9 / 131.1 / 147.1 | 0 |
  | C off（`--adapt-every 0`；关法安全：`generate.cpp:5438` usage 不分配，`:7141` 空判短路） | 54.0 / 80.1 / 53.4 | 78.8 / 105.5 / 73.8 | 0 |

  - 自适应层收益决定性：hit +15.6~+43.4 pp、decode +24%~+100%（off 臂 Y 80% 只是旧 profile 预填恰好命中内核话题）。
  - mmap 下热跟踪正常落盘：C on 会话 QUIT 写出的 `expert-profile-p15.bin` 与 P0 快照 rank 序 **24574/24576 变化**，平均位移 5368 → 热度累积+重排序工作。
  - **serve 侧 adapt lambda（`generate.cpp:5491`）零遥测**：全程无 ADAPT/swap 日志（`STRATA_TRACE_ADAPT` 只影响 CLI lambda `:7898+`）→ P2 加 swap 计数（见 P2 第 13 项）。
  - 注意：P1 会话其实也开着自适应层（默认 4/96，P0 期误判已更正），所以"on vs off"才是有效对照；P4 各臂必须显式写 `--adapt-*`。
- **门 2 判定（2026-10-07）：PASS**——①稳定：两臂含多次重启 0 swap/refill 失败、0 CUDA 错误（日志里 12 处 OOM/ASSERT 为孤儿引擎事故当天残留；今日 6 次启动 vision 全 "warmed up"）；②收益：见上表。含义：自适应层在 mmap 下不是增益而是**必需** → P2 固定区必须与自适应层共存、不得饿死其 swap。

### P2 50/50 拆分（核心代码，~100 行，全在 `src/program/generate.cpp`）

1. 新参数 `--expert-cache-fixed N`（固定区占槽百分比；默认 0 = 现状；本配置设 50）。选项声明 ~`generate.cpp:363`，usage 文本 ~`:672`
2. **统一不变量 `is_fixed_slot(slot)`**（修订 #3）：固定区身份 = `slot < fixed_n` 的唯一判定点（槽是 VRAM arena 中地址稳定的字节区，#533 的设计目标）。所有路径经它判断，不散落索引比较；不引入 `CacheSlot`/`ExpertTier` 数据模型（见 §10）
3. `adapt()` victim 过滤（`:7918-7922`）：victim 候选加 `!is_fixed_slot(r[e])`
4. **断言锁**：swap 落地路径（`adapt`/`apply_pending`）断言 `out` 槽 `!is_fixed_slot(slot)`（debug 构建）——"固定区永不被换出"成为机制而非约定
5. 启动释放：profile 预填 + `verify_slot` 之后（`:3493`）对固定区专家循环 `srcp->release(l, e)`，打印 `fixed tier: N experts, M GiB host residency advised DONTNEED`（口径同 §1，非"RAM 永久释放"）
6. **tier 字节统计日志**（修订 #2）：启动打印 `total/fixed/adaptive slots + source bytes` 四元组，实测值填 §9 基线表
7. **写槽路径审计**（修订 #3，当前代码全部 4 条，无遗漏）：

   | 路径 | 处理 |
   |---|---|
   | `adapt()` swap（`:7948`） | victim 过滤 + 断言 |
   | `--vram-elastic` refill（`:5831`） | 与固定区互斥，启动拒绝 |
   | prompt loan（尾部槽，`:439`） | 结构上只取自适应区；加启动断言 `loan 范围 ∩ 固定区 == ∅` |
   | 启动 profile 预填（`:3470`） | tier 建立点，非替换路径 |

   （"OOM recovery / cache rebuild / future compaction" 当前代码中不存在，不列为审计项）
8. `src/core/expert_cache.cpp`、`src/core/expert_source.cpp` 零改动（第 11 项例外见下）
9. **release 构建运行时守卫**（M7）：断言只在 debug 生效；release 保留廉价比较 + `fixed_evict_attempts` 计数器，命中则 log warning 并跳过该 swap（不 abort）；P4 要求该计数器恒为 0
10. **参数校验**（M8）：N ∈ [0,100] 整数；N=100 且 C on → 自适应区为空，启动拒绝（或警告）；槽数取整规则 = floor；`--expert-cache auto` 槽数随空闲 VRAM 变动 → 固定区边界也随启动变动，启动时记录实际槽数/fixed_n 并入 profile 快照元数据
11. **release 增强选项**（H1，改 `expert_source.cpp`）：`MADV_DONTNEED` 只摘进程 PTE（RSS 降、page cache 保留）；要真让固定区页退出 page cache，`release()` 后加 `MADV_PAGEOUT`（内核 6.8 支持）或 `posix_fadvise(POSIX_FADV_DONTNEED)`——V1 先只做 `MADV_DONTNEED`，PAGEOUT 作为 P4 实测项用 `fincore` 验收，有效再合入（此时 `expert_source.cpp` 非零改动，~10 行）
12. **各层无 victim 计数**：某层全固定区（无自适应常驻）时 `adapt()` 跳过该层（已有 `continue`，`:7931`），遥测计数"无 victim 层"数量，与 P0 离线分析对照
13. **serve 侧 swap 遥测**（P1.5 实测补，原计划遗漏）：serve 的 `adapt` lambda（`:5491`）现在什么都不打印，`STRATA_TRACE_ADAPT` 也只管 CLI（`:7898+`）——没有它，P4 的"swap 对 p95 贡献"与"固定区挡 swap 次数"都不可测。给 serve lambda 加计数器（swap in/out 个数、bytes、无 victim 层数），每 `--adapt-every` 轮打一行

### P3 自适应 + 重载循环（纯配置 + 遥测）

```
--adapt-every 4 --adapt-swaps 64
--adapt-decay 0.7            # 默认值写明；候选阈值 usage ≥ 2.0 / victim + 1.5 的含义依赖它，调参时一起记录
--expert-profile      /home/ai/Strata-data/packs/iq3_s/expert-profile.bin
--expert-profile-save /home/ai/Strata-data/packs/iq3_s/expert-profile.bin
```

- **profile 路径 per-pack 化**（修订 #6）：profile 文件放 pack 目录内，一模型一文件。消除"同 shape 不同权重"跨模型复用残留风险——`read_expert_profile` 已拒绝 shape 失配（`expert_cache.cpp:43`，"profile for a different artifact"），剩下的只有 48×512 同构但量化不同（如 IQ3_S vs UD-IQ4_XS）；per-pack 路径一行配置消掉，不动文件格式
- **profile 输入/输出分离**（M9）：实验模式下各臂从同一只读快照（P0 产物）读入、`--expert-profile-save` 写到各臂独立路径，避免实验互相污染；生产模式保留 `.prev` 轮转（覆盖前留一份上版），异常运行不毁掉唯一好 profile
- **回滚开关 D**（新增，§6）：关 `--expert-profile-save`（profile 只读），防实验把基线 profile 覆盖掉
- 初值 `adapt-every`/`adapt-swaps` 为调参项，P4 扫描后定稿（every ∈ {2,4,8} × swaps ∈ {16,32,64,128}，比 hit rate / SSD read / tok/s / p95，取 Pareto 最优；50/50 比例本身也是实验变量，必要时试 33/67、67/33）
- 重载换血：profile 每 10 分钟 + QUIT 落盘（tmp + rename 原子写已有，`expert_cache.cpp:134`）；下次启动固定区 = 上轮热度 top 50%。注意：固定区是 **session 级策略**（重启换血），不是在线动态重排
- **遥测**（修订 #4，失配诊断）：per-layer 固定/自适应槽分布 + 固定区/自适应区各自 hit rate（`usage` 按 tier 过滤即可，一行统计）。判据：某层固定比例长期严重偏离 50%，或固定区 hit rate << 自适应区 → 固定区与负载失配，触发重启刷新 profile；V2 再议 per-layer quota

### P4 验证（2 天；8 h 夜跑 soak 可并行）

| 检查 | 方法 | 通过标准 |
|---|---|---|
| 正确性 | 改造后首个 adapt 轮之前的 token 流 vs 旧配置（greedy、单请求、无并发） | bit 一致（初始驻留集合相同 = profile 前 12045；该范围内确定性成立） |
| 固定区不被换出 | `assert(!is_fixed_slot(out))` + `fixed_evict_attempts`（release 守卫）+ `STRATA_TRACE_ADAPT=1` 长会话 | 0 断言失败、计数器恒 0；日志中所有 swap 的 out 槽 ∈ 自适应区 |
| RAM 释放 | smaps 映射分类（匿名 vs `experts.bin` 文件映射）+ `AnonPages` + `MemAvailable`（P0 实测：VmPin/Pinned/VmLck/Unevictable 对 cudaHostRegister 全为 0，不可用） | 46.84 GiB 匿名映射变为文件映射；AnonPages 降 ~46.8 GiB；带压下 MemAvailable 由 3.5 GiB 基线明显抬升；`MADV_PAGEOUT` 后 fincore 见页实际退出 page cache |
| **4 臂对比**（M4） | 同一 workload 跑：① 基线（全关）② P1（A）③ P1+全槽自适应（A+C）④ P1+50/50（A+B+C）；各臂 profile 输入 = P0 只读快照（P3 分离模式） | 各臂 hit_rate / tok/s / p95 / SSD read 并列；50/50 臂须对全槽自适应臂在 H-F1/F2/F3 至少一条上有可见收益，否则停在 P1.5 |
| **对抗性 drift**（M5） | workload A 训练 profile → 切到近乎不重叠的 workload B，对比 50/50 vs 全槽自适应 vs 静态 | 量化固定区最大代价；drift 下 50/50 不显著劣化或给出固定比例选择依据 |
| **spec 接受率**（M6） | 记录 `--spec 4` 接受率（MTP 草稿头独立 VRAM 分配不受固定区影响，但数值变化影响接受率） | vs P1 臂无显著下降 |
| refill 代价 | cold/hot 单专家 refill 端到端耗时分布 + H2D 带宽 + major fault 速率 | hot（page cache）refill 延迟可接受；major fault 无持续增长；SSD read 无放大尖峰 |
| 换血循环 | 跑 1 h → diff profile → 重启 | 新固定区 = 上轮热度 top 50% |
| prompt loan | 长 prompt 请求 + 贷还时间测量（借用的专家写回槽 → 首 token 耗时） | 无 SSD 重读尖峰（loan 取尾部 = 自适应区）；还贷后首 token 无明显磁盘读延迟 |
| 吞吐/延迟 | vs P0 基线（含带压场景） | tok/s 回退 < 5% **且** p95 延迟回退 < 10%（双指标，单一 tok/s 不算过） |
| 失配诊断 | 遥测：per-layer 分布 + 双区 hit rate | 无层固定比例长期严重偏离 50%；固定区 hit rate 不显著低于自适应区 |
| 退出模式（M10） | `systemctl stop`（SIGTERM→QUIT）/ QUIT / SIGKILL 三种退出各查一次 profile 落盘完整性 | 前两种必落盘（serve QUIT 优先机制，`server.py:1227-1239`）；SIGKILL 靠 10 分钟兜底，接受丢 ≤10 min |

### P5 文档（0.5 天，AGENTS.md 风格：plain words + 实测数字）

- `docs/DETAILS.md` 新增一节：固定/自适应分层、`STRATA_ARENA_MMAP`、RAM 前后实测值与 tokens/s
- 更新 `strata-iq3_s.json`（`env` + 新参数 + per-pack profile 路径）

## 6. 回滚（四个独立开关，修订 #7）

| 开关 | 关闭态 | 效果 |
|---|---|---|
| A：`STRATA_ARENA_MMAP`（env） | 不设 | 回到 pinned arena（改造前状态） |
| B：`--expert-cache-fixed` | 0 | 无固定区（全槽静态/自适应） |
| C：`--adapt-every`/`--adapt-swaps` | 0/0 | 无自适应层（静态驻留） |
| D：`--expert-profile-save` | 去掉 | profile 只读不覆盖，基线实验不被污染 |

开关正交，可分级定位故障面：

- mmap 异常：A off、B=0、C off → 完整原状
- 自适应层异常：A on、B=0、C off → 保留 P1 的 RAM 收益
- 50/50 异常：A on、B=50、C off → 保留固定分区 + 文件后端，只停动态交换
- `experts.bin` 是派生物（首启可重写），无回滚状态问题

## 7. 改动清单

| 文件 | 改动 | 规模 |
|---|---|---|
| `src/program/generate.cpp` | 选项、`is_fixed_slot()` 不变量、victim 过滤、断言、启动 release 循环、tier 字节统计日志、互斥/断言检查、遥测 | ~100 行 |
| `strata-iq3_s.json`（serve 配置，非仓库文件） | `env` 段 + `--adapt-every`/`--adapt-swaps`/`--expert-cache-fixed` + per-pack `--expert-profile`/`--expert-profile-save` 路径 | ~10 行 |
| `docs/DETAILS.md` | 新节 | ~15 行 |

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| 首次写 `experts.bin` 失败（盘满） | 已有 `NOT writing` 兜底，回落普通 arena |
| mmap arena 不再锁页 → H2D 走 driver staging（pageable 代价）+ 内存压力下 expert 页被回收 → major fault | 两条 DMA 路径（adapt swap + prompt loan）直接受影响；热路径**仅在 page cache 热时**不受影响（51% 专家由 CPU 池读文件映射页）；P1/P4 实测 cold/hot refill 延迟 + H2D 带宽 + 带压 p99，回退超阈值用开关 A 回滚 |
| **（P1 实测，10-07）mmap + `--pcie-frac 0` → 全量 prefill 3.1k tok/s（P0 5.7–6.3k，−48%）**；102k prompt wall 20.9→37 s | 这是 mmap 的结构性代价（无 GPU 别名，miss 全走 CPU）。decode/短请求无影响。长 prompt 重的负载需权衡：接受（换 47 GiB 可用内存）或回滚开关 A。V2 设想：对 experts.bin 页做 cudaHostRegister（重新可锁）或按请求类型双 arena——均改动大，不在 V1 |
| 固定区页释放后被 prompt loan 流式读 → 一次性磁盘重读 | loan 只取尾部（自适应区）；P4 实测频率 |
| 启用自适应层后 GPU/CPU 舍入差异 → token 与旧配置不同（质量相同，引擎日志已有说明） | 一致性基线取"首个 adapt 轮前" |
| 强杀服务丢 profile | 每 10 分钟落盘兜底 |
| `experts.bin` 过期：staleness 检查**仅比文件大小**（`expert_source.cpp:2747`），同 size 不同权重（GGUF 换版、量化切换）会静默加载旧专家 | GGUF/pack 变更后删 `experts.bin` 强制重写；P5 文档写一条操作规程；（V2 加内容指纹，见 §10） |
| mmap I/O 错误（文件截断/盘故障）→ SIGBUS，引擎无专门 handler | 发生即重启 + 校验 `experts.bin`（size + `verify_slot`）；运维加盘健康检查；P4 记录一次注入测试（`chattr +S`/截断）确认行为 |
| Windows/HIP 无 `STRATA_ARENA_MMAP` | 本方案针对 Linux 机；Windows 上 50/50 结构仍成立，仅不省 RAM（`release()` no-op），文档注明 |

## 9. 基线数字（P0 填）

| 指标 | 改造前 | P1 后 | P2+P3 后 |
|---|---|---|---|
| RSS (MiB)（引擎 pid；另有 server 221 MiB、vision 503 MiB） | **57946**（55.26 GiB）`[实测 10-07]` | **36538（35.7 GiB）**；experts.bin 文件映射 Rss 28.3 GiB（46.84 中 22.35 已被 `release()` DONTNEED——"显存专家的 RAM 副本归还"在 mmap 下自动发生）| |
| 46.84 GiB arena 映射类型（smaps） | **匿名，Rss=46.8409 GiB** | **`experts.bin` 只读文件映射 ✓**（日志 "mapped read-only ... not locked, not pinned"） | |
| AnonPages (GiB) | **52.6** | **6.5（−46.1）✓** | |
| VmPin / smaps Pinned / VmLck / Unevictable | **全 ≈0（无效指标，见 P0）** | | |
| MemAvailable (GiB) | **3.5**（内存压力直接证据） | **50.3 ✓** | |
| expert cache 槽数（`auto`，随启动漂移） | 12045/22.87 GiB（10-06）；**11751/22.29 GiB**（10-07，vision 先占 1.6 GB） | **11797/22.39 GiB**（10-07 mmap 会话）| P2：11797 不变 → 固定区 5898 槽/11.20 GiB + 自适应 5899 槽/11.18 GiB（启动日志四元组 ✓）|

**门 1 结论（2026-10-07）**：内存判据全绿（文件映射 ✓、AnonPages −46.1 ✓、MemAvailable 3.5→50.3 ✓、带压 3G hog 已无感）；decode/短请求吞吐在噪声内 ✓；**唯一系统性回退 = 全量 prefill −48%**（结构性：mmap 无 GPU 别名 → pcie_frac 必须 0）。是否接受由使用者按负载形态决定（长 prompt 重 → 回滚开关 A；decode 重/内存紧 → 保留）。

**门 2 结论（2026-10-07）：PASS**。漂移负载 X→Y→Z 两臂（详见 §5 P1.5 实测表）：自适应层开 hit 95.7–96.8% / decode 131–148 tok/s，关 hit 53.4–80.1% / decode 74–106 tok/s，全程 0 swap/refill/CUDA 错误；profile 热度重排正常落盘。P2 继续；约束更新：固定区不得饿死自适应 swap，serve 侧须补 swap 遥测（P2 第 13 项）。

**P2 完成（2026-10-07，代码 + 冒烟）**：`--expert-cache-fixed 50` 实现于 `generate.cpp`（**84 行插入 / 1 文件**，比 ~100 行预估略少）：`is_fixed_slot` 统一判据；serve/CLI 两处 victim 过滤 + landing 守卫（`fixed_evict_attempts` 计数）；serve 遥测行（round/swapped/no-victim/attempts）；loan 尾区封顶 `kAutoLendPct` + CLI 借槽 arm 补判据；启动校验（N∈[0,100]、拒 100/无 profile/elastic/split/per-layer）。实测（同 P1.5 漂移负载）：固定区四元组日志 ✓、loan 封顶 5899/11797 ✓、`fixed evict attempts 0` ✓、"reached fixed slot" 0 ✓、copy/refill 失败 0 ✓、no-victim 层 0；hit med 95.0–95.5 / decode med 127.8–147.7，在 P1.5 噪声内（50/50 是否**优于**全自适应留给 P4 判）。回滚：去掉 `--expert-cache-fixed` 即完全等价旧行为；旧二进制备份 `engine/strata.pre-p2`。

**P3 完成（2026-10-07，配置 + ~40 行遥测/轮转）**：profile 切 per-pack（`packs/iq3_s/expert-profile.bin` 输入=输出，种子=旧基线）；`--adapt-decay 0.7` 显式写进配置；`save_profile` 落盘前把上一版 rename 成 `.prev`（一份历史，坏会话毁不掉唯一好 profile）。新遥测两条：启动 `fixed tier per layer: 93..155 experts (avg 122.9 of 512)`（全局排名跨层均匀，无层极端）；每轮 `expert tiers this round: routes fixed X% / adaptive Y% / miss Z%`。**重载换血实测**：QUIT 落盘 → `.prev` = 种子 md5 `ff1bc6…`、新 profile md5 `47a047…` → 下次启动固定集（top-5898）**39.0% 成员换血** ✓。失配信号当场可见：用户话题漂移下 fixed 路由份额 60%→37%（miss 1.5%→13%）——这就是 §5"触发重启刷新 profile"的扳机，遥测够用。
| swap in/out (MiB/s) | | | |
| 固定区 source 字节 (GiB，top 6022 实测) | **11.44**（24.4% of 46.84 GiB） | | P2 固定区 = 5898 槽 × 均匀槽字节 = **11.20**（启动日志实测）|
| 自适应区 source 字节 (GiB) | | | P2 自适应区 = 5899 槽 = **11.18** |
| 各层固定比例 min/max | **18.4% (L15) / 31.1% (L6)**，均值 24.5% ± 3.0%；无层 <10% 或 >90% → P2 无需调设计 | | |
| 启动 → ready 耗时 (s) | **27**（10-07 重启后冷 page cache：loaded 46.84 GiB @ 3.85–4.10 GiB/s + prefill 11751 槽）| 首启（写 experts.bin 46.8 GiB）**60**；后续启（映射）**27** | **12**（10-07 P2 重启，page cache 热）|
| 全量 prefill (tok/s)（全新 102k–120k prompt，cached=0） | **5.7–6.3k**（`[日志]`）；102k 首次 wall 20.9 s | **3.1k（−48%）**，120k wall 41 s；同两次一致 → 系统性回退：mmap arena 无 GPU 别名 → `--pcie-frac 0` 硬前提（`expert_source.cpp:2733,2757` `dev_slice_.clear()`）→ miss 专家 100% 走 CPU（AVX-2）。decode 无影响（158.8 vs 156.5）| |
| 首 token 延迟 (ms) | | | |
| spec 接受率（`--spec 4`） | **71.2%**（中位；min 48.4 / max 100，n=790）`[日志]` | | |
| decode tokens/s（± 噪声范围，5–10 次重复） | **140.3**（中位；min 0.0 / max 197.8，n=791）`[日志]`；活体噪声（10-07，同请求 ×8，thinking off，200 tok）：min 107.1 / med 156.5 / max 166.2，**CV 13.4%** → P4 对比必须用重复中位数，5% 阈值在噪声内 | **med 158.8（+1.5%，噪声内）✓**；带压最差 87.8（P0 79.8） | P2 会话（X/Y/Z 漂移）：med 147.7/127.8/135.7，与 P1.5 差在 CV 13.4% 噪声内 |
| p95 / p99 延迟 (ms)（请求级，`[日志]` 2026-10-06 会话） | decode p50/p95/p99 = 2950/15080/27744；prefill p50/p95/p99 = 1558/24829/37330 | | |
| 带压场景 p99（原计划 stress-ng 8G；实测用 3 GiB python hog，因 MemAvailable 本就只剩 2.5 G） | 10-07 实测：avail 2.5→0.4 G、swap 用 +1 G；decode 最差 79.8 tok/s（压力首请求），其余 135–148；系统 pgmajfault +20357 但 **引擎 majflt=0**（被回收的是页缓存/PLE 文件页，锁页 arena 不动）；引擎 RSS 压力下**自降 2.1 GiB** | | |
| KV host 占用 (GiB，262K) | 长请求实测：102k token prompt 首次 wall 20.9 s、复用 cached 98304 后 3.6 s；`[日志]` KV streaming 主机块读 0.5–2.8 GiB/会话，conversation parking 要 1.5–2.6 GiB（内存不足时拒绝 park） | | |
| hit_rate | **95.3%**（中位；min 78.1 / max 98.6，n=790）`[日志]` | | |
| 固定区 / 自适应区 hit rate | | | |
| major faults/s | | | |
| SSD read MiB/s | | | |
| fixed_evict_attempts 计数 | | | |
| VRAM free (MiB) | **393**（10-06）/ **394**（10-07 脚本起）`[日志]`；smi 31855/32607 已用 | | |
| PCIe H2D (GB/s) | **28.4**（probe）`[日志]` | | |

`[日志]` 值来自 `strata-iq3_s.log`（2026-10-06 23:58 会话，engine 0.1.39，791 个请求）。活体指标（VmPin、噪声范围、带压 p99、KV 占用、major faults、SSD read、启动耗时）需引擎运行态，随 P1 前的一次短会话补齐。

## 10. 明确不做（后续单独立项）

- 100% 显存专家释放 RAM（自适应换入变磁盘读）
- per-layer 50/50（`set_per_layer_admission` 开启时固定/自适应按层对齐；V1 仅遥测监控，见 P3）
- 多 GPU（`peer_experts` / remote tier）接入固定区
- `CacheSlot`/`ExpertTier` 数据模型重构（V1 用 `is_fixed_slot()` + 断言守住不变量；槽结构体化留 V2，与代码库 flat-table 风格一致）
- profile 文件头加 model fingerprint（V1 用 per-pack 路径规避，文件头动格式留 V2）
- 24 h 全矩阵压测（hot/cold/distribution-shift 三 workload；本机 hack 取 8 h + 一次 shift 足够，生产化时补全）

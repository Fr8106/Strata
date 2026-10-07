# Strata 内存改造项目：从头梳理与技术线路评估（2026-10-07）

> **来源**：记忆 `strata-expert-split-progress`；会话 `3bdb8be6`（10-07 00:05–09:35，P0–P3）与 `180d3c2c`（10-07 09:17–23:09，P4-A/方案 B/实际使用）；`docs/EXPERT_SPLIT_PLAN.md` §9–§9.6；git 至 `4f24486`。
> 所有数字出自项目内实测（窗口脚本输出 / `strata-iq3_s.log`），§7 中标注了口径有缺口的两处。

---

## 1. 起因与目标

**改造前（P0）的痛点**：Strata 把 48 层 × 512 = 24576 个专家（IQ3_S，**46.84 GiB**）全量匿名 pinned 常驻 RAM；显存另有 **22.87 GiB 专家缓存**（≈11751 槽，热门常驻 + 自适应换入/淘汰）。系统只剩 **3.5 GiB MemAvailable**。

**用户的原始设计（10-06 深夜）**：把显存专家槽 50/50 拆分为——
- **固定半区**：加载后**不再保留内存副本**、服务重启前不换出；
- **自适应半区**：保持原换入/淘汰机制；
- 排名沿用原 `usage` 统计；重载时固定集替换为当时最热专家。

## 2. 计划与评审（`docs/EXPERT_SPLIT_PLAN.md`）

P0 基线 → P1 专家层切 mmap 文件后端 → P1.5 自适应层验证 → P2 50/50 拆分（~100 行 generate.cpp）→ P3 重载循环 → P4 验证 → P5 文档。两轮专家评审共 **7+12 条修订**（关键修正：VmPin 类计数器对 `cudaHostRegister` 全部无效；P1 必须 `--pcie-frac 0`；新增 P1.5 阶段与两个决策门；P2 加 `fixed_evict_attempts` 守卫与参数校验）。

**铁律（已入记忆）**：本助手会话跑在 8088 本地 LLM 上；停/拉 LLM 必须同一脚本闭环、停前先征得同意；ninfer 容器与 `strata.service`（systemd）**互斥不共存**。

## 3. 逐阶段结果

| 阶段 | 结果 |
|---|---|
| **P0 基线** | 固定区（top 6022）11.44 GiB = 24.4%，各层 18.4–31.1% 无极端；噪声 CV 13.4%；MemAvailable 3.5 GiB |
| **P1 mmap** | 门 1 PASS：AnonPages −46.1 GiB、MemAvailable 3.5→**50.3 GiB**；**唯一结构性回退：prefill −48%**（3.1k vs 5.7–6.3k；mmap 不能被驱动注册 → 无 PCIe 别名 → `--pcie-frac 0` → miss 全走 CPU AVX-2）|
| **P1.5** | 门 2 PASS：自适应层在 mmap 下**必需**（hit 96% vs 53–80%，decode 131–148 vs 74–106）；发现 serve 侧 adapt 无遥测 → P2 补 |
| **P2** | `--expert-cache-fixed 50`（84 行，1 文件）：固定区 5898 槽/11.20 GiB + 自适应 5899 槽/11.18 GiB；`fixed evict attempts` 恒 0；回滚＝去掉参数 |
| **P3** | profile per-pack + `.prev` 轮转；重载换血实测 **39%**；tier 份额遥测上线 |
| **P4** | 四臂对比被用户搁置 → 转**实际使用测试**（`tools/usage-watch.sh` 看门狗）|
| **P4-A** | 实际使用暴露 prefill −48% 不可接受 → 实测驱动**拒绝注册 file-backed 映射**（匿名可）→ 改**匿名 arena 选择性注册**（非固定区 35.6 GiB 拿 PCIe 别名，固定区不注册、可回收）。启动三连挂排查（t7–t15 全矩阵 + 引擎内取证，真根因＝注册段形状/粒度）→ **48 层整层 Mapped 注册**（`9ad8c44`），19:26 窗口验证通过。稳态 A/B：32K prefill **4468** tok/s，但峰值 MemAvailable **3.1 GiB < 专家 8 GiB 安全线** → 用户立项方案 B |
| **方案 B（P4-B）** | `572abc0`：`expert_off` 逐专家偏移表 + `expert_layout_tier_order`（每层 profile 专家按排名序排到层前部，固定集＝前缀）→ **96 tier runs**（每层固定块 + 非固定块各一）；`load_experts_tier`；`release_fixed_tier()` 变真。两处驱动约束的连环修复：**canary L0 降级根因**＝64 KiB 零拷贝 HtoD 跨两个相邻 Mapped 注册边界被拒（k=0 采样点踩在固定 run 末页；`t16` 独立复现）→ 改 `ceil4k`（`c976960`）；**fill 在 pair 5898 挂**＝源在规范序 experts.bin 里跨注册边界（L9 非固定区起点非 4K 对齐）→ staging bounce（`beb9deb`）|

**方案 B 第三窗口（21:50，全验收通过，`a71e020`）**：tier-ordered layout ✓；96 tier runs 0 拒 ✓；canary **L0 Mapped 零拷贝** ✓；fill 11797/11797 ✓；**11.19 GiB 真归还 OS**（P4-A 为 0）✓；峰值 MemAvailable **15.6 GiB**（空闲 18.4，安全线 2 倍，未换页）✓；**32K prefill 4416.8–4506.2 tok/s（A/B 的 99–101%）**、1K 684–748、decode 112–136 ✓；fixed evict 恒 0、无 released 告警、闭环干净退出（VRAM 34 MiB → swift15 显式拉起）。

## 4. 改造前 → 现在（核心对照）

| 指标 | 改造前 | 现在（方案 B） |
|---|---|---|
| 46.84 GiB arena | 匿名全 pinned | 35.66 GiB 注册（GPU PCIe 别名零拷贝）+ **11.19 GiB 归还 OS**（真实使用中随槽数变化实测 10.63 GiB）|
| MemAvailable | 3.5 GiB | 空闲 18.4 / 峰值 **15.6 GiB** |
| 固定区 | —（不存在）| 5898/11797 槽（11.19 GiB），重启前不换出；重载按新 profile 换血 39% |
| 32K prefill | 5.7–6.3k（102–120K prompt 口径，见 §7.3-②）| 4417–4506（A/B 口径的 99–101%；P1 mmap 时只有 3.1k）|
| decode | med 156.5（n=791）| 112–136（噪声 CV 13.4% 内）|
| 用户原始构想 | — | **全部落地**：50/50 固定/自适应 + 内存副本真释放 + 排名换血 |

## 5. 当前未决：verify 超时（与改造的关系见 §7.3-①）

- **症状**：大 prompt（88K/126K/158K/163K）+ **多大会话并发**下 → `verify: timed out at layer N; its GPU waits were released but the GPU did not finish within 5 s (#267)` → 引擎自停、server 慢重启（2+ 分钟不可用）、dmesg NVRM 中断风暴 + Xid 31 MMU Fault；layer 号不定（4/6/7/22/23）、同尺寸时成时败（162,776 Done vs 163,108 Error）——竞态/饱和，不是干净的尺寸阈值。
- **机制**：`--spec` 的推测解码验证窗口（`src/core/verify.cpp`，`release_gpu_waits(5000)` **硬编码 5 s/层**）在独立 stream 上跑 CUDA graph；超时 → `EngineDied`。
- **收窄结论**：触发量是 **live KV 总量**（会话缓存 6144 MiB/4 slots 让 2–3 个 127K+ 会话同时 live，`parked=3 bytes=6.26 GB`，总 live ≫ 131K 常驻窗）→ 每请求 200–465 MiB KV 经 PCIe 流式 → GPU 饱和 → verify 图饿死。放大因素＝显存 **298 MiB free 贴地**（代码自注"贴地 paging → verify 自旋永不完成"警戒带）。
- **反直觉点**：原版 20 s prefill 不报错，是因为原版 RAM/disk-bound、**GPU 有空闲**；"把 prefill 变快"本身制造了 verify 饿死的条件。KV 侧相对 P0 唯一改动只是 `--kv-resident 32K→131K`（方案 A，只止血单会话，131K 已是显存硬上限）。
- **已交接**：`docs/HANDOFF-VERIFY-TIMEOUT-2026-10-07.md`（`4f24486`），请专家裁定：**B**（verify 饱和期让位/自适应 deadline）vs **A′**（压并发 live，配置止血）vs **C**（live-KV 封顶驱逐），外加 298 MiB free 是否本就是 bug、Xid 31 是否独立故障。
- **A′ 对照（23:43 窗口，`tools/repro/aprime-win.sh`，结果 `tools/repro/aprime-results.txt`）：两臂均未触发，未构成复现**。工作负载＝2 个 ~100K 会话并行 ×2 轮（`kv-multi-smoke.py`）。arm1（6144，阳性对照）4/4 完成、0 超时、0 重启，流式仅 110–140 MiB/请求（真实故障时 207–465 MiB）；arm2（3072）同样 4/4 完成（付出了应有的代价：会话缓存 `evictions=1`，第二个大会话丢缓存→重 prefill 25.4 s）。结论：**"live 总量超窗"单条件不足以饿死 verify 图**，需要更强负载（更大会话 127K–163K / 更长生成 / 3 路并发）才能复现；A′ 仍未验证。

## 6. 当前机器与代码状态

- **服务**：`strata.service` inactive；LLM 在 **swift15** 容器（8088，本助手会话跑在其上）。
- **配置**（`strata-iq3_s.json`）：`--kv-resident 131072`、`--conversation-cache-mib 3072`（A′ 预置，未验证）、`--expert-cache-fixed 50`、无 mmap、无 `--pcie-frac`（方案 B 形态）。
- **代码**：HEAD `4f24486`；未提交＝`tools/switch-strata.sh` + `tools/repro/kv-long-smoke.py` 两处冒烟健壮性小修；未跟踪产物＝`full-window-results.txt`、`optionb-forensic-results.txt`、`reglog-*.txt`、`kv-multi-smoke.py`、`data/request-log.jsonl` 等。
- **文档**：计划正本 `docs/EXPERT_SPLIT_PLAN.md`（§9 基线 / §9.5 P4-A / §9.6 方案 B）；两份交接文档；`docs/reviews/` 四份专家评审 + 分析。

---

## 7. 技术线路评估

### 7.1 结论

**技术线路没有方向性错误。** 内存目标（项目存在的理由）已达成且有实测；性能保留有同窗口对照；每一步都有回滚开关与备份。发现的问题集中在三类：① 一个阻塞产品可用性的未决故障（verify，其与改造的因果关系**尚未完全排除放大作用**）；② 两处证据/口径缺口；③ 若干运营性遗留。均为可处理事项，无需重构。

### 7.2 成立的部分（判定依据）

- **决策链路均有实测支撑**：file-backed 不可注册（引擎停机窗口实测）、跨注册边界 DMA 被拒（`t16` 独立复现）、HMM 寻址模式（`attrq`）、pageable 带宽 60%（`optd`）、注册段数预算是上下文相关（t9/t13/t14/t15 矩阵）。
- **两个目标被同时达成**：方案 B 让"归还 11.19 GiB"与"prefill 99–101% A/B"并存——这是 P1（只省内存丢性能）与 P4-A（保性能但 3.1 GiB 峰值不达标）之外的第三条路，且双向达标。
- **正确性防护成体系**：fill 全槽 + 逐槽校验、canary 三级梯子（L0/L1/L2）、`fixed_evict_attempts` 不变量、`blob()` 释放后守卫（返回 nullptr 落 CPU 路径而非读零页）、`expert_layout_test` 逐字节装载测试、跨 run 拷贝的 bounce 兜底。
- **工程可回滚**：四个独立开关（A/B/C/D）、`engine/strata.pre-p2`/`.pre-p4` 二进制、`strata-iq3_s.json` 各阶段备份。

### 7.3 问题清单

**① P0 级——阻塞产品可用：verify 超时。** 现行结论是"与改造无关"，证据链到"工作负载形态是主因"为止（故障在 serve 期 spec 验证窗口，fill/canary/专家侧全部正常）。但改造的两处放大作用**未被排除**：
- 显存余量 393 MiB（P0）→ 298 MiB（现在），"贴地 paging"的概率上升；
- prefill 变快 = 单位时间内 GPU 负载密度上升，留给 verify 图的空隙变少。

建议把结论改写为：**主因＝工作负载（多大会话并发），改造有放大作用待排除**。排除路径见 §7.4。若要把话说到底，还有一个反事实可选：用 P0 二进制（`engine/strata.pre-p2` + `strata-iq3_s.json.p0-backup`，`--kv-resident 32768`）配同工作负载跑一次——若 P0 也超时，则改造完全无关；若不超时，则改造是必要条件之一。仅诊断价值，非决策必需。

**② P1 级——证据/口径缺口（影响对外数字与后续决策）：**
1. **prefill 对照口径不一致**：改造前的 5.7–6.3k 是 102–120K prompt 的全量口径，A/B 的 4468 是 32K 口径，"85%" 只是内部近似，不能当作同口径结论。补法：P0 二进制 + 32K prompt 跑一次（半个窗口）。
2. **50/50 拆分的价值从未做对照**：P4 四臂被搁置。已知数据只能说明"固定区不劣"（fixed evict 恒 0、miss 1.2–11.4%、各层固定占比均匀），但不能回答"50% 是否优于 30%/70%"——固定区越大，可归还内存越多，但自适应灵活性越小；这是一条未测的权衡曲线。低成本补法：同窗口跑 `--expert-cache-fixed 30/50/70` 三臂（每臂 ~5 min）。若不做，应在 P5 文档中明确标注"该参数未做对照"。
3. **长稳未测**：方案 B 三窗口均为分钟级；8 h/24 h soak（P4 计划里）未执行。残余风险＝低频问题（已释放页被重触、35.66 GiB pinned 在长时间内存压力下的行为）。

**③ P2 级——运营遗留（成本低）：**
1. 配置里 `--conversation-cache-mib 3072`（A′ 预置）未验证——下次起 strata 前必须判定：跑掉它，或改回 6144，不留歧义（首轮 A′ 窗口后配置已还原为 3072）。
2. 未提交小修与未跟踪产物——归档即消。
3. `--vram-reserve-mib 700` vs 实测 298 free（日志有 `reserve was lowered` 分支）：建议在 verify 修复里一并加"余量地板"（如 free < 512 MiB 时压缩缓存/告警），给"榨干显存"策略留一条自救余量。
4. 固定区的运维语义：话题漂移后固定集失配（实测 fixed 路由份额 60%→37%、miss 1.5%→13%），靠重启换血——应写进 P5 使用文档（遥测扳机已有）。

### 7.4 对 verify 修复的具体建议（提交专家时补充）

1. **B 的形态优先选"饱和期动态降级推测解码（关 spec / 缩窗），而不是"跳过/放宽 verify"**。理由：verify 图是推测解码的验证窗口（`verify.cpp`：`--spec` 的 drafts 才需要 verify）——关闭推测时**没有 draft 就没有验证需求**，正确性语义保守（退化到普通解码，只是变慢）；而"跳过/放宽 verify"意味着 draft 的接受判定可能被跳过或延迟，存在正确性漏检风险，需要专家确认 `#267` 的 `release_gpu_waits` 语义后定夺。`--spec` 目前是启动常量，需要引擎加运行时开关。
2. **饱和判据无需新埋点**：现成可用的信号已有三类——`KV streaming: X% of N block reads hit VRAM, Y MiB read from RAM`（每请求）、每轮 `expert tiers this round: fixed/adaptive/miss`（每轮）、`cudaMemGetInfo` 的 free VRAM（README 已有 298 MiB 打印）。组合（流式字节速率 + freeVRAM 下限）即可定义"饱和"。
3. **顺序建议**：先跑 A′ 对照（已就位，判"live 总量"假设真假、且本身是可用止血）→ 等专家回复 → 实现 B（含 §7.3-③3 的余量地板）→ 再谈 C。

### 7.5 未测项清单（明确登记）

| 项 | 状态 | 价值/成本 |
|---|---|---|
| P0 二进制 + 32K 同口径 prefill | 未测 | 补齐唯一的口径缺口；半个窗口 |
| `--expert-cache-fixed` 30/50/70 三臂 | 未测 | 固定区大小的权衡曲线；一个窗口 |
| 8 h soak（hot/cold/shift 三 workload） | 未测（P4 计划内） | 长稳；一个夜间窗口 |
| A′ 对照（live 总量假设） | 已跑（2×100K，两臂均未触发，未构成复现）；需更强负载复跑 | 决定 verify 止血方案是否成立；一个短窗口 |
| P0 反事实（同工作负载） | 未测 | 判定改造是否引入/放大 verify 故障；诊断用 |
| nsys prefill 时间线 / chunk 调优 / CPU sweep(12v24/CCD/大页) | 未测（专家建议已排队） | 后续性能方向 |

## 8. 未来方向

- **待专家回复**：verify 超时（B/A′/C + §7.4 的补充）。
- **专家优化建议**（已评估落盘 `docs/reviews/OPTIMIZATION-SUGGESTIONS-*`）：重心转向 **prefill 流水线 + 前缀缓存**；已做＝请求级日志（`STRATA_REQUEST_LOG`）、usage 播种；排队＝双缓冲预取（并入方案 C 决策）、TinyLFU/spec 联动；缓做＝前缀缓存（等命中率数据）、量化分级；CPU sweep 待做。
- **项目内剩余**：P4 四臂对比（或明确标注不做）、P5 文档（AGENTS.md 风格）、8 h 压测。

## 9. 固化经验（坑与规则）

1. **驱动硬约束**：① file-backed 映射不可 `cudaHostRegister`；② 零拷贝 DMA 源**跨两个相邻 Mapped 注册边界**被拒 `invalid argument`（canary 与 fill 各踩一次）。
2. **无效指标**：VmPin / smaps Pinned / VmLck 对 `cudaHostRegister` 全 ≈0；验收用 AnonPages / MemAvailable。
3. **窗口脚本模式**：dead-man 定时器 + VRAM 预检 + kill -9 兜底 + 孤儿显存 ABORT + 同脚本拉回 LLM（三次手动救场换来的；见记忆 `llm-service-window-rule`）。
4. 注册段数预算 **≈5300 是上下文相关**，不是固定上限；`--expert-cache auto` 槽数随显存水位漂移，固定区大小随槽数变（11797→11199 槽时归还数 11.19→10.63 GiB）。

## 10. 证据索引

- 计划正本：`docs/EXPERT_SPLIT_PLAN.md`（§9 基线表、§9.5 P4-A、§9.6 方案 B）
- 交接：`docs/HANDOFF-EXPERT-CACHE-2026-10-07.md`（P4-A 故障排查）、`docs/HANDOFF-VERIFY-TIMEOUT-2026-10-07.md`（verify 超时）
- 评审：`docs/reviews/P4A-REVIEW-2026-10-07.md` + `-ANALYSIS`、`docs/reviews/OPTIMIZATION-SUGGESTIONS-2026-10-07.md` + `-ANALYSIS`
- 复现与窗口：`tools/repro/`（t7–t16、`verify-win.sh`、`ab-win.sh`、`optionb-win.sh`、`optionb-forensic-win.sh`、`kv-long-smoke.py`、`kv-multi-smoke.py`）
- 关键提交：`da870f9`（P2+P3）→ `00a530e`/`4255b29`/`9ad8c44`（P4-A）→ `a2c8bb5`/`6b7a2d1`（验证+A/B）→ `572abc0`（方案 B）→ `c976960`/`beb9deb`/`a71e020`（方案 B 修复+全验收）→ `40df7af`/`4f24486`（闭环切换脚本、verify 交接）

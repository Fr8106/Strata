# 加固方案审核意见 —— 逐条核对与裁决（2026-10-08）

> 被核对文档：`docs/reviews/HARDENING-PLAN-REVIEW-2026-10-08.md`（专家，纯文档审核，自标 10 处"待核实"）。
> 本文件 = 我方对代码逐条核实后的裁决。全部行号对当前 main（`f110877`）。

---

## 1. 十个"待核实"的核实结果

| 专家问题 | 代码事实 | 裁决 |
|---|---|---|
| §8-1 别名只查头不查尾？ | `expert_source.cpp:3162` 是 `bo >= ns && bo < end`：end=层逻辑末端；blob 按 `per` 连续平铺（布局不变量 `bo+per ≤ end`）；run 注册到 `ne=ceil4k(end) ≥ end` → **尾自动被包含**。 | 无"另一半 bug"；保护来自平铺不变量而非显式检查 → T3 校验器把它显式化 |
| §8-2 释放取整方向？ | `release_fixed_tier:3015-3021` 只 DONTNEED `[ceil4k(起), floor4k(止))`=**两端向内的内部**；边页显式保留（注释 3002-3004，~96 KiB）。per-expert `release():2991-2992` 同规则。 | 已处理，R4 降级 |
| §8-3 96 段构成 | 每层 2 run × 48 层（注释 3111），逐层 [fixed][non-fixed] 连续（3105-3108）。 | 确认 |
| §8-4 骑边界 blob 1 个还是 2 个 | **≤1**：别名唯一发放在 non-fixed run 循环（`blob_dev_[...] =` 全文件仅 :3163 一处），fixed 侧从不发别名。"48/24576"是 gap 修复前的**拷贝**跨界计数。 | 确认 1 个 |
| §8-5 第一个 non-fixed=最热非驻留？ | 是。tier 序=全局排名序（`expert_layout_tier_order`），fixed=前缀 → 骑边界专家=排名 nfix。 | 成立；R6 需实测，T5 的 pad 顺带根治 |
| §8-6 pinned()==false 消费者都有 fallback？ | 未证——正是 R6 的 `STRATA_FORCE_NOALIAS_PCT` 注入要压的。 | T7 |
| §8-7 queued staging 何时回收？ | **实锤潜伏 bug**：`:675-676` 重试先 CPU `memcpy` 写 `blocking_staging_`，上一笔从该 staging 出发的 `cudaMemcpyAsync`（stream 0）可能仍在飞；CPU 写不与流排序 → 覆盖在飞数据。今天该分支近乎不触发所以未爆。 | T2 修（重试入口先 `cudaStreamSynchronize(0)`） |
| §8-8 experts.bin 与 arena 布局耦合？ | tier 序只存在于内存 `expert_off` 表（`load_experts_tier` 规范序→tier 序拷贝；`expert_layout.hpp:90`：层起点不变、只有 `blob_offset` 动）。**R1 填充只进偏移表，文件格式不动。** | R1 前提成立 |
| §8-9 teardown 是否同步？ | `close():2930` 无条件注销全部 runs；无"卡死则跳过"。 | T7（R10） |
| §8-10 t17 注册标志？仅 Portable 下 B？ | t16/t17 全部 `Portable\|Mapped`（t16.cu:31,106；t17.cu:61-98）。**仅 Portable 从未测过**。 | T4 关键臂 |

## 2. "已存在、不必再造"——专家三处高危评级下调

1. **R8 fail-fast**：`verify.cpp:1458-1466`（window）与 `:1996-2004`（batch）已实现每 1024 spin/~2 ms `cudaStreamQuery`，流报非 NotReady 且 seq 落后 → 立即 `never rang (<err>)`。与专家示意代码同形。剩余仅可选 NVML watcher（P3，YAGNI）。
2. **R4 取整**：见 §8-2 行。另：生产形态为选择性注册，`release()` 对该模式返回 0（`:2984`），DONTNEED 只发生在故意回收的固定区内部，无"相邻 non-fixed 被清零"路径。
3. **R5 状态机**：`release_fixed_tier` 唯一调用点在**启动期 fill 后、serving 前**（`generate.cpp:4523`）→ 生产流程无运行时窗口；别名置空（`:3028-3029`）+ `fixed_released_` 的 `blob()` 守卫（`:3323-3339`，warn-once 落 CPU，"never silent zeros"）已封死零页路径。状态机留给未来动态释放。

## 3. 对专家建议的采纳台账

| 建议 | 裁决 | 落点 |
|---|---|---|
| H1 分类/限流/清 last-error/staging 生命周期 | 采纳（分类离线做：日志带 src，对照 `STRATA_PCIE_REGLOG`） | T2 |
| "次数==0"过宽 | 采纳：几何类==0，他类单独计数 | T2 + 计划 §4 |
| H2 矩阵 + 仅 Portable | 采纳 | T4 |
| 启动特性探针（B/C 两形态） | 半采纳：并入 T3 校验行的可选开关，不单独立项 | T3 |
| H3 升为代码断言 | 采纳（首周 WARN、两个无假阳浸泡夜后升 fail-closed，改一行） | T3 |
| R1 构建侧填充 | 采纳（纠正我方此前否决；前提 §8-8 已核） | T5 |
| R2 启动全量校验 + 无 GPU 单测 | 采纳 | T3 |
| R6 热专家代价 + 注入开关 | 采纳 | T1 基线 + T7 |
| R7 HostRangeTable | **暂缓**：3 个调用点，且禁止第二份 run 表（#267 即两视图不同步病） | 计划 T8 |
| R9 统计力度（三法则） | 采纳：确定性校验为主验收，浸泡 ≥30 序列/8 h | 计划 §4/T7 |
| R10 teardown | 采纳 | T7 |
| R11 Q1(c) 证据混杂 | 采纳：措辞降级 + t18 隔离臂复测 | T0/T4 |
| R12 fixed 去 Mapped | 前提半对（fixed 确无别名消费者），**先测仅-Portable 再改** | T4 → 复评 |
| R13 kv-resident 重估 | 半采纳：重估要，但"假设已死"过头——KV 流式饱和是独立现实现象 | 数据另议 |
| 假设登记表 / 旧文档横幅 / 驱动 hold | 采纳 | T0 |

## 4. 执行

任务与验收见 `docs/HARDENING-PLAN-2026-10-08.md`；分支 `hardening/2026-10-08`。

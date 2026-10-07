# 交接文档：Strata 大 prompt 下 verify 窗口超时（求助人类专家）

**日期**：2026-10-07　**机器**：RTX 5090 32 GiB + 62 GiB RAM + Ryzen 9 5900X，Ubuntu 24.04，驱动 610.57.04，CUDA 13.0
**模型**：Qwen3.8-Flash-Next（48 层 × 512 专家，IQ3_S，`strata-iq3_s.json`）
**状态**：方案 B（tier 有序 arena）已全验收通过；本问题是**实际使用测试**中暴露的新故障，配置层（方案 A）只能部分缓解。

---

## 0. 一句话求助

大 prompt（≥88K，实测 88K/126K/158K/163K）下，引擎报
`verify: timed out at layer N; its GPU waits were released but the GPU did not finish within 5 s (#267)`，
随后引擎自停、server 慢重启（2+ 分钟不可用）、dmesg 出现 NVRM 中断风暴 + Xid 31 MMU Fault。
**layer 号不固定**（实测 4/6/7/22/23），**同尺寸有时成功有时失败**（162,776 Done，163,108 Error）——是竞态/饱和，不是干净的尺寸阈值。
请专家判断：这是 **verify 图与主计算争抢 GPU 资源的结构性缺陷**，还是显存余量（298 MiB free）触发的驱动 paging？修复方向应是 **B（verify deadline 自适应）** 还是 **压住 live KV 总量**？

---

## 1. 症状（确切证据）

- 报错行（`src/core/verify.cpp:1474/1477`）：
  `verify: timed out at layer N; its GPU waits were released but the GPU did not finish within 5 s (#267)`
- 机制：`Verifier::run` 在独立 stream 上 launch 一个 CUDA graph，host 线程自旋等 GPU 逐层写 `seq` 计数器，**每层 5 s 硬超时**（`release_gpu_waits(5000)`）。超时 → 引擎 `EngineDied` → server 重启引擎（`reading the model's weights ... a minute or two`）。
- dmesg（每次故障后）：
  - `NVRM: Going over RM unhandled interrupt threshold for irq 166`（重复多次，~40 s 间隔）
  - `Xid 31 ... MMU Fault: ENGINE GRAPHICS ... FAULT_PTE ACCESS_TYPE_VIRT_READ @ 0x71d5_3c049000`（收尾期，是卡死状态的**后果**非起因）
- 面板表现：请求 `Error`，随后 8088 无响应数分钟。

**时间线（2026-10-07，本地时间）**：
| 时间 | prompt | 结果 |
|---|---|---|
| 22:03:40 | 88,177 | verify 超时 layer 6 → 引擎停 |
| 22:19:22 | 126,903 | verify 超时 layer 22 → 引擎停 |
| 22:4x | 158,708 | verify 超时 layer 4 → 引擎停 |
| 22:50 | 122,058 / 163,108 | verify 超时 layer 7 → 引擎停（122K < 131K 窗口仍失败！）|
| 22:49:18 | 162,776 | **Done**（同尺寸成功 → 竞态）|

---

## 2. 根因分析（已用日志证据收窄）

### 2.1 直接触发：live KV 总量超过 VRAM 常驻窗，强制 PCIe 流式
`--kv-resident` 决定每 QSA 层常驻 VRAM 的 cell 数。当前 `131072`（131K）。
但**会话缓存**（`--conversation-cache-mib 6144 --conversation-cache-slots 4`）会让**多个大会话同时 live**：

```
conversation cache: parked 127085 tokens ... parked=2 bytes=3006074900   # 两个大会话
conversation cache: parked 158867 tokens ... parked=3 bytes=6260885700   # 三个大会话共存
KV streaming: 82.92% of 301932 block reads hit VRAM, 207.8 MiB read from RAM
KV streaming: 90.62% of 1232400 block reads hit VRAM, 465.5 MiB read from RAM
```

3 个 127K–163K 会话同时 live ⇒ live KV ≈ 300K+ cells ≫ 131K 窗口 ⇒ 每请求 200–465 MiB 从 pinned RAM 经 PCIe（Gen4 x16 ~28 GB/s）流式进 VRAM ⇒ **GPU 队列饱和** ⇒ 并行的 verify graph 在 5 s/层 内跑不完 ⇒ 超时。

**关键反证**：122,058 token 单请求 < 131K 窗口，本应全常驻，但因其它大会话同时 live 仍触发流式 + 超时。⇒ 触发量是 **live 总量**，不是单请求尺寸。

### 2.2 放大因素：显存余量贴地（298 MiB free）
`strata serve: 298 MiB of VRAM free with everything loaded`。代码自注（`generate.cpp:5953-5958`）：
> under WDDM a GPU filled to the brim does not fail, it pages — and a page-in while the verify graph spins on a host flag stalls the request for good.

298 MiB 紧贴代码自身的 ~256 MiB 警戒带（低于才告警）。显存贴地 + verify 自旋 ⇒ 驱动可能 page GPU 内存 ⇒ verify 图"never finishes"。**Xid 31 / 中断风暴与此一致。**

### 2.3 专家缓存已自动让位（非瓶颈）
`--expert-cache auto` 随 kv-resident 增大自动缩：`11797 slots (32K) → 11400 (98K) → 11199 (131K)`，VRAM free 恒 298 MiB。专家侧已无余量再让。

---

## 3. 我已做的（方案 A，配置层，效果有限）

`strata-iq3_s.json` 的 `--kv-resident`：`32768 → 98304 → 131072`（备份 `strata-iq3_s.json.pre-kvres96`）。
- 效果：88K/126K 单会话场景缓解（常驻窗变大，流式减少）。
- **不足**：① 显存到顶，131K 已是上限（再大都撑爆专家缓存）；② 多大会话并发时 live 总量仍超窗，122K/158K/163K 仍超时；③ 不解决 verify 图在 GPU 饱和时的结构性脆弱。

**结论：方案 A 是止血不是根治。需要方案 B 或 live-KV 封顶。**

---

## 4. 候选修复（请专家裁定方向）

| 方案 | 改动 | 效果 | 风险/代价 |
|---|---|---|---|
| **A′ 压 live 总量**（配置） | `--conversation-cache-mib 6144→~3200`、`--conversation-cache-slots 4→2`，使同时 live 的大会话 ≤1 个（≤131K） | 消除"多大会话并发超窗"触发 | 用户失去多大会话并行缓存；小会话不受影响 |
| **B verify deadline 自适应**（代码） | `src/core/verify.cpp`：超时时不直接 `EngineDied`，改为**放宽/跳过该窗口**（饱和期暂停 canary），或 deadline 随 KV 流式速率缩放 | 根治"饱和即杀引擎"；canary 在饱和期让位 | 需定义"饱和"判据；canary 在高压期暂时失察（正确性窗口让位）；`#267` 的 `release_gpu_waits` 路径要同步处理 |
| **C live-KV 封顶**（代码） | 引擎在 live KV > 常驻窗时**主动驱逐最冷 parked 会话**（而非让其流式） | 从源头消除超窗流式 | 驱逐策略 + 会话缓存语义改动较大 |
| **显存余量** | 提高 `--vram-reserve-mib`（现 700，实测被压到 298 free）| 降低"贴地 paging"概率 | 挤占专家缓存/常驻窗，与 3 冲突 |

**我倾向 B（治本）+ A′（立即止血）**：A′ 让用户当前多大会话场景不再触发；B 让引擎在真正饱和时不再自杀。C 更彻底但改动面大，可作后续。

---

## 5. 具体想请专家回答

1. **verify 图饱和时让位是否安全**：verify 是正确性 canary。高压期"跳过/放宽"窗口，会不会漏掉它要抓的那类 bug？`#267` 的 `release_gpu_waits` 语义下，跳过窗口要动哪些状态？
2. **饱和判据**：用什么信号判断"GPU 正在 KV 流式饱和"（PCIe 利用率？block-read 命中率 < 阈值？verify 窗口等待时长 > X）？引擎里现成可采的量有哪些？
3. **298 MiB free 是否本就是 bug**：`--vram-reserve-mib 700` 应保 700，实测只剩 298 —— 是 reserve 被 `reserve_adapted` 压低了（日志有 `reserve was lowered` 分支），还是预算算错？显存贴地本身是否就该告警/拒载？
4. **Xid 31 / 中断风暴**：是 verify 自旋 + 贴地 paging 的必然后果，还是独立故障？是否需要单独处理（如显存贴地时禁 verify）？
5. **会话缓存语义**：`--conversation-cache-mib/slots` 是 RAM（parked）预算，但触发的是 VRAM（live）超窗。是否应有"live KV ≤ 常驻窗"的硬约束（方案 C）？

---

## 6. 复现 + 文件

- **复现**：起 strata（`tools/switch-strata.sh` 闭环），并发 2–3 个 ≥127K 会话（`tools/repro/kv-long-smoke.py` 可发 120K+ 单请求；多会话并发用面板连发）。看 `strata-iq3_s.log` 的 `verify: timed out` + `KV streaming ... read from RAM`。
- **关键文件**：
  - 配置：`strata-iq3_s.json`（`--kv-resident 131072`、`--conversation-cache-mib 6144`、`--vram-reserve-mib 700`、`--expert-cache auto`）
  - verify 机制：`src/core/verify.cpp`（`Verifier::run` 1390+、`release_gpu_waits`、`#267`）
  - 显存预算/告警：`src/program/generate.cpp:5953-5973`（free-mib 三分支 + 自注）
  - 专家缓存自动缩放：`src/program/generate.cpp:427`（`--expert-cache auto`）
  - 日志：`strata-iq3_s.log`（本次会话从 51330 行起）
  - 闭环脚本：`tools/switch-strata.sh`、`tools/repro/kv-long-smoke.py`
- **dmesg 证据**：`sudo dmesg -T | grep -iE 'xid|nvrm'`（22:03–22:06 段：irq 166 中断风暴 + Xid 31）

---

## 7. 当前机器状态（交接时）

- LLM 已回 **swift15**（ninfer，8088，用户手动拉起）；strata.service **inactive**。
- `strata-iq3_s.json` 停在 `--kv-resident 131072`（方案 A 上限）。
- 方案 B（tier 有序 arena）代码已提交 main，全验收通过；本问题与其**无关**（fill/canary 均正常，故障在 serve 期的 verify 窗口）。

---

## 8. 脚本化复现（2026-10-08 00:09–00:29 新增，三臂）——**故障已复现；两处缓解被证伪**

**工作负载**（`tools/repro/kv-multi-smoke.py`，窗口脚本 `tools/repro/aprime-win.sh`）：**3 个大会话同时发起**（160K / 130K / 100K tokens，`max_tokens 512`），8090 窗口服务器，引擎同生产（P4-B binary）。

| 臂 | 配置 | 100K | 130K | 160K | dmesg |
|---|---|---|---|---|---|
| 1 | max-context 262144 / conv-cache 6144 | OK 27 s | **HTTP 400 @83 s** | 卡死（900 s 客户端超时；GPU 100%、日志静默）| — |
| 2 | 262144 / 3072（A′）| OK 27 s | 卡死（290 s+，人工终止）| 卡死 | — |
| 3 | **393216** / 3072 | OK 27 s | **HTTP 400 @83 s，body 即 `verify: timed out at layer 29 … (#267)`** | 卡死（240 s 超时）| NVRM 中断风暴 + **Xid 31 MMU Fault**（收尾期）|

**结论**：
1. **第 3 臂完整复现生产故障**：`verify: timed out at layer 29; its GPU waits were released but the GPU did not finish within 5 s (#267)` + NVRM 中断风暴 + Xid 31——与 10-07 22:xx 实际使用故障同型。
2. **A′（conv-cache 3072）被证伪**：不避免故障；且实测其代价（第二个大会话被 `evictions=1` 逐出 → 重 prefill 25.4 s）。
3. **加大 KV 池（max-context 393216）也被证伪**：故障照发，且池子够大时引擎并发跑多请求 → verify 图直接被饿死报 #267。
4. **§2.1 的机理需要修正（源码核实，见 §8.1；对照实验见 §8.2）**：触发量**不是**"多会话同时 live"——`--batch 0` 下请求严格串行；也**不是单条大 prompt**——§8.2 实测单条 160K 在两版上都正常。真正相关的是**前序请求留下的状态 + 现版特有的一条路径**（见 §8.2 的根因候选）。
5. 引擎行为两态：**"磨"**（大 prompt 的 KV 流式拷贝 + 显存贴地 → 20×+ 慢，请求挂）或 **"死"**（verify 握手某步 >20 s → `ERR`+`return 1` → 引擎进程退出 → server 重启 → 在途请求全灭）。客户端的 HTTP 400 **就是 #267 错误经 server 映射的结果**（`serve/server.py:3185/3187`），不是参数错误。
6. 复现材料：`tools/repro/aprime-results.txt`（本轮＝臂 3 的数值；臂 1/2 数值见上表）、`tools/repro/aprime-server-maxctx393.log`（#267 原文）、`strata-iq3_s.log` 00:25–00:29 段。

### 8.1 源码对照（2026-10-08，三份代码分析的核心事实）

- **并发**：`serve/server.py:1678,2290` 每请求持进程级 FIFO；引擎 serve 循环一次取一条命令（`src/program/generate.cpp:6484-6492`）；`--batch 0` 时整段读 prompt（`:7164`），"chunk 边界让行"（BYIELD/YIELDED，`:7188-7215`）只存在于 `--batch > 0`。`--batch N` = N 个**启动时预 carve** 的 slot session，各带完整 `max_context`，放不下就整个关掉（`:3013-3031`）。
- **KV 池**（`include/strata/kernels/kv_stream.hpp:1-20` 设计注释）：流式层的**权威 K/V 在 pinned host**（identity 布局），VRAM 是 `n_slots` 页的 **residency map**；每次 attention 前 `kv_stream_resolve` 对选中 block 做 CLOCK 淘汰 + PCIe 拷贝（`src/kernels/cuda/kv_stream.cu:82-158`）；写永远写 host 副本、resident 才写 slot。`--kv-resident` 只决定 VRAM 页数（钳 ≥20480，`layer.cpp:537,556`）；host pinned 副本是**全量**（随 `--max-context`，262144→3.09 GiB / 393216→4.64 GiB）。准入只看静态 `n + max_new + 8 > max_context`（`generate.cpp:6689-6692`），不看别的请求；conversation cache 是主机 RAM 预算，parked 不占 cell，内存不足时只是跳过 park。
- **verify 窗口**（`src/core/verify.cpp`）：doorbell 握手——GPU 每层写 `seq`（`src/kernels/cuda/elementwise.cu:308-326`），host 自旋（`verify.cpp:1444-1479`）后跑 CPU expert pool、发 plan、抬 `flag`，GPU 在 `wait_flag_ge_kernel`（`src/kernels/cuda/verify_kernels.cu:496-499`）空转等。**每（层,组）步的 host 自旋上限是 20 s（`:1467`），不是 5 s**；错误串里的 5 s 是释放旗标后等 stream 排空（`release_gpu_waits(5000)`，`:1472/:1477`；drain 成功会说 "and the GPU finished"）。失败**不可恢复**：`released_=true` 后该 Verifier 拒绝一切后续窗口（`:1396,:1900`），调用方 `ERR`+`return 1`（`generate.cpp:7431-7432`）→ 引擎进程退出 → server `EngineDied` + 重启（`serve/server.py:595`，`RESTART_RETRY_S=15`）。verify 流全是 `cudaStreamNonBlocking`，与主解码流**无优先级、无事件绑定**（`:476-484`）；饱和期没有超时自适应或降级。

### 8.2 2026-10-08 对照实测：**故障是现版引入的回归**；根因候选＝verify 的 DMA 上传路径

**实验**（`tools/repro/p0-160k-win.sh`、`tools/repro/seq-160k-win.sh`；结果 `p0-160k-results.txt`、`seq-160k-results.txt`；全新引擎、单条/两条序贯、`CONC=1`）：

| 场景 | P0 原版（pre-p2 binary + p0 配置，kv-resident 32768）| 现版（P4-B，kv-resident 131072）|
|---|---|---|
| 单条 160K | **OK 33.9 s**（prefill 30374 ms = 5269 tok/s，decode 171.5 tok/s）| OK 40.2 s（36100 ms = 4434 tok/s，146.0 tok/s）|
| 单条 130K | — | OK 32.5 s（28678 ms = 4534.9 tok/s）|
| **100K → 160K 序贯** | **两条全 OK**（22.5 s + 34.8 s，0 超时）| **160K 在 63.2 s 报 `verify: timed out at layer 42 (#267)`** |

- **单条大 prompt 不是触发条件**（两版都跑得动；P0 靠 1.5 GiB KV 流式、89.35% 命中吸收）。同一序列 P0 无恙、现版必死 → **回归是现版引入的**（可 63 秒复现）。
- 现版同口径更慢：160K prefill 4434 vs P0 5269 tok/s（−16%），decode 146 vs 171.5；代价来自专家缓存 11199 vs 11751 槽 + 固定区/借槽封顶；内存收益同时确认（请求后 MemAvailable 17.6 vs 5.5 GiB）。

**根因候选（代码定位）**：`Verifier::fetch_dma`（`src/core/verify.cpp:1621-1630`，注册为 `sink_.fetch`，`verify.cpp:400`）——verify 窗口的 PCIe 份额用 `cudaMemcpyAsync` 从 **arena 专家 blob** 直接 DMA 到 staging，**在 side stream 上异步执行、返回值不检查**；同文件注释写明"the graph waits for it before the PCIe groups"。tier 有序 arena 每层有**两个相邻 Mapped 注册**（固定块/非固定块，边界非 4K 对齐）→ 跨边界的 blob 源被驱动拒收（`invalid argument`，t16 已证实）→ flag B 不落 → verify 图空转 → host 20 s → #267。fill 与 canary 两处同源问题已修（bounce / ceil4k），**这一处没有**；P0 是整块注册、无内部边界 → 永不触发。层号随机、时好时坏 = 看该窗口选中的专家集是否含跨边界 blob。

**下一步**：① t16 式独立程序复现**异步**变体（side stream + 不检查返回值的跨注册拷贝，不需 LLM 窗口）；② `fetch_dma` 加同款 bounce（只影响每层 ~1 个跨界 blob）+ 拷贝失败可见化；③ 复跑 `100K→160K` 验收。

**对修复方向的含意（10-08 按源码修正）**：
- **B（verify 饱和期让位/自适应 deadline）**能消除"死"这一支，不解决"磨"。
- "磨"的根源是**单条大 prompt 的 KV 流式读**（residency map 之外的 block 每次 attention 经 PCIe 补页；实测 100K prompt 已 ~677 MiB），叠加显存贴地（298 MiB free）。抓手：① 提高 `--kv-resident`（VRAM 从专家缓存借；`auto` 会自动缩小专家槽）；② 让 prompt/上下文不超过常驻窗量级；③ 给 verify 加饱和期降级（同 B）。
- **"并发准入/排队"不是方向**（源码证明 `--batch 0` 已严格串行；"并发 live KV"不存在）。**立即可用的运维缓解：单条请求的 prompt/上下文控制在 ≲120K tokens**——实测 100K 无恙、130K/160K 触发（130K 直接 #267，160K 磨死）；超过 residency map（131072 cells）就走 PCIe 流式，风险陡增。

# 交接文档：Strata 专家缓存改造（P0–P4）— 2026-10-07

写给接手的人类工程师。项目背景看 [AGENTS.md](AGENTS.md)、[DETAILS.md](DETAILS.md) 与 [EXPERT_SPLIT_PLAN.md](EXPERT_SPLIT_PLAN.md)；本文只写**现状、证据链、卡点与下一步**，不重复那些文档。

## 1. 项目与机器

- **Strata**：在普通 PC（一张 NVIDIA/AMD 卡 + 系统内存）上跑 Qwen3.8-Flash-Next MoE（48 层 × 512 专家 = 24576 专家）的 C++/CUDA 推理引擎 + Python server（OpenAI/Anthropic 兼容 API，端口 8088）。
- **本机**：RTX 5090 32 GB（可用 31.39 GiB），62 GiB RAM + 8 GiB swap，Ubuntu 24.04，驱动 610.57.04，CUDA 13.0（`/usr/local/cuda-13.0`）。
- **模型**：`/home/ai/Strata-data/packs/iq3_s`（IQ3_S 原生 pack，46.84 GiB 专家 arena）+ PLE 表 `/home/ai/strata-gguf/...00002-of-00002.gguf`（26.8 GiB 文件映射）。
- **服务形态**：二选一占 8088 + 整卡显存——systemd `strata.service`（Strata 引擎）或 Ninfer docker 容器（qwen3.8-27b 等）。两者不共存。
  - 当前（写本文时）：`NInfer-kaushikvira-swift15` Up（healthy，占 8088 + 30.7 GiB VRAM）；`NInfer-kaushikvira-ajgazin` Exited；`strata.service` failed/inactive。

## 2. 研究进展（专家缓存 50/50 改造）

计划全文在 `docs/EXPERT_SPLIT_PLAN.md`，进度：

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 显存专家缓存基线 | 完成（commit da870f9 前） |
| P1 | mmap 专家 arena（门 1 PASS） | 完成 |
| P1.5 | 自适应层验证（hit 96% vs 53–80%） | 完成 |
| P2 | `--expert-cache-fixed 50` 固定/自适应 50/50 分层（`fixed_evict_attempts` 实测恒 0） | 完成（da870f9） |
| P3 | profile per-pack + `.prev` 轮转 + tier 份额遥测（换血 39% 实测） | 完成（da870f9） |
| P4 | 四臂 A/B 对比 | **用户搁置**（改用实际使用测试模式） |
| P4-A | 匿名 arena 选择性注册：GPU 经 PCIe 直接读 host RAM 里的专家（zero-copy），固定区 host 页可归还 | **已实现并提交（9ad8c44），启动验证未完成** |

P4-A 的设计目标：prefill 从 P1 mmap 的 ~3.1k tok/s 回到 ~5.5–6k tok/s（§9.5 验收线）。

## 3. 当前核心问题：P4-A 启动确定性失败（已定位，修复已提交，验证被挡）

### 3.1 现象

引擎启动加载完成后：

```
strata generate: expert arena: PCIe alias registered over 34.87 GiB in 4628 runs; the fixed tier's 6320 experts stay unregistered and releasable
strata generate: the profile fill failed at pair 0: ExpertCache::fill_slot_blocking: invalid argument
```

→ 引擎 exit 1，server 轮询至 ~255 s 截止，`strata.service` failed。多次启动**完全一致（确定性）**。`fill_slot_blocking` 里的 `cudaMemcpy(dst, src, 2176000, HtoD)` 返回**全新** `cudaErrorInvalidValue`。

### 3.2 排除矩阵（全部实测，非推测）

| 假设 | 实验 | 结果 |
|---|---|---|
| 配置子系统引起（vision/mtp/ple/kv-resident/conversation-cache） | 6 变体 bisection（逐个去掉，引擎完整跑） | 全挂，排除 |
| 先前异步 fault 在 fill 时浮现 | fill 前 `cudaDeviceSynchronize()` 探针 | 干净，排除 |
| sticky error | `cudaGetLastError` 探针（fill 前 + 注册后） | 干净，排除 |
| THP 与 pin 交互 | `STRATA_NO_LARGEPAGES=1`（4 KiB 页）跑引擎 | 照挂，排除 |
| 注册段数量本身 | t9 阶梯：干净上下文 8192 段 × 3.3 MiB | 通过，排除 |
| 总 pin 字节（~44 GiB） | t13：24+12 GiB 设备 + 9.14 GiB 预 pin + 4628 段 | 通过，排除 |
| 设备上下文状态（数百分配+流+kernel） | t14：同上 + 512 小分配 + 2 流 + kernel | 通过，排除 |
| 复现形状（引擎完整上下文 + PLE 26.8 GiB 映射 + 256 MiB PCIe 探针） | t15 m1/m48/p1 | **1 段/48 层 Mapped/1 段 plain 全通过** ← 关键 |

`tools/repro/` 下 t7–t15 是这些复现程序（`t15` 是引擎完整上下文形状）。

### 3.3 引擎内取证（fill 失败诊断块，`src/program/generate.cpp`）

- 失败的 src（pair 0 = 排名前 1 = **固定区**，per-blob 版里属**未注册**区）做 HtoD：**任何大小**（含 64 KiB）都报全新 `invalid argument`；
- CPU 读该页正常；`cudaPointerAttributes` 正常（Host 类型）；
- dst 侧全部正常（fresh dst + old src 挂，old dst + fresh src 过）；
- **bounce**：把同一批字节 `memcpy` 到全新 host buffer 再 HtoD → **通过**；
- ~~src 的 4 MiB 窗口 `cudaHostUnregister` 报 `invalid argument`、再注册报 `already mapped`~~ ——（专家审核订正）`cudaHostUnregister` 要求传注册基地址，对区间内子窗口调用**必然**报 `invalid argument`，再注册报 `already mapped` 也是预期行为。该探针**无判别力**，不作为证据；"already mapped" 是外扩页对齐与相邻 run 共享边缘页的假象。

结论（按专家审核订正后的叙述）：失败的 src 在**未注册的固定区**，失败形态是"pageable 源 HtoD 在重上下文 + 内存压力下报全新 InvalidValue，同一批字节经新 pinned buffer 则通过"。指向驱动（610.57.04）在特定上下文状态下对 pageable HtoD 路径（内部 staging）的异常。**尚未复现最小 repro，"驱动 bug" 仍是推断**；record-replay（导出注册序列在 t15 上下文重放）成功之前不向 NVIDIA 提报（专家意见 §2.4-7）。本机 `nvidia-smi -q` 显示 **Addressing Mode = HMM**（5090 + 开源内核模块），`cudaHostRegister` 与 HMM 的交互是首要候选机制，也直接支持"方案 D：不注册、GPU 直读系统内存"的可行性试验。

注册段数约束（**上下文相关，非固定上限**，专家审核订正）：干净上下文 8192 段全过（t9）；引擎重上下文里 4628 段全过、9256 段被拒 ~3900（压缩前会话测得）。三个数字（3900/4628/8192）说明有效容量随上下文状态漂移，是"段数 × 单段大小 × 总字节 × 上下文状态"的共享预算，不是 5300 这样的固定值。

### 3.4 修复（已提交，commit `9ad8c44`）

`ArenaExpertSource::register_pcie_alias`（`src/core/expert_source.cpp`）：

- 注册粒度：逐 blob run（4628 段 × ~8 MiB）→ **每层 1 段、共 48 段、整层 `cudaHostRegisterPortable | cudaHostRegisterMapped`**；
- 48 个 zero-copy 映射离驱动资源上限很远（t15 实测通过）；
- **Mapped** 是 GPU 直接经 PCIe 读专家所必需的（device 侧 zero-copy 映射；纯 pin 只帮 `cudaMemcpy`，不帮 kernel 直接解引用 host 指针）；
- 代价：固定区（~11.2 GiB）随整层 pin 住、会话内不归还。`release()` 对已注册 blob 返回 0、`release_fixed_tier()` 为 no-op（**专家审核订正**：pinned 页上发 `MADV_DONTNEED` 不是"无效"，而是**有害**——内核会丢弃用户侧映射而驱动仍持有旧物理页，再读即读到陈旧数据；故对已注册区不碰，遥测不撒谎）；
- 同 commit 还带诊断探针（fill 失败诊断块、pre-fill sync 探针、sticky 探针）——**已提交**，可保留可清理。

**验证缺口**：部署的二进制 `engine/strata` 还是旧的 per-blob 版本。需要 `ninja -C build strata && cp build/strata engine/strata` 后跑一次 GPU 窗口确认：

```
PCIe alias registered over ~46.8 GiB in 48 per-layer runs
pre-filled 12641/12641 slots   （压缩前会话在 plain 版上已看到过这两行 + READY，Mapped 版尚未实测）
```

**卡点**：`NInfer-kaushikvira-swift15` 占着 8088 + 30.7 GiB VRAM，最近一次窗口里引擎 weight arena 直接 OOM，没跑到注册。需要用户放行一个窗口：**停 swift15 → 跑引擎 → 拉回 swift15**（同一脚本闭环，规则见 §5）。

### 3.5 验证后的收尾（按序）

1. 窗口验证通过 → `sudo systemctl start strata.service`，确认 READY；
2. A/B 测试（对照 §9.5 预期）：prefill ~5.5–6k tok/s；decode 中位数；`fixed evict attempts` 恒 0；RSS ≈ 46.8 pinned + 引擎开销（注意比 P4-A 原设计的 35.6 GiB 高 ~11 GiB，是段数上限的代价）；MemAvailable 会降到 ~4–6 GiB（若太紧，可把 `--conversation-cache-mib 6144` 降到 2048 换 4 GiB）；
3. 把数字记进 `docs/EXPERT_SPLIT_PLAN.md` §9.5；
4. 提交文档改动（当前工作区唯一未提交代码相关文件：`docs/EXPERT_SPLIT_PLAN.md`）；
5. 用户裁定最终服务（Strata vs Ninfer）。

## 4. 未来研究方向

`EXPERT_SPLIT_PLAN.md` §10 已列的明确不做/立项项：

- 100% 显存专家释放 RAM（自适应换入变磁盘读）；
- per-layer 50/50（固定/自适应按层对齐，V1 仅遥测）；
- 多 GPU（`peer_experts`/remote tier）接入固定区；
- `CacheSlot`/`ExpertTier` 数据模型重构（V2）；
- profile 文件头加 model fingerprint（V2）；
- 24 h 全矩阵压测（hot/cold/distribution-shift）。

本次排障新产生的开放问题：

1. **驱动 bug 报告**：610.57.04 下"数千小段 `cudaHostRegister` 在重上下文里使后续 HtoD 报全新 InvalidValue"——**先做 record-replay**（把引擎真实注册序列导出、在 t15 上下文 `tools/repro/t15.cu` 里重放，可独立复现后才向 NVIDIA 提报，专家意见 §2.4-7；"驱动 bug"目前仍是推断）。若 NVIDIA 确认，可考虑升级驱动或永久采用 48 层粒度（当前修复已免疫）。
2. **zero-copy 语义确认**：GPU kernel 直接解引用 Mapped 注册的 host 指针，与 `cudaMemcpy` 路径的性能差未测（P4-A 收益的核心假设；§9.5 A/B 会间接验证）。
3. **固定区 RAM 代价**：48 层整层注册使 ~11.2 GiB 常驻。~~按 128 专家粗化省回大部分固定区 RAM~~（**专家审核订正：算术不成立**——固定密度 25.7%（6320/24576），按 128 专家分块几乎每块都含 ~33 个固定专家，块仍是混合的，一个字节都省不回来）。`MAP_HUGETLB` 是**性能选项**（pin 效率/TLB），不是 RAM 选项（当前 `vm.nr_hugepages=0`，走 THP fallback）。真正能省回 ~11 GiB 的路径是**方案 B：arena 按 tier 重排**（固定区连续成块、只注册非固定块、对固定块 DONTNEED），专家审核背书为首选结构方向，待立项。
4. P4 四臂对比（用户搁置）随时可恢复。

## 5. 操作注意事项（重要规则）

- **LLM 窗口规则**：本 AI 会话自身跑在 8088 的 LLM 服务上。任何停 LLM 的操作，**停与拉必须在同一脚本内闭环**（`trap` 兜底 + 显式 `docker start` 收尾），且**停之前先征求用户同意**。参考脚本：`/tmp/mmtest/fixwin.sh`、`/tmp/mmtest/t15win.sh`（模式：`docker stop` → 实验 → `pkill` 清理 → `docker start`）。
- 服务切换：`tools/switch-llm.sh strata|ninfer|restart|status`；strata 侧 `sudo systemctl stop/start strata`（`Restart` 会自动拉起，kill 无效）。
- 构建：`.venv/bin/ninja -C build strata`；部署：`cp build/strata engine/strata`。
- 引擎手动跑：`env STRATA_TRACE_ADAPT=1 engine/strata --serve <strata-iq3_s.json 的 args>`（cwd `/home/ai/Strata`）。
- 备份：`engine/strata.pre-p4`、`engine/strata.pre-p4b`、`strata-iq3_s.json.pre-p4`、`strata-iq3_s.json.p0-backup`。
- 复现程序已存档到 `tools/repro/`（t7–t15 的 .cu 与 bisection 脚本，15 个文件；`/tmp/mmtest/` 里的原件临时目录会丢，以 `tools/repro/` 为准）。重要结论已进 §9.5 与本文。

## 6. 关键文件索引

| 文件 | 内容 |
|---|---|
| `src/core/expert_source.cpp` `register_pcie_alias`（~3046 行起） | 48 层 Mapped 注册（9ad8c44） |
| `src/core/expert_source.cpp` `release`/`release_fixed_tier` | pinned 页的 no-op 语义 |
| `src/program/generate.cpp` ~3500–3640 行 | fill 调用 + 失败诊断块（指针二分、bounce、unregister 探针） |
| `src/core/expert_cache.cpp` `fill_slot_blocking` | sticky 探针 + pending error 报告 |
| `src/core/pinned.cu` ~200–248 行 | arena 分配（`STRATA_NO_LARGEPAGES` 开关） |
| `docs/EXPERT_SPLIT_PLAN.md` §9.5 | 完整计划 + 失败/修复记录（有未提交更新） |
| `/home/ai/Strata/strata-iq3_s.json` | 现网配置（gitignored） |

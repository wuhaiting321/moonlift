# ACCEPTANCE — 官方验收对照表

> 一句话：本表把官方的每一条要求映射到仓库里**一个可执行的命令**和**一份可审阅的文件**。
> 凡是命令跑不出来的数字，都不写进申报书。
> 复现总入口：`bash script/check.sh` → `ALL GREEN`（无需联网、无需 C 工具链）。
> 最近一次整改（2026-11-23）：实现 `call_indirect` 与四类导入，数字全部按整改后重测。

## 1. 官方验收 6 条（逐条核对）

| # | 官方要求 | 本仓库的证据 | 复现命令 | 状态 |
|---|---|---|---|---|
| 1 | **MoonBit 为主** | 15,671 行 MoonBit 源码（`core/` 13,987 + `runtime/` 1,218 + `cmd/` 466），8 个 `_wbtest.mbt` 共 162 个白盒用例；CLI、解码器、分析器、代码生成器、调用计划全部用 MoonBit 写；生成物也是 MoonBit 包 | `find core runtime cmd -name '*.mbt' \| xargs wc -l`；`moon test --target wasm-gc` | ✅ |
| 2 | **仓库公开** | 已公开：`https://github.com/wuhaiting321/moonlift`（PUBLIC，默认分支 `master`）；全部提交的作者与提交者统一为 `wuhaiting321 <19177746962@163.com>` | `gh repo view wuhaiting321/moonlift --json visibility,defaultBranchRef` | ✅ |
| 3 | **能够运行** | `info` / `disasm` / `decompile` / `verify` 四个子命令在 `wasm-gc`、`js`、`wasm` 三端输出逐字节一致；生成包 `moon check` 零错误零告警；GitHub Actions 在每次推送时复跑同一套门禁并全部通过 | `bash script/check.sh`（cross-target 段）；`bash script/demo.sh`；仓库页 Actions 标签 | ✅ |
| 4 | **工作有效** | 44 个模块全部反编译成可编译包；498 个调用与 Node 跑原件的值逐一比对，498 匹配、0 失败；150 个间接调用用例值/陷阱对拍；5 条共享导入属性；31 个真实编译器产物端到端通过 | `bash script/verify.sh`；`bash script/extended.sh` | ✅ |
| 5 | **开源合规** | Apache-2.0（`LICENSE`）；`NOTICE` 标注格式与算法参考来源；`corpus/PROVENANCE.md` 说明 44 个 `.wasm` 的来源、许可证与 SHA-256（`corpus/good/SHA256SUMS`、`corpus/extended/SHA256SUMS`）；所有夹具均为自制或 MoonBit 编译器产出，无第三方二进制 | `cat NOTICE`；`cat corpus/PROVENANCE.md` | ✅ |
| 6 | **AI 可解释** | `docs/AI_USAGE.md` 逐项说明 AI 参与了什么、人做了什么决策、每个 AI 产出如何被独立验证；`docs/DESIGN.md` 记录每个关键取舍及被否方案；`PLAN.md` 保留实测基线与计划偏差 | `cat docs/AI_USAGE.md` | ✅ |

## 2. 官方评分 4×25 的证据落点

| 维度 | 主要证据 | 为什么算得上 |
|---|---|---|
| **工程深度与实现强度** | 8 层流水线（reader → section → instr → cfg → stack → struct → emit → runtime）；15,671 行 MoonBit；162 单测；25 步门禁 | 每一层都是独立模块 + 独立测试，不是把 wasm 打印成文本了事 |
| **技术贡献与攻关** | 构造树结构化 + `brk` 逐层解绕（`docs/DESIGN.md` §3.2/3.3）；`call_indirect` 的"表 + 每签名一个 dispatcher"（`docs/INDIRECT_CALL.md`）；导入绑定与别名保持（`docs/SHARING.md`）；边值在前驱写入（D12）；三类重排隐患的强制溢出；位级浮点 helper | 解决的都是"能编译但算错"的问题，附被否方案与实测依据 |
| **生态增量** | mooncakes.io 全量 3,882 模块检索 `decompiler`/`wasm2mbt`/`wasm2c` 命中 0；GitHub `moonbit+decompiler` `total_count = 0`；产出是三端可用的**迁移通道**而非又一个解析库 | 检索结论按"可检索范围内未发现直接重复实现"表述，不声称 100% 无人做过 |
| **开发与验证能力** | wabt 逐指令对拍 4,585/4,585；差分验证 498/498；间接调用 150 用例双向对拍；三端逐字节一致；31 个真实编译器产物；每个数字都被门禁钉住 | 判据是"与独立实现对比"，不是"自己跑通" |

## 3. MVP 契约 M1–M5（PLAN.md §3）逐条结算

| 编号 | 原判据 | 实际结果 | 说明 |
|---|---|---|---|
| **M1** | `info` 对语料 100% 不 panic；非法输入 100% 返回 `E0xx` + 字节偏移 | **63/63**（44 个良构 + 19 个畸形）全部按预期处理；畸形样本按文件名报出错误码与偏移 | ✅ 达成 |
| **M2** | ≥95% 模块生成物 `moon check` 零报错 | **44/44 = 100%**，且**零告警**（12 个自制夹具 + 1 个 20 KB 主产物 + 31 个编译器产物） | ✅ 超出（把告警也纳入判据） |
| **M3** | 导出函数随机输入差分，case 通过率 ≥99%，trap 也算可比较观测值 | **498 个可比较调用 498 匹配、0 失败**；另有 237 个调用因原件 trap / NaN **被跳过并单列**；间接调用的三类陷阱由 `script/indirect.sh` 单独对拍（150 用例） | ⚠️ **有意收缩**：见 BOUNDARY §4.19。MoonBit 的 `trap` 是 abort 不是可捕获错误，无法在生成测试里观测；浮点按精确位比较、不放宽到 1 ULP；未比对调用后的线性内存哈希。这三项都写进边界而不是藏在"100% 通过"里 |
| **M4** | 生成代码在 `wasm` / `wasm-gc` / `js` 三端实跑，结果逐位一致；某端编译不过要记录跳过原因 | `info`、`--ops`、`--cfg`、`--stack`、`--struct`、`calls.tsv` 在**三端逐字节一致**；项目自身单测在 `wasm-gc` 与 `js` 双端通过；生成包的 `moon check` 在三端通过，行为测试在 `wasm-gc` 实跑 | ⚠️ **部分达成**：三端一致性的证据是 CLI 分析输出与编译，生成包的**行为**测试只在 `wasm-gc` 跑（js/wasm 未跑行为测试）。native 后端因本机缺 MSVC 未验证，已在 BOUNDARY §4.2 记录原因 |
| **M5** | `bash script/demo.sh` 从零跑完 info→decompile→verify 并打印指标表 | 已实现：`bash script/demo.sh` 五步演示 + 实时测量指标表；完整门禁是 `bash script/check.sh` | ✅ 达成 |

M3 / M4 的两处收缩是**明确申报的边界**，不是遗漏。`docs/DESIGN.md` §5 与 `BOUNDARY.md` §4 说明了原因和影响面。

## 4. 仓库公开（已完成）

项目已推送到 `https://github.com/wuhaiting321/moonlift`（PUBLIC，默认分支 `master`）。

推送前做了三件事，记录在此以便复核：

1. `moon.mod` 的 `name` 改为 `wuhaiting321/moonlift`，`repository` 指向仓库 URL；`cmd/main/moon.pkg` 的包引用同步改名；
2. git 身份由占位值 `moonlift-dev` 改为 `wuhaiting321 <19177746962@163.com>`，**全部 16 个提交的作者与提交者一并改写**，公开后的历史里没有占位身份；
3. 改名后重跑 `bash script/check.sh` → `ALL GREEN`（与改名前的数字一致），确认模块名变更没有引入回归。

`git remote -v` 现在为：

```
origin  https://github.com/wuhaiting321/moonlift.git (fetch)
origin  https://github.com/wuhaiting321/moonlift.git (push)
```

## 4.1 初审整改（2026-11-23，已完成）

初审意见：*"范围明确排除 WebAssembly 1.0 的基本间接调用行为，无法满足所选标准的完整语义目标。"*

该意见成立，整改分三块，全部落地并有门禁证据：

| 块 | 内容 | 证据 |
|---|---|---|
| P0-1 | `call_indirect` 端到端：`ECallIndirect` IR、按签名分组的 dispatcher、三类陷阱 | `table.wasm` 4 生成 / 2 拒绝 → **6 / 0**；真实 20 KB 产物 72 / 6 → **75 / 3**；新增 150 用例值/陷阱对拍 |
| P0-2 | README 第三节改为 **1.0 逐项对照矩阵**（13 项），不再自称"MVP 子集" | README §3.1 |
| P1 | 四类导入（函数 / 内存 / 表 / 全局）+ `global.get` 作段偏移 + 至多一张表 | `imported.wasm` 8 生成 / 0 拒绝；`script/verify.sh` 覆盖该类模块（7 个调用双向一致） |
| P0-3 | 迁移前后行为与人工接入步骤成文 | `docs/INDIRECT_CALL.md`、`docs/IMPORTS.md` |

数字变化：对拍 4,485 → **4,575**；差分 384 → **481**；块覆盖 395 → **400**；单测 152 → **162**；语料 41 → **43**。

## 4.2 第二轮初审整改（2026-11-25，已完成）

第二轮意见：*"将导入状态改为独立对象并要求预填，未覆盖共享实例的必要语义。请说明如何绑定和保持共享导入，并用同一可变全局被导入两次的读写案例解释迁移前后行为。"*

该意见成立，且是可复现的 bug 而不是表述问题：同一 `(module, name)` 导入两次会生成两个 `Ref`，写 `$a` 读 `$b` 恒为 0。整改四块：

| 块 | 内容 | 证据 |
|---|---|---|
| P0-1 | 导入由"物化成本地副本 + 宿主预填"改为**绑定**：`MoonliftExterns` + `moonlift_bind()`，生成代码直接用宿主给的对象 | `docs/SHARING.md` §3；生成包里能看到 `__ml_externs.val.env_mem` |
| P0-2 | 绑定记录按 `(module, name)` **去重**，别名结构性成立 | `alias.wasm`：两个 import 条目 → 一个 `env_counter` 字段；`sharing.sh` 5 条属性 |
| P0-3 | 全部段挪到 `moonlift_init()` 铺到当前绑定实例，且每个实例只铺一次（`__ml_pending`） | "先 bind 不 init 读到 0；bind 后 init 读到 97"；`memory.wasm` 49 调用回到 49/49 |
| P0-4 | 评审索要的"绑定方式 + 迁移前后行为"成文，含同一可变全局导入两次的六行对照 | `docs/SHARING.md` §1–§5；`docs/IMPORTS.md` 重写 |

数字变化：差分 481 → **498**；对拍 4,575 → **4,585**；语料 43 → **44**；源码 15,323 → **15,671**。

整改中被门禁抓到并修掉的两个真 bug：

1. 常量段偏移被 `const_of_global` 当成 0（只处理了 `global.get`）——`memory.wasm` 49 个调用一起错，是差分从 481 掉到 425 露出来的。
2. 段移到 init 后，`moonlift_init()` 每次调用都重铺，把模块写过的内存盖回段的初始值——`floats(7)` 一个值错，是单条 `expect` 失败露出来的。修法是"每个实例只实例化一次"。

## 5. 三分钟复现路径（评委视角）

```bash
git clone https://github.com/wuhaiting321/moonlift && cd moonlift
bash script/demo.sh        # info → struct-stats → decompile → moon check → verify → 指标表
bash script/check.sh       # 完整门禁，ALL GREEN
cat BOUNDARY.md            # 支持矩阵 / 14 条语义偏差 / 19 条已知限制
cat docs/ACCEPTANCE.md     # 本表
cat README.md             # 项目申报书（见 README 顶部）
```

**环境**：MoonBit 工具链 `0.1.20261020`（`moon check` 首次会联网拉取 `moonbitlang/x@0.5.6`）；Node 用于差分验证；`wabt` 是**可选**的对比工具，未安装时 `verify_decode.js` 打印 `SKIP`，演示脚本会注明，门禁把它记为 skipped 而不是失败。

**CI**：`.github/workflows/ci.yml` 在每次推送时用 ubuntu runner 复跑 `bash script/check.sh`，先 `moon update` 拉取 registry 索引（全新 runner 没有索引，否则解析不到 `moonbitlang/x`），再安装 `wabt` 做解码对拍。CI 用当前 release 工具链而非 `0.1.20261020`（后者已不再由 CDN 提供），因此它同时也是一次向前兼容检查——当前工具链对整数→浮点转换的弃用告警就是这样被发现并修掉的。

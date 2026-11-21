# ACCEPTANCE — 官方验收对照表

> 一句话：本表把官方的每一条要求映射到仓库里**一个可执行的命令**和**一份可审阅的文件**。
> 凡是命令跑不出来的数字，都不写进申报书。
> 复现总入口：`bash script/check.sh` → `ALL GREEN`（约 3.5 分钟，无需联网、无需 C 工具链）。

## 1. 官方验收 6 条（逐条核对）

| # | 官方要求 | 本仓库的证据 | 复现命令 | 状态 |
|---|---|---|---|---|
| 1 | **MoonBit 为主** | 14,383 行 MoonBit 源码（`core/` 12,699 + `runtime/` 1,218 + `cmd/` 466），12 个 `_wbtest.mbt` 共 152 个白盒用例；CLI、解码器、分析器、代码生成器、调用计划全部用 MoonBit 写；生成物也是 MoonBit 包 | `find core runtime cmd -name '*.mbt' \| xargs wc -l`；`moon test --target wasm-gc` | ✅ |
| 2 | **仓库公开** | 已公开：`https://github.com/wuhaiting321/moonlift`（PUBLIC，默认分支 `master`，158 个文件）；16 个提交的作者统一为 `wuhaiting321 <19177746962@163.com>` | `gh repo view wuhaiting321/moonlift --json visibility,defaultBranchRef` | ✅ |
| 3 | **能够运行** | `info` / `disasm` / `decompile` / `verify` 四个子命令在 `wasm-gc`、`js`、`wasm` 三端输出逐字节一致；生成包 `moon check` 零错误零告警 | `bash script/check.sh`（cross-target 段）；`bash script/demo.sh` | ✅ |
| 4 | **工作有效** | 41 个模块全部反编译成可编译包；384 个调用与 Node 跑原件的值逐一比对，384 匹配、0 失败；11 个行为测试；31 个真实编译器产物端到端通过 | `bash script/verify.sh`；`bash script/extended.sh` | ✅ |
| 5 | **开源合规** | Apache-2.0（`LICENSE`）；`NOTICE` 标注格式与算法参考来源；`corpus/PROVENANCE.md` 说明 41 个 `.wasm` 的来源、许可证与 SHA-256（`corpus/good/SHA256SUMS`、`corpus/extended/SHA256SUMS`）；所有夹具均为自制或 MoonBit 编译器产出，无第三方二进制 | `cat NOTICE`；`cat corpus/PROVENANCE.md` | ✅ |
| 6 | **AI 可解释** | `docs/AI_USAGE.md` 逐项说明 AI 参与了什么、人做了什么决策、每个 AI 产出如何被独立验证；`docs/DESIGN.md` 记录每个关键取舍及被否方案；`PLAN.md` 保留实测基线与计划偏差 | `cat docs/AI_USAGE.md` | ✅ |

## 2. 官方评分 4×25 的证据落点

| 维度 | 主要证据 | 为什么算得上 |
|---|---|---|
| **工程深度与实现强度** | 8 层流水线（reader → section → instr → cfg → stack → struct → emit → runtime）；14,383 行 MoonBit；152 单测；22+ 步门禁 | 每一层都是独立模块 + 独立测试，不是把 wasm 打印成文本了事 |
| **技术贡献与攻关** | 构造树结构化 + `brk` 逐层解绕（`docs/DESIGN.md` §3.2/3.3）；边值在前驱写入（D12）；三类重排隐患的强制溢出；位级浮点 helper | 解决的都是"能编译但算错"的问题，附被否方案与实测依据 |
| **生态增量** | mooncakes.io 全量 3,882 模块检索 `decompiler`/`wasm2mbt`/`wasm2c` 命中 0；GitHub `moonbit+decompiler` `total_count = 0`；产出是三端可用的**迁移通道**而非又一个解析库 | 检索结论按"可检索范围内未发现直接重复实现"表述，不声称 100% 无人做过 |
| **开发与验证能力** | wabt 逐指令对拍 4,485/4,485；差分验证 384/384；三端逐字节一致；31 个真实编译器产物；每个数字都被门禁钉住 | 判据是"与独立实现对比"，不是"自己跑通" |

## 3. MVP 契约 M1–M5（PLAN.md §3）逐条结算

| 编号 | 原判据 | 实际结果 | 说明 |
|---|---|---|---|
| **M1** | `info` 对语料 100% 不 panic；非法输入 100% 返回 `E0xx` + 字节偏移 | **60/60**（41 个良构 + 19 个畸形）全部按预期处理；畸形样本按文件名报出错误码与偏移 | ✅ 达成 |
| **M2** | ≥95% 模块生成物 `moon check` 零报错 | **41/41 = 100%**，且**零告警**（10 个自制夹具 + 31 个编译器产物） | ✅ 超出（把告警也纳入判据） |
| **M3** | 导出函数随机输入差分，case 通过率 ≥99%，trap 也算可比较观测值 | **384 个可比较调用 384 匹配、0 失败**；另有 164 个调用因原件 trap / NaN **被跳过并单列** | ⚠️ **有意收缩**：见 BOUNDARY §4.19。MoonBit 的 `trap` 是 abort 不是可捕获错误，无法在生成测试里观测；浮点按精确位比较、不放宽到 1 ULP；未比对调用后的线性内存哈希。这三项都写进边界而不是藏在"100% 通过"里 |
| **M4** | 生成代码在 `wasm` / `wasm-gc` / `js` 三端实跑，结果逐位一致；某端编译不过要记录跳过原因 | `info`、`--ops`、`--cfg`、`--stack`、`--struct`、`calls.tsv` 在**三端逐字节一致**；项目自身单测在 `wasm-gc` 与 `js` 双端通过；生成包的 `moon check` 在三端通过，行为测试在 `wasm-gc` 实跑 | ⚠️ **部分达成**：三端一致性的证据是 CLI 分析输出与编译，生成包的**行为**测试只在 `wasm-gc` 跑（js/wasm 未跑行为测试）。native 后端因本机缺 MSVC 未验证，已在 BOUNDARY §4.2 记录原因 |
| **M5** | `bash script/demo.sh` 从零跑完 info→decompile→verify 并打印指标表 | 已实现：`bash script/demo.sh` 五步演示 + 实时测量指标表；完整门禁是 `bash script/check.sh` | ✅ 达成 |

M3 / M4 的两处收缩是**明确申报的边界**，不是遗漏。`docs/DESIGN.md` §5 与 `BOUNDARY.md` §4 说明了原因和影响面。

## 4. 仓库公开（已完成）

项目已推送到 `https://github.com/wuhaiting321/moonlift`（PUBLIC，默认分支 `master`）。

推送前做了三件事，记录在此以便复核：

1. `moon.mod` 的 `name` 改为 `wuhaiting321/moonlift`，`repository` 指向仓库 URL；`cmd/main/moon.pkg` 的包引用同步改名；
2. git 身份由占位值 `moonlift-dev` 改为 `wuhaiting321 <19177746962@163.com>`，**全部 16 个提交的作者与提交者一并改写**，公开后的历史里没有占位身份；
3. 改名后重跑 `bash script/check.sh` → `ALL GREEN`（4,485/4,485 对拍、395/395 块、384/384 差分，与改名前的数字一致），确认模块名变更没有引入回归。

`git remote -v` 现在为：

```
origin  https://github.com/wuhaiting321/moonlift.git (fetch)
origin  https://github.com/wuhaiting321/moonlift.git (push)
```

## 5. 三分钟复现路径（评委视角）

```bash
git clone https://github.com/wuhaiting321/moonlift && cd moonlift
bash script/demo.sh        # info → struct-stats → decompile → moon check → verify → 指标表
bash script/check.sh       # 完整门禁，ALL GREEN
cat BOUNDARY.md            # 支持矩阵 / 13 条语义偏差 / 19 条已知限制
cat docs/ACCEPTANCE.md     # 本表
cat README.md             # 项目申报书（见 README 顶部）
```

**环境**：MoonBit 工具链 `0.1.20261020`（`moon check` 首次会联网拉取 `moonbitlang/x@0.5.6`）；Node 用于差分验证；`wabt` 是**可选**的对比工具，未安装时 `verify_decode.js` 打印 `SKIP`，演示脚本会注明，门禁把它记为 skipped 而不是失败。

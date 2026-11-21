# moonlift 项目申报书

[![CI](https://github.com/wuhaiting321/moonlift/actions/workflows/ci.yml/badge.svg)](https://github.com/wuhaiting321/moonlift/actions/workflows/ci.yml)

> 2026 MoonBit Hackathon（11 月赛）
> 本文档同时是仓库 README。文中每个数字都可由 `bash script/check.sh` 复现；跑不出来的数字不写。

## 一、基本信息

| 项 | 内容 |
|---|---|
| 项目名称 | **moonlift — Wasm 字节码到可编译 MoonBit 源码的反编译器** |
| 参与者 | 吴海婷 |
| 联系方式 | 19177746962@163.com |
| GitHub 仓库链接 | https://github.com/wuhaiting321/moonlift |
| 项目方向 | 开发者工具 / 编译器基础设施 / WebAssembly 生态迁移 |
| 是否为移植项目 | **否**，原创项目（与既有开源项目的关系见第六、七节） |

## 二、项目简介

MoonBit 的 `wasm-gc` / `js` 后端无法链接 C FFI，大量存量 C/Rust 生态到不了这两个后端。反编译是唯一能把既有 `.wasm` 产物变成三端可用 MoonBit 源码的通道——moonlift 做的不是"又一个 wasm 解析库"，而是一条**迁移通道**。

moonlift 读取一个 MVP 子集的 `.wasm` 文件，依次完成：字节读取 → 12 个段 → 172 条 MVP 指令 → 基本块 / 控制流图 → 类型化栈模拟与表达式重建 → 构造树结构化 → MoonBit 代码生成 → 差分验证，最终写出一个 6 文件的 MoonBit 包，`moon build` 直接可编译。

正确性不靠自证：解码器与 wabt 逐指令对拍 **4,485 / 4,485 一致**；41 个模块的生成包全部 `moon check` **零错误且零告警**；**384 个调用**在生成代码与 Node 跑原始 wasm 之间逐一比对，**384 匹配、0 失败**；20 KB 真实编译器产物 **395 / 395 可达块**各产出一次。一键门禁 `bash script/check.sh` → `ALL GREEN`。

## 三、项目方向与通用性说明

**方向定位**：把 WebAssembly 当作"可读的中间产物"，为 MoonBit 生态补上"二进制 → 源码"这一环，让既有 wasm 资产在 `wasm` / `wasm-gc` / `js` 三端重新可维护。

**通用性说明**：

- **不绑定业务**：输入是标准 wasm 二进制，输出是标准 MoonBit 包，没有游戏、UI、特定领域假设。
- **后端无关**：生成代码在三端编译；`info` / `--ops` / `--cfg` / `--stack` / `--struct` / `calls.tsv` 的输出在三端**逐字节一致**。
- **可嵌入**：核心是 `core/` 库（解码、CFG、栈模拟、结构化、代码生成、调用计划），CLI 只是薄壳，可被构建工具、IDE 插件、CI 复用。
- **边界可预期**：对不支持的特性**逐函数**报稳定错误码 + 绝对字节偏移，并生成 trap 桩；不会整模块失败，也不会静默算错。
- **不承诺"任意 wasm 都能还原成漂亮源码"**：接受子集明确（wasm v1 + MVP 指令 + 符号扩展 + 部分批量内存），拒绝面明确（GC / 引用类型、SIMD、原子、异常、尾调用、多内存、多值、`call_indirect` 等）。这是工程可验收的前提，也是本项目与"演示级反编译器"的区别。

**与"解析库"的区别**：解析器只回答"这条指令是什么"；moonlift 回答"这段程序等价于什么 MoonBit 代码"，并用独立实现（wabt、Node 跑原件）验证等价性。

## 四、预期使用场景

### 场景 1：把 C/Rust 存量 wasm 模块迁到 wasm-gc / js

- **背景**：团队有一个 C 写的算法库，已编译成 `.wasm`，但 MoonBit 的 `wasm-gc` / `js` 后端贴不了 C FFI，无法直接复用。
- **输入**：`lib.wasm`（MVP 子集）。
- **步骤**：`moonlift info lib.wasm` 看段 / 函数 / 导入 → `disasm --stats` 看指令覆盖 → `decompile lib.wasm -o lib_mbt/` 生成包 → `moon check` → `bash script/verify.sh lib.wasm` 对比行为。
- **输出**：一个不依赖宿主、可在三端编译的 MoonBit 包；被拒绝的函数有函数名、错误码、字节偏移和 trap 桩，迁移工作量可估算。
- **价值**：从"整库重写"变成"生成 + 定点修补"。

### 场景 2：第三方 wasm 构件的审计与理解

- **背景**：供应链引入了一个来源不明的 `.wasm`，需要知道它做什么、有没有异常控制流。
- **步骤**：`info` 看导入 / 导出 / 内存 / 数据段 → `disasm --cfg` 看块、支配关系、自然循环、可归约性 → `disasm --stack` 看每块恢复出的表达式（同一遍也是类型检查）→ `disasm --struct` 看结构化后的 `while` / `if` / `match`。
- **输出**：可读的控制流与表达式，而不是字节偏移；不可达块**保留并标记**，不静默丢弃。
- **价值**：审计结论可复核；分析器对畸形输入给出稳定错误码和偏移，而不是崩溃。

### 场景 3：编译器教学与 wasm 语义研究

- **背景**：讲"wasm 的 `block` / `loop` / `br` 如何对应结构化语言"，或研究某个编译器的代码生成策略。
- **步骤**：用 `--struct` 观察 `block` → 一次性 `while true`、`loop` → 真循环、跨层 `br` → `brk` 逐层解绕、`br_table` → `match`；用 `--stack` 观察重排隐患如何被强制溢出。
- **输出**：同一函数的 wasm、CFG、表达式、结构化源码四种视图，可并排讲解。
- **价值**：把"反编译"变成可演示的教学材料，每个结论都有对应命令。

### 场景 4（附加）：CI 中的 wasm 依赖行为快照

- 把 `verify` 的调用计划 + Node oracle + 生成包测试接进 CI，wasm 依赖每次升级都跑同一批调用，行为漂移立即失败。
- **价值**：把"反编译正确性"变成可回归的工程指标，而不是一次性演示。

## 五、拟实现的核心功能（均已实现并通过验证）

| # | 核心功能 | 实现状态 | 验证方式 |
|---|---|---|---|
| 1 | **模块解析 `info`**：12 个段（type / import / function / table / memory / global / export / start / element / code / data / datacount），段顺序按规范等级校验 | 已实现 | 41 个良构模块 + 19 个畸形样本全部按预期处理 |
| 2 | **指令解码 `disasm`**：172 条 MVP 指令、29 种指令形态，`.wat` 风格列出；未知操作数长度的前缀（SIMD / 原子）停止并标记 partial body | 已实现 | 与 wabt 独立对拍 **4,485 / 4,485 一致，0 不符** |
| 3 | **控制流分析 `--cfg`**：基本块、边、支配树、自然循环、Hecht–Ullman 可归约判定；不可达块保留并标记 | 已实现 | 每个夹具 / 真实产物全部输出，78 / 78 完整函数可归约 |
| 4 | **类型化栈模拟与表达式重建 `--stack`**：逐块模拟操作数栈、恢复表达式树，同遍完成类型检查；三类重排隐患强制溢出 | 已实现 | 真实产物 72 个主体、111 次溢出（110 强制 + 1 隐患） |
| 5 | **结构化控制流 `--struct`**：走 wasm 自带构造树，`block`→一次性 `while true`、`loop`→真循环、跨层 `br`→`brk` 逐层解绕、`br_table`→`match` | 已实现 | `blocks emitted 395 / 395`；输出中无裸 `br` / `br_if` / `br_table` / `if (...)` |
| 6 | **MoonBit 代码生成 `decompile`**：写出 `moon.mod` / `moon.pkg` / `module.mbt` / `funcs.mbt` / `exports.mbt` / `runtime.mbt` 六文件包；拒绝的函数生成真实签名 + trap 桩 | 已实现 | 41 / 41 生成包 `moon check` 零错误零告警；真实产物 79 个函数定义（72 主体 + 7 桩） |
| 7 | **差分验证 `verify`**：生成调用计划 `calls.tsv`，由 Node 跑原始模块出答案，再在生成包内生成 `inspect` 测试并运行比对 | 已实现 | **384 个调用、384 匹配、0 失败**；164 个 trap / NaN 跳过并单列 |
| 8 | **三端一致与一键门禁**：`wasm-gc` / `js` / `wasm` 全量对照；格式、编译、单测、语料、反编译、差分、扩展语料一条命令跑完 | 已实现 | `bash script/check.sh` → `ALL GREEN`，约 3.5 分钟，离线 |
| 9 | **语料与溯源**：41 个 `.wasm`（10 个自制夹具 + 31 个 MoonBit 编译器真实产物），逐文件 SHA-256 + 来源说明 | 已实现 | `corpus/good/SHA256SUMS`、`corpus/extended/SHA256SUMS`、`corpus/PROVENANCE.md` |

## 六、是否为原创项目、移植项目或参考已有开源项目

**本项目为原创项目，不是移植项目，也不是对某个已有开源项目的复刻。**

依据：

1. **生态检索结论**：截至 2026-11-20，在 mooncakes.io 全量 **3,882 个模块**、GitHub / Gitee 与已报名项目等**可检索范围内**，未发现 `decompiler` / `wasm2mbt` / `wasm2c` 的直接重复实现；GitHub `moonbit+decompiler` 的 `total_count` 为 **0**。这是对"可检索表面"的陈述，不声称 100% 无人做过。
2. **结构化算法自研**：没有采用 Relooper。实测 wasm 的分支只能指向外层标签，因此可归约性由格式本身保证（78 / 78 完整函数可归约），走 wasm 自带的 `block` / `loop` / `if` 构造树即可，无需把 `if` 变成状态机。被否方案与理由记录在 `docs/DESIGN.md` §3.2。
3. **验证框架自研**：MoonBit 出调用计划 → Node 跑**原始 wasm** → bash 在生成包内生成测试并运行，三方拆分，两边不是同一套实现。
4. **没有代码复制**：未从 wabt、Binaryen、Emscripten 或任何上游项目复制源码；`NOTICE` 逐项标注规范与工具的参考方式。

## 七、参考项目、来源链接与许可证

本项目**不是移植项目**，仅在"规范定义"和"独立对拍"层面参考以下公开资源：

| 参考对象 | 来源链接 | 许可证 | 参考方式 |
|---|---|---|---|
| WebAssembly Core Specification | https://www.w3.org/TR/wasm-core-1/ | W3C Recommendation | 二进制格式与指令语义的规范定义；只实现行为，不复制文本 |
| wabt（WebAssembly Binary Toolkit） | https://github.com/WebAssembly/wabt | Apache-2.0 | 作为**独立实现**对拍解码结果；不复制代码 |
| MoonBit 工具链 / 标准库 | https://www.moonbitlang.com | 官方工具链 | 目标后端与语料产出 |

- **本项目许可证：Apache-2.0**（见 `LICENSE`）。
- 第三方归属逐项标注于 `NOTICE`；语料来源、许可证与 SHA-256 见 `corpus/PROVENANCE.md`。
- 41 个 `.wasm` 全部自制或由 MoonBit 编译器产出，**无第三方二进制**。

## 八、完成情况（实测于 2026-11-21）

以下指标均可在仓库内自行复现，验收要求的达成情况以实际仓库内容为准。

### 8.1 实测指标

| 指标 | 结果 | 复现命令 |
|---|---|---|
| MoonBit 源码行数（要求 ≥500） | **14,383**（生产 11,964 + 测试 2,419） | `find core runtime cmd -name '*.mbt' \| xargs wc -l` |
| 白盒单测 | **152 / 152**，`wasm-gc` 与 `js` 双端通过 | `moon test --target wasm-gc` |
| 语料模块 | **41**（10 自制 + 31 真实编译器产物） | `ls corpus/good/*.wasm corpus/extended/*.wasm \| wc -l` |
| 畸形样本按码 + 偏移拒绝 | **19 / 19** | `bash script/check.sh` |
| 解码器 vs wabt | **4,485 / 4,485 一致，0 不符**（62 条 SIMD 按设计不尝试） | `node corpus/tools/verify_decode.js` |
| 真实 20 KB 产物结构化 | **395 / 395** 可达块各产出一次；72 / 79 主体结构化、6 按名拒绝、1 跳过、**0 判为非法** | `moon run cmd/main -- disasm corpus/good/moonbit_fib.wasm --struct-stats` |
| 生成包可编译率 | **41 / 41，零错误且零告警** | `bash script/check.sh` + `bash script/extended.sh` |
| 行为差分 vs 原件（Node） | **384 个调用，384 匹配，0 失败**；164 个 trap / NaN 跳过单列 | `bash script/verify.sh` |
| 生成包行为测试 | **11 个**（control 6 / fib 3 / nested 2），期望值来自原件 | `bash script/check.sh` 冒烟段 |
| 三端一致性 | 6 类输出在 `wasm-gc` / `js` / `wasm` 逐字节一致 | `bash script/check.sh` cross-target 段 |
| 一键门禁 | **ALL GREEN**，约 3.5 分钟，离线 | `bash script/check.sh` |

### 8.2 未完成项与边界（如实申报）

| # | 未完成 / 收缩 | 说明 |
|---|---|---|
| 1 | `native` 后端未验证 | 本机无 MSVC，`--target llvm` 缺 `prelude.mi`；记录于 `BOUNDARY.md` §4.2，含安装命令 |
| 2 | M3 有意收缩 | trap / NaN **跳过单列而非算通过**（MoonBit `trap` 是 abort，不可捕获）；浮点按精确位比较、不放宽 1 ULP；未比对调用后线性内存哈希；参数为固定对角序列而非随机 |
| 3 | M4 部分达成 | 生成包的**行为**测试只在 `wasm-gc` 实跑；三端一致性证据是分析输出与编译 |
| 4 | 3 个性能指标未产出 | 吞吐 KB/s、代码膨胀比、执行性能比——正确性判据是"与独立实现一致"，时间投给了 41 模块与 384 次差分，理由见 `PLAN.md` §7 |
| 5 | 明确拒绝的 wasm 特性 | `call_indirect` `E111`、多值 `E112`、SIMD / GC / 引用类型、原子 / 线程、批量内存、非函数导入等，逐个报码 + 绝对偏移 + trap 桩 |
| 6 | 生成代码是 witness 而非漂亮源码 | 一次性循环、`brk` 变量、`// b3` 注释——定位是"可归因、可审计、可继续开发" |

**审查中确认的、由门禁真实抓到并修复的问题**（说明验证不是摆设）：条件 `return` 被吞成无条件、块入口值未绑定、`br_table` 载荷读未写临时量、`Memory::grow` / `check` 32 位溢出、`start` 段语义缺失、整数字面量作方法接收者、只写不读局部命名不一致、多返回值被静默丢弃。

## 附录：技术架构与关键决策

流水线：`reader → section → decode_instr → cfg → stack → struct → emit → runtime`，验证层为 `verify` + `script/verify.sh`。每层一个文件、一组白盒测试；`script/check.sh` 逐层比较三端**文本输出**，后端差异（整数运算、浮点位模式、UTF-8、`argv` 布局）会变成 diff 失败而不是细微错值。

关键决策（完整版见 `docs/DESIGN.md`）：

1. **宽解析、窄生成**：`info` 解析 `v128` / 多返回值 / `datacount` / name 段；`decompile` 逐函数拒绝并生成 trap 桩。
2. **走构造树而非 Relooper**：`br` 只能指向外层标签，可归约性由格式保证。
3. **`block` → 一次性 `while true`**：MoonBit 没有带标签的 `break`，跨层分支用 `Int brk` 逐层解绕。
4. **边值在前驱落盘**：分支载荷由前驱写入目标临时量，不读类型占位符。
5. **语义按实测分流**：与 MoonBit 一致的算子直接输出；除法溢出、`min(0,-0)`、NaN、ties-to-even 走 `runtime/runtime.mbt` 具名 helper。
6. **浮点按位模式输出**：避免打印/解析往返丢失 NaN 载荷或零的符号。
7. **拒绝也有真实签名**：被拒函数生成 `trap("...")` 桩，包始终可编译，失败定位到调用点。
8. **告警即错误**：生成包必须 `moon check` **零告警**，为此做了读/写 × 参数/局部分类与 `_p0` / `_l3` / `_t2` 命名。
9. **`start` → `moonlift_init()`**：MoonBit 包没有实例化步骤，由宿主显式调用。
10. **浮点与 trap 是"观测"不是"值"**：trap / NaN 跳过并单列，绝不冒充通过。

更多文档：[BOUNDARY.md](BOUNDARY.md)（支持矩阵、13 条语义偏差、19 条已知限制）、[docs/DESIGN.md](docs/DESIGN.md)、[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)、[docs/AI_USAGE.md](docs/AI_USAGE.md)、[corpus/PROVENANCE.md](corpus/PROVENANCE.md)。

## License

Apache-2.0。第三方归属见 [NOTICE](NOTICE)，语料来源见 [corpus/PROVENANCE.md](corpus/PROVENANCE.md)。

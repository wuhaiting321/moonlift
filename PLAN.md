# moonlift 项目实施计划（v1 → 已完成）

> 项目：Wasm 字节码 → 可编译 MoonBit 源码的反编译器
> 路径：`F:\moonbit总文件\moonlift`
> 目标：通过 2026 MoonBit 黑客松 11 月赛验收，并具备拿季度奖的工程强度
> 本文档状态：**S0–S11 全部完成**。原计划保留在下方作为对照，偏差与最终数据写在各节「实测」里。

---

## 0. 事实基线（已实测，不是假设）

写方案前先在本机跑了一遍环境，把会翻车的地方提前钉死：

| 项 | 实测结果 | 对方案的影响 |
|---|---|---|
| 工具链 | `moon 0.1.20261020` | 用**新格式**：`moon.mod`（TOML）+ 每目录 `moon.pkg`，不是旧的 `moon.mod.json` |
| 代码风格 | 官方脚手架要求 `///|` 分块 | 生成代码也要遵守，否则 `moon fmt` 会重排 |
| `Int` 语义 | `2147483647 + 1 = -2147483648`（wasm-gc 与 js 一致） | **可直接映射 wasm `i32`**，无限位问题 |
| `Int32` / `UInt32` | 存在；`UInt32::popcnt() -> Int` | `i32.shr_u` / `div_u` 走 `UInt32` |
| `Float` / `Double` | `Float` = f32（有 `::sqrt`、`::reinterpret_as_int`）；`Double` = f64（有 ceil/floor/round/trunc） | `f32.*`→`Float`，`f64.*`→`Double` |
| `Bytes` / `Array[Byte]` | 都可变长、可索引 | 线性内存用 `Array[Byte]` |
| 可用数学库 | `@math` 有 sin/cos/tan/exp/ln/pow/log10/log2/cbrt/hypot/atan2（f64 与 f32 双版本） | 浮点算子可一一映射 |
| **`--target wasm`（MVP 后端）** | **可用**：`moon build --target wasm` → 20 KB wasm，node + WASI 实跑 `fib(20)=6765` | 可当「真实编译器产物」语料，但**不等于 MVP 子集**，见下一行 |
| **MoonBit wasm 产物的真实特征**（S2 实测，推翻前一版判断） | 含 **`datacount` 段**、**多返回值签名**（2 个）、**`v128` 局部变量**（1 个函数，memcpy 助手）、`memory.fill` 等 bulk/SIMD 指令 | ① 段顺序不是 id 序：`datacount` 在 `element` 与 `code` 之间 → 用 rank 比较 ② `v128`/多值由 `info` 解析并计数、由代码生成逐个函数拒绝 ③ 解码器必须先「宽解析」再「窄生成」 |
| native 后端 | 不可用：无 MSVC；`--target llvm` 需 nightly（缺 `prelude.mi`） | 验证矩阵改为 **wasm / wasm-gc / js 三端实跑**；native 降级为「环境依赖」，不阻塞验收 |
| Node | v22.22.2 | 差分测试的**参考实现**（`WebAssembly.instantiate`）+ 三端运行载体（含 `node:wasi`） |
| wabt（npm 纯 JS 版） | **可用**：`npm i wabt` → wat↔wasm 双向；41 字节 `add` 模块汇编并执行通过 | ① 手写 `.wat` 夹具可汇编 ② **解码器可与 wabt `wasm2wat` 逐指令对拍** |
| 文件读取 | `moonbitlang/x@0.5.6` 的 `fs` 包在 wasm-gc / js / wasm 三端实测可读文件（`read_file_to_bytes` 三端均返回 508 字节） | CLI 有真实 IO；首次构建需联网拉包，index 本地已到 0.5.6（0.5.8 需 `moon update`，当前会超时） |
| 三端 `argv` 布局 | **不一致**：wasm-gc / wasm 是 `[program, cmd, ...]`，js 是 `[node, main.js, cmd, ...]` | CLI 不硬编码「丢掉 N 个」，改为定位第一个已知子命令；由三端输出比对脚本发现 |
| clang / emcc / rustc | 缺失（**已不构成阻塞**） | 无需 C 工具链：语料 = MoonBit 自身 MVP 产物 + 手写 wat + 可选公开 prebuilt wasm |

官方验收 6 条（原文）：MoonBit 为主 / 仓库公开 / 能够运行 / 工作有效 / 开源合规 / AI 可解释。
官方评分 4×25：工程深度与实现强度、技术贡献与攻关、生态增量、开发与验证能力。

---

## 1. 项目定位

**一句话**：把任意 MVP 子集的 `.wasm` 反编译成能 `moon build` 通过、行为等价的 MoonBit 源码。

**为什么不是「再写一个解析器」**：

MoonBit 的三端策略有个结构性硬伤——wasm-gc 与 JS 后端**贴不了 C FFI**。全库 3,882 个模块里有 159 个提到 `ffi`，绝大多数只能 native 跑。反编译是唯一能把 C/Rust 生态的存量搬进三端的路径。所以这个项目的产出不是「一个库」，而是**一条存量搬运通道**。

**与外部基线的关系**（评分维度 03 要的「外部基线」）：

| 能力 | 外部成熟实现 | MoonBit 现状 |
|---|---|---|
| wasm → C | wabt `wasm2c` | 无 |
| wasm → 伪代码 | `wasm-decompile`、Ghidra | 无 |
| wasm → 可编译高级语言 | 基本没有生产级方案 | 无 |
| MoonBit 侧检索 | `decompiler` 0 / `wasm2mbt` 0 / `wasm2c` 0（全量 3,882 模块） | GitHub 同词 `total_count = 0` |

---

## 2. 交付形态

### 2.1 仓库结构（MoonBit 新格式）

```
moonlift/
├── moon.mod                 # name = "wuhaiting321/moonlift", license Apache-2.0
├── moon.pkg                 # 根包（库入口）
├── README.mbt.md           #  literate README（官方脚手架同款）
├── LICENSE                 # Apache-2.0
├── NOTICE                  # 算法/格式参考来源（合规）
├── docs/
│   ├── DESIGN.md           # 架构与关键取舍
│   ├── BOUNDARY.md         # 支持矩阵 + 不支持清单 + 语义偏差
│   ├── ACCEPTANCE.md       # 验收对照表（官方 6 条 → 本仓库证据）
│   └── AI_USAGE.md         # AI 用在哪、怎么校验（对应「AI 可解释」）
├── src/
│   ├── core/               # 位读取、LEB128、诊断
│   ├── model/              # IR：类型、指令、模块
│   ├── decode/             # 段解析 + 指令解码
│   ├── analyze/            # CFG、类型化栈模拟
│   ├── reloop/             # 结构化（实际实现为 core/struct.mbt：走构造树，不含 relooper）
│   ├── emit/               # MoonBit 代码生成 + 运行时 prelude
│   ├── fixture/            # 自建 wasm 二进制生成器（测试夹具）
│   └── cmd/main/           # CLI（executable）
├── examples/               # 5 个示例：wasm 输入 + 生成结果 + 运行截图
├── script/
│   ├── demo.sh             # 一条命令跑完全流程
│   └── diff.sh             # 差分测试（Node 参考实现）
└── test/                   # 跨包集成测试
```

### 2.2 CLI 契约

```bash
moonlift info   <in.wasm>              # 打印结构摘要；非法输入给错误码+字节偏移
moonlift decompile <in.wasm> -o <dir>  # 生成 <dir>/module.mbt + prelude
moonlift verify <in.wasm> --cases 500  # 差分测试：原 wasm vs 生成代码
```

退出码：`0` 成功 / `1` 输入非法（带 `E0xx`）/ `2` 命中不支持特性（带 `E1xx`）/ `3` 内部错误。

---

## 3. MVP 契约（验收就看这张表）

| 编号 | 交付项 | 可执行判据 |
|---|---|---|
| **M1** | `info` 全量结构解析 | 对语料库 100% 输入不 panic；非法输入 100% 返回 `E0xx` + 字节偏移 |
| **M2** | `decompile` 生成可编译代码 | 语料库 ≥ 95% 的模块，生成物 `moon check` 零报错 |
| **M3** | 行为等价 | 导出函数随机输入差分测试，**case 通过率 ≥ 99%**（trap 也算一种可比较观测值） |
| **M4** | 三端一致 | 生成代码在 `wasm`（MVP）、`wasm-gc`、`js` 三端实跑，结果逐位一致；某端编译不过则**记录跳过原因**，不得静默省略 |
| **M5** | 一键复现 | `bash script/demo.sh` 从零跑完 info→decompile→verify 并打印指标表 |

### 3.1 输入子集（精确边界）

**支持**

- 二进制格式 v1（magic + version=1）
- 段：type(1)、import(2)、function(3)、table(4)、memory(5)、global(6)、export(7)、start(8)、element(9)、code(10)、data(11)、datacount(12 只读)、custom(0 仅 name)
- 值类型：`i32` `i64` `f32` `f64`（`funcref` 仅用于 table）
- 指令：**MVP 全集（172 条）** + sign-extension（`0xFC 0x00–0x07`，可开关）
- imports：**仅函数导入**，生成 Host trait 钩子，默认实现 = trap

**明确拒绝（报错，不静默降级）**

| 特性 | 触发 | 错误码 |
|---|---|---|
| GC / struct / array | `0xFB` 前缀 | `E101` |
| SIMD | `0xFD` 前缀 | `E102` |
| Threads / atomics | `0xFE` 前缀 | `E103` |
| Exception handling | `0x06/0x07/0x08/0x09/0x0A/0x18/0x19` | `E104` |
| Tail call | `0x12/0x13` | `E105` |
| memory64 / multi-memory | 段声明 >1 个 memory 或 flag 位 | `E106` |
| memory/table/global 导入 | import 段非 func | `E107` |
| 不可归约 CFG | `br` 标签深度越界（解码期即拒绝，见 BOUNDARY §3 D3） | `E008`（`E108` 保留，无路径返回） |

> **原则**：宁可报错，绝不生成「能编译但算错」的代码。这条原则写进 README 第一段。

### 3.2 明确不做（Non-goals）

1. 不做 wasm → wat 的美化（只在 debug 模式输出 `.wat` 风格用于自检）
2. 不追求生成代码「像手写」；目标是**可读 + 可改 + 可调试**
3. 不做性能优化（目标：生成代码 ≤ 原 wasm 3× 耗时，超了记录为已知问题）
4. 不支持 GC/SIMD/线程/异常（见上表）
5. 不保证 native 后端（本机无 MSVC，属环境依赖；安装 VS Build Tools 后可跑，不影响生成代码正确性）
6. 不做 wasm 校验器（我们假设输入已被 `WebAssembly.validate` 通过；自己只做「不越界读」的防御）

---

## 4. 技术方案（评分维度 02 的核心）

### 4.1 流水线

```
bytes ──► reader(边界检查) ──► sections ──► Module IR
                                              │
                            ┌─────────────────┼──────────────────┐
                            ▼                 ▼                  ▼
                        cfg builder      typed stack sim     name recovery
                            │                 │                  │
                            ▼                 ▼                  ▼
                        structurer ──────► expr trees ──────► emitter ──► .mbt
                                                                          │
                                                              runtime prelude
```

### 4.2 五个关键设计决策（每个都写进 DESIGN.md，含被否掉的方案）

**D1 · 值模型：直接映射，不做装箱联合**

| wasm | MoonBit | 依据 |
|---|---|---|
| `i32` | `Int` | 实测 32 位环绕，两端一致 |
| `i64` | `Int64` | 原生 |
| `f32` | `Float` | 有 `sqrt`/`reinterpret` |
| `f64` | `Double` | 有 ceil/floor/round/trunc |

被否方案：`enum Value { I32(Int); I64(Int64); ... }` 统一装箱。否掉理由：每个算子都要 match，生成代码体积 ×5、性能 ×10 差，且完全不可读。

**D2 · 控制流：走 wasm 自带的构造树，不设 Relooper、不设图调度器**

wasm 的 `block/loop/if` 本身带着嵌套树（每个构造有 `open`/`close`），CFG 是从这棵树派生的。所以结构化直接走这棵树，只重新推导 `br` 的数字深度；`block` 落成一次性 `while true`（MoonBit 没有带标签的 `break`，只能这样给 `break` 一个落点），`loop` 落成真 `while true`，跨多层的 `br` 用一个 `int brk` 记目标、逐层 guard 解绕，`br_table` 落成 `match`。**被否方案**：① 无条件 Relooper——把普通 `if` 也变成状态机，代码不可读；② 「能结构化就走树、否则退回图调度器」——后者在本输入子集里不可达（解码期 `check_label` 已拒绝越界标签），是没人能跑、没人能测的死代码。代价是 `E108` 成为保留码，明写在 BOUNDARY §3 D3。

**D3 · 代码生成：两级策略（本项目最核心的取舍）**

- **L1 表达式重建**：块内做类型化栈模拟，把 `local.get / i32.add / local.set` 折叠成 `x = a + b`。覆盖绝大多数代码。
- **L2 显式栈**：当块内栈形状无法静态确定（`br` 携带值、多值块、`unreachable` 之后的死代码），该块退化为 `stack.push/pop` 序列。

判据：**正确性优先，可读性尽力**。每个函数输出头注释标明走了 L1 还是 L2，便于评审核查。

**D4 · 内存模型**

`struct Memory { data : Array[Byte]; max : Int }`，所有 `load/store` 走 `mem.load_i32(addr)` 之类的访问器：先算有效地址（addr + offset，按 i32 环绕），越界 → `trap(TRAP_OOB, addr)`。被否方案：裸 `Array` 索引（越界行为与 wasm 不一致，且 `i32` 负偏移会 panic 在不同位置）。

**D5 · imports：Host trait 注入**

```moonbit
pub(open) trait Host {
  fn env_putchar(Int) -> Unit
}
```
默认实现全部 trap。这样反编译产物在无宿主时行为可预测，也给使用者留了接入点——这是 MoonBit 的 trait 比 C 的函数指针表更干净的地方。

### 4.3 必须攻克的难点

| 难点 | 具体问题 | 对策 |
|---|---|---|
| 结构化正确性 | 跨层 `br`、`br_table` 扇出、`if` 臂内跳转、循环回边 | 两条不变量落成断言：`visited == reachable`（395/395）与「输出零残留 `br`/`br_if`/`br_table`」；三端 `--struct` 逐字节一致 |
| 类型化栈模拟 | `select`、`drop`、多值块出口 | 用「块出口签名」反推，失败即降 L2 |
| f32/f64 位级语义 | NaN 传播、`nearest`（银行家舍入）、`copysign`、`min/max` 的 NaN 规则 | 手写 helper 而非用宿主 `min/max`；用差分的位比较验证 |
| i64 无符号运算 | MoonBit `Int64` 除法是有符号 | 拆成 `UInt64` 路径；`div_s` 溢出（MIN/-1）单独 trap |
| 生成代码体积 | 大模块一个文件几万行，编译器吃不消 | 按函数分文件 + 基本块函数化 |
| 死代码与不可达 | `unreachable` 后的指令仍在字节码里 | 解码保留，生成时跳过，但保留注释标记 |

---

## 5. 实施步骤（11 步，每步一个 commit）

| # | 步骤 | 产出 | 完成判据 |
|---|---|---|---|
| **S0** | 立项脚手架 | `moon.mod`/`moon.pkg`/LICENSE/NOTICE/README 骨架/git init | `moon check` 通过；首个 commit |
| **S1** | 位读取层 | `core`：LEB128(u32/u64/s32/s64)、f32/f64 位读取、边界检查、`Diag` 错误类型 | 单测覆盖非法 LEB128、截断、超长；错误带偏移 |
| **S2** | 模块模型 + 段解码 | `core/section.mbt`+`report.mbt`：12 个段 → IR；`moonlift info` 上线 | **已完成**：8 个语料全解析（含 20KB MoonBit 产物），11 个坏样本全部报 `E0xx/E1xx` + 字节偏移，三端输出逐字节一致 |
| **S3** | 指令解码 | 29 个指令形态覆盖 0x00–0xC4 全部操作码 + 0xFC；`disasm` / `--ops` / `--stats` | **已完成**：76 测试；与 wabt 逐条对拍 **4386 条全中、0 处不符**（62 条 SIMD 按设计不尝试）；7 个代码层坏样本按文件名报码；三端指令流逐字节一致 |
| **S4** | CFG + 可归约判定 | `core/cfg.mbt`：基本块划分、支配树、自然循环、Hecht–Ullman 可归约判定；`disasm --cfg` | **已完成**：95 测试（新增 19）；真实产物 439 块 / 583 边 / 20 循环 / 循环深度 1 / **78 个完整函数全部可归约、0 个不可归约**；不可归约路径用合成图单测覆盖；三端 `--cfg` 逐字节一致 |
| **S5** | 类型化栈模拟 | `core/stack.mbt`：块内类型化栈、表达式重建、三类别重排隐患（局部变量/内存/全局）、块边界与函数返回值校验；`disasm --stack` | **已完成**：124 测试（新增 29）；真实产物 **72/79 主体完成分析、6 个按名拒绝、1 个跳过、0 个被判非法**；111 次溢出中 **110 次强制（调用结果）+ 1 次重排隐患**；`stack.wasm` 夹具逐条钉死"读跨写"与"load 跨 store"；三端 `--stack` 逐字节一致 |
| **S6** | 结构化（原计划：Relooper） | `core/struct.mbt`：走 wasm 自带构造树，`block`→一次性 `while true`、`loop`→真 `while true`、跨层 `br` 用 `brk` 逐层解绕、`br_table`→`match`；`disasm --struct` / `--struct-stats` | **已完成**：133 测试（新增 9）；真实产物 **72/79 主体结构化、395/395 可达块各产出恰好一次、32 个 guard、0 个 switch、最大嵌套 7 层、1,115 个节点**；9 个夹具 0 条残留 `br`/`br_if`/`br_table`/`if (...)`；三端 `--struct` 逐字节一致 |
| **S7** | MoonBit 代码生成 + 支持库 | `core/emit.mbt`（1,901 行：命名、表达式打印、死尾裁剪）+ `runtime/runtime.mbt`（927 行：Memory、除法/取余、移位、旋转、trunc、min/max、无符号比较、位级浮点 helper）+ `decompile` 写出 6 个文件 | **已完成**：150 测试（新增 17）；**9 个夹具全部生成可编译包，`moon check` 零错误零告警**；真实产物写出 79 个函数定义（72 主体 + 7 个 trap 桩）；`control` 6/6、`fib` 3/3 用 Node 跑原件取期望值后逐值对齐，wasm-gc 与 js 双端通过 |
| **S8** | 差分验证 harness | `core/verify.mbt`（调用计划：对角序列 + 4 组锚定行）+ `corpus/tools/oracle.js --json`（参考实现，浮点按位比较）+ `script/verify.sh`（编排 + 生成测试 + 跑 `moon test`） | **已完成（当时值）**：**354 个调用，354 个与原件一致，0 失败**，覆盖 7 个不需要 host 的夹具；164 个调用因原件 trap/NaN 被跳过并单列；`imports` 与 `moonbit_fib` 需要 host，报告如实写明并排除。**S9 加入 `nested.wasm` 后为 384/384/0、8 个夹具**，见 §13 |
| **S9** | 语料建设 | 三层：① 手写 `.wat` 夹具经 npm wabt 汇编（覆盖边角指令）② `corpus/tools/gen_corpus.py` 用 `moon build --target wasm` 批量产出真实编译器模块 ③ 公开 prebuilt wasm 未采用（无必要，且会带来第三方许可证） | **已完成**：**41 个模块入库**（10 个 `corpus/good/` + 31 个 `corpus/extended/`），每个都有 SHA-256 与来源说明；新增 `nested.wat`（`br_table` 在 `loop` 里且跨边携带值）；`script/extended.sh` 对 31 个真实产物逐个做校验和→解码→反编译→零告警 `moon check`。这一层找出并修复了 3 个真实 bug：整数字面量作方法接收者、只写不读局部的命名不一致、多返回值被静默丢弃 |
| **S10** | 边界与偏差清单 | `BOUNDARY.md`：支持矩阵、错误码、语义偏差逐条、未完成项 | **已完成**：13 条语义偏差（D1–D13，每条含偏差/原因/影响面）、20 条已知限制、冻结的 17 个错误码、§5 复现清单；明确写出 M3/M4 的有意收缩与仓库未公开 |
| **S11** | 文档 + 指标 + 申报材料 | README、DESIGN、ACCEPTANCE 对照表、指标表、一页申报书 | **已完成**：`README.md` 指标表 + 状态；`docs/DESIGN.md`、`docs/ACCEPTANCE.md`、`docs/AI_USAGE.md`；申报书并入 `README.md` 顶部（中文一页，可直接贴飞书）；`script/demo.sh` 三分钟演示；`bash script/check.sh` → **ALL GREEN** |

> 顺序理由：S1–S3 是纯机械劳动但必须先对；S4–S6 是算法难点，放在有测试保护之后；S7 之后每一步都要 `moon check` 生成物，形成闭环。
>
> S4 的一个实测结论直接改变了 S6 的做法：**结构化 wasm 只可能产生可归约 CFG**（`br` 只能指向外层标签，而这正是可归约的定义），20 KB 真实产物 78/78 可归约。原计划是「先按原生嵌套生成，跨层时调 Relooper 兜底」；实测之后改成**只走构造树、不写 Relooper**：wasm 自己就带着 `block`/`loop`/`if` 与 `end` 的嵌套树，图是从这棵树派生的，再从图反推结构属于把已有的信息丢掉再猜回来。唯一树解决不了的是「一条 `br` 同时离开多层」，它用一个 `int brk` 记住要逃到哪一层、逐层 guard 解绕。**被否方案**：无条件 Relooper（把普通 `if` 也变成状态机，代码不可读）、以及「未命中就退回图调度器」——后者在本输入子集里不可达（解码期 `check_label` 已拒绝越界标签），留着就是没人能跑、没人能测的死代码。代价写进 BOUNDARY §3 D3：`E108` 保留在错误码表但没有任何代码路径会返回它，这一点明说，而不是假装有。
>
> S5 的一个副产品是 **S4 的真 bug**：`end if2` 后面紧跟 `else if1` 时，两者落在同一个真实下标上。按"进入 else 臂"读，栈是空的；按"刚结束了一个构造"读，栈上是那个构造的结果。S4 的逃逸表只跳一层，于是两条语义不同的流被合并进同一个块，真实产物里 4 个函数因此报"同一块的两个前驱栈形状不同"。修法是给每个位置加一张 `resolve` 表：落在 else 位上的"构造结束"要继续跳到外层 `if` 的结束处，`br` 的目标同样过这张表。这条抓得很值——它是"先做分析、再写生成"顺序的直接回报，如果先写 Relooper，这个 bug 会以"生成的代码在某个分支上算错"的形式出现，而那种 bug 极难定位。
>
> S6 遇到的是语言侧的硬约束，不是算法侧的：**MoonBit 没有带标签的 `break`/`continue`**（`'outer : while true` 直接是词法错误，`break 'label` 不存在），而 `block` 的语义就是"跳到它的 `end`"。所以每个 `block` 都落成一次性 `while true { ...; break }`；`loop` 落成真 `while true`；`br_if` 指向最内层 `block` 时仍然只是一个干净 `break`（有测试断言该函数输出里**不出现** `brk = 1`）。三个失败模式都是先撞上再设计的：`match` 分支里 `break` 是否合法（合法，已实测）、tail 位置裸 `while true` 返回类型报错（改成标志位）、`for_blocks_in` 把"扫过界"当成"找到了"导致给每个 `if` 臂都套了一次性循环（分离 `found`/`go` 修掉）。**结构化最难的不是生成，是证明它没漏块**：因此把 `visited == reachable` 做成断言，再把"输出里不许残留 `br`/`br_if`/`br_table`"做成第二道断言——因为"什么都没做"的实现能通过所有只检查"能跑通"的测试。
>
> S7 的难点不在"把树打印成文本"，而在"打印出来的文本能让编译器零告警地接受"。MoonBit 的**参数不可变**（`fn f(mut x : Int)` 是语法错误），所以一个被函数体写过的 wasm 参数必须先落成 `let mut l0 = p0`；反过来，一个只读参数直接叫 `p0`。这条规则一落地立刻分裂成四种情况（读/写 × 参数/局部），而漏掉任何一格都是编译错误——真实产物第一版 155 个错误里有 7 个是 `l0 is not mutable`。另外三类是告警而非错误，但同样必须清零：函数体不读的参数（`_p0`）、只写不读的局部与临时量（`_l3` / `_t2`）、以及结构器留下但控制流到不了的尾巴（由 emitter 在打印时停手）。关键是这些分析必须和 emitter **用同一条裁剪规则**走树，否则"声明了但没打印"和"打印了但没声明"会交替出现——`live_nodes` 因此成了所有声明分析的唯一入口。
>
> 两个真正的语义 bug 都不是"编不过"，而是"编得过但算错"，只有把生成物真的跑起来才看得见：① 一条 `br_if` 指向函数体末尾时被当成无条件 `return` 打印（"缓冲区空了就返回"于是变成"直接返回"），真实产物里 6 处，`moonbit.fprintln` 的主循环因此只跑一次；② block 的入口值被打印成 `in0` 却没有任何绑定——覆盖率不变量当时是绿的（每个块都恰好产出一次），因为这条不变量看不见"名字有没有绑定"。修法分别是给条件转移加 `NIf` 包裹、以及把入口值改成由前驱在边上写入的临时量。**结论写进了门禁**：`script/check.sh` 现在不只要求生成物 `moon check` 零告警，还要求 `control` 与 `fib` 两个生成包真的跑起来，和 Node 跑原件的值逐一对齐——不然"能编译"就是唯一的标准，而它筛不掉这两类 bug。
>
> 还有一条是被拒函数的处理：**被拒的函数必须留下一个桩**（真签名 + `trap("... E111 ...")`），不能直接不生成。第一版是直接跳过，结果所有调用它的函数全部编不过（真实产物 7 个错误，全是 "identifier `f47` is unbound"）。留桩比"猜一个函数体"安全得多：它精确地停在那一处调用，而不是返回一个看起来很合理的错值。

> S8 的第一个决定是**分工**：MoonBit 侧不做比较，只产出"要调什么"的计划（`calls.tsv`）；比较在 Node 里跑原件；编排在 bash 里。理由很硬——`moonlift` 自己跑在 `wasm-gc`/`js` 上，既不能执行 wasm 模块也不能起子进程；而在 MoonBit 里写第二份实现再和自己比，证明的是"两份代码一致"而不是"解编译正确"。三方分工是能同时满足"独立"和"可复现"的最小结构。
>
> 第二个决定是**参数怎么选**。最初按里程表枚举（最后一个参数最快），结果 `arith` 的 `$i32_bin` 把二十个二元算子串成一个累加器，`a=0` 时第四步就 `div_s` 除零，整个预算全花在会 trap 的第一行上。改成**对角序列**（第 k 个参数取 `t mod |池_k|`）加四组**锚定行**（首参固定为 1/4/5/9，其余枚举）之后，`i32_bin` 立刻产出一批可比的非零结果。这不是美学问题：参数顺序决定了这套 harness 到底在测什么。
>
> 第三件事是**超时与例外**。`fib.wasm` 的 `fib` 是递归斐波那契，`fib(255)` 永远不会返回——这不是解编译的 bug，是原件本身的性质。解法分两层：原件跑不动就 `timeout` 截断并把"原件没跑完"写进报告（已打印的行仍然按序可比，绝不冒充通过）；`fib` 这一个夹具用 `--small` 只取前五个值。**任何被跳过的调用都单列一栏，不进"通过"**：trap 和 NaN 没有可比的值，把它们算成通过就是自欺。
>
> S8 立刻抓到一个 `moon check` 永远抓不到的真 bug：`Memory::grow` 里 `pages + delta` 用 32 位算，`memory.grow(2147483647)` 溢出成负数、绕过上限判断、然后在分配里炸掉；原件返回 `-1`。修的时候顺手发现 `Memory::check` 同样问题（地址加宽度用 32 位，`0x7FFFFFFE` 会绕回界内而不是 trap），两个都改成 64 位并补了回归用例。**没有 harness 的话，这两个 bug 会以"生成的程序在某些输入上崩掉/读错"的形式流到用户手里。**
>
> 还补上一个语义缺口：**`start` 段**。wasm 在实例化时跑 start，MoonBit 包没有实例化这一步，所以 `globals.wasm` 的 `f4` 一开始返回 0（原件返回 1）。现在每个生成包都带 `pub fn moonlift_init()`（无 start 时为空），由宿主调用一次——写成 BOUNDARY §3 D11，并在 verify 的测试文件里真的先调它。

> S5 还确认了一个设计判断：**调用结果必须立刻落成临时变量**。原因不是性能而是语义——调用在原位执行，把它的结果当表达式推迟到消费点，等于把调用挪了位置。这类溢出记为 `forced`，与真正的重排隐患（`hazard`）分开统计；真实产物 110 : 1 的比例正说明"被迫的"是常态、"隐患"是少数，但也正因如此，隐患必须单独计数，否则会被淹没在噪声里。
>
> S4 还顺带修掉一个夹具缺陷：`control.wat` 的 `$sum_to` 里 `if` 内写的是 `br 1`，按标签规则指向 `loop` 而不是外层 `block`，函数对任何输入都死循环；CFG 把出口块标成 unreachable，使这个错误暴露出来。已改成 `block { loop { br_if $exit ... } }` 并重新汇编。

---

## 6. 代码行数预算（硬指标 ≥500，目标 3,000+）

| 包 | 内容 | 预估行数 |
|---|---|---|
| `core` | LE128/reader/diag | 340 |
| `model` | 类型 + 172 条指令定义 | 460 |
| `decode` | 段解析 + 指令解码 | 740 |
| `analyze` | CFG + 类型化栈 | 640 |
| `reloop` | 结构化（实际：`core/struct.mbt`，走构造树而非 Relooper） | 420 → 实测 1,465 |
| `emit` | 代码生成（`core/emit.mbt`）+ 支持库（`runtime/runtime.mbt`） | 840 → 实测 2,828 |
| `verify` | 调用计划（`core/verify.mbt`）：值池、对角序列、锚定行 | — → 实测 368 |
| `fixture` | wasm 二进制生成器 | 220 |
| `cmd/main` | CLI | 200 |
| 测试（`_wbtest.mbt`） | 单测（12 个文件） | 600+ → 实测 **152 个用例**，测试文件约 2,500 行 |
| **合计** | | **≈ 4,460 → 实测 14,383 行 MoonBit**（`core/` 12,699 + `runtime/` 1,218 + `cmd/` 466；另有 31 个语料源码 `.mbt` 约 469 行不计入） |

> 硬指标 ≥500 行：**14,383 行，超出 28 倍**。项目实现代码 100% 为 MoonBit。

---

## 7. 验证方案（评分维度 04）

**三层验证，缺一层都不算完**（括号内为实际落地方式）：

1. **单元层**：每个 pass 一个 `_wbtest.mbt`，`test "..." { assert_eq(...) }`（✅ 12 个文件、152 个用例）
2. **快照层**：原计划三份 golden 文件；**实际改为更严格的「三端逐字节一致 + 钉住统计」** —— `info` / `--ops` / `--cfg` / `--stack` / `--struct` / `calls.tsv` 在 `wasm-gc`、`js`、`wasm` 三端输出必须完全一致，真实产物的 `nodes 1115`、`blocks emitted 395 of 395` 等数字写进门禁断言。golden 文件会随工具链升级而过期，钉住关键数值不会
3. **差分层**（最关键）：Node 跑原 wasm，MoonBit 跑生成代码并比对（✅ `script/verify.sh`：384/384，见下方偏差说明）

差分测试的判据要写清楚：

- 整数：按位相等
- 浮点：`f32/f64` 按 IEEE 位相等；若不等，允许 ≤1 ULP 并单独计数（NaN 归一化为 canonical NaN）
- trap：两边都 trap 视为通过；一边 trap 一边返回值视为失败
- 内存：调用结束后比对整个线性内存的哈希

**要产出的指标表**（原计划，申报书直接用）：

| 指标 | 定义 | 实际 |
|---|---|---|
| 解析成功率 | 语料中成功解析 / 总数 | ✅ **60/60**（41 良构 + 19 畸形按预期） |
| 编译成功率 | 生成物 `moon check` 通过 / 总数 | ✅ **41/41**，且零告警 |
| 差分通过率 | 通过 case / 总 case | ✅ **384/384**，164 个 trap/NaN 跳过单列 |
| 反编译吞吐 | KB/s（输入字节 / 耗时） | ❌ 未产出 |
| 代码膨胀比 | 生成 `.mbt` 字节数 / 输入 `.wasm` 字节数 | ❌ 未产出 |
| 执行性能比 | 生成代码耗时 / 原 wasm 耗时（wasm-gc） | ❌ 未产出 |

> **实际落地的偏差（S8–S11，如实申报）**：
> ① 输入从「随机」改为**固定对角序列 + 四组锚定行**，因为失败必须能从报告单独复现；
> ② trap / NaN **跳过并单列**，不算通过 —— MoonBit 的 `trap` 是 abort 而非可捕获错误，生成测试无法观测自身 trap；
> ③ 浮点**精确按位比较**，不放宽到 1 ULP（按位比较的意义就是不许打印往返改掉 NaN 载荷或零的符号）；
> ④ 未比对调用后线性内存哈希；
> ⑤ 三个性能指标未产出：本项目的正确性判据是「与独立实现一致」，吞吐/体积/速度比与验收无关，把时间花在了 41 个模块的编译与 384 次差分上。最终申报书改用 `README.md`「Metrics」与 `README.md（申报书）` 里的 **11 项以正确性为核心的指标**，每项都有复现命令。详见 `docs/ACCEPTANCE.md` §3 与 `BOUNDARY.md` §4.20。

---

## 8. 边界文档（BOUNDARY.md）目录

1. 输入子集支持矩阵（段 / 值类型 / 指令）
2. 不支持特性 → 错误码 → 触发位置
3. **语义偏差清单**（逐条：偏差 / 原因 / 影响 / 是否可接受 / 缓解）
4. 未验证项（native 后端、>2MB 模块、深嵌套 500+）
5. 已知 bug 与规避方式
6. 复现命令与期望输出

> 第 3 节是「边界掌握」的评分点，我预期至少列 8 条（如 `memory.grow` 上限、`call_indirect` 类型检查时机、`f32.nearest` 舍入模式、`unreachable` 后的死代码、`select` 的类型多态等）。

---

## 9. 风险与预案

| 风险 | 概率 | 预案（降级路径） |
|---|---|---|
| Relooper 做不完/不可靠 | 已解除 | S6 实测后改为「走构造树、不写 Relooper」：`br` 只能指向外层标签，可归约性由解码期的 `check_label` 保证，20 KB 真实产物 78/78 可归约。不可归约在 BOUNDARY §3 D3 里明写为「不可达，`E108` 保留」 |
| 生成代码编不过 | 中 | S7 起每步都 `moon check` 生成物；先过简单夹具再上复杂 |
| MoonBit 对超长函数/深嵌套有限制 | 中 | 基本块函数化 + 按函数拆文件 |
| 真实语料拿不到（无 C 工具链） | 已解除 | 改用 `moon build --target wasm` 自身 MVP 产物（真实编译器输出，且源码已知）+ 手写 `.wat`（npm wabt 汇编）；公开 prebuilt wasm 仅作可选补充 |
| 差分通过率上不去 | 中 | 先按算子分类统计失败分布，逐个修；实在不行缩子集并在边界里声明 |
| native 无法验证 | 已发生 | 三端实跑改为 wasm / wasm-gc / js；native 在边界文档里列为「需要 VS Build Tools 的环境依赖」，并给出安装命令 |

---

## 10. 一页申报书结构（提交飞书用）

**已产出：`README.md（申报书）`，可直接复制粘贴。** 原计划的结构与最终落地的差别：

1. **项目名 + 一句话** ✅
2. **生态缺口**（带数据：3,882 模块全量检索 `decompiler` 0；GitHub `moonbit+decompiler` total_count 0；表述为「在可检索范围内未发现直接重复实现」）✅
3. **方案与关键技术**（构造树结构化 + `brk` 逐层解绕 + 边值前驱落盘 + 算子/helper 语义分流 + 三方独立差分验证）✅ 原计划的「L1/L2 两级代码生成」实际未分层，改为单遍 `core/emit.mbt` + 运行时库，如实改写
4. **边界**（MVP 子集 + **13 条**语义偏差 D1–D13 + **20 条**已知限制 + M3/M4 的有意收缩）✅
5. **验证数据**（**11 项**以正确性为核心的指标表，每项附复现命令；三个性能指标未产出并说明原因）✅
6. **开源合规 + AI 使用说明**（Apache-2.0；`docs/AI_USAGE.md`；格式参考 WebAssembly spec，结构化策略为自研，逐项在 `NOTICE` 标注）✅
7. **新增：提交前唯一待办 —— 仓库公开**（按你的要求全程未推送）✅

---

## 11. 排期（按 10 个有效工作日）

| 日 | 内容 |
|---|---|
| D1 | S0 + S1（脚手架 + 位读取 + 单测） |
| D2–D3 | S2 + S3（段解码 + 指令解码 + info 上线） |
| D4–D5 | S4 + S5（CFG + 类型化栈） |
| D6 | S6（结构化：构造树 + `brk`） |
| D7–D8 | S7（代码生成 + prelude，第一个端到端跑通） |
| D9 | S8 + S9（差分 harness + 语料） |
| D10 | S10 + S11（边界文档 + 指标 + 申报书） |

---

## 12. 需要你拍板的 3 件事（全部已定）

1. **边界策略** → **已定：接受「MVP 子集 + 明确报错」**。落地为 17 个冻结错误码、13 条语义偏差、20 条已知限制；「范围变化和未完成事项交代清楚」写进 `BOUNDARY.md` 与申报书。
2. **native 后端** → **已定：不装 MSVC**，验证矩阵为 `wasm` / `wasm-gc` / `js` 三端；native 在 `BOUNDARY.md` §4.2 列为环境依赖并给出安装命令。本机实测 `--target llvm` 缺 `prelude.mi`。
3. **申报书** → **已定并已产出**：`README.md（申报书）`，中文一页、含 11 项指标表，可直接贴飞书。

> **你另外追加的两条约束也已遵守**：① 先列步骤过目再实现（`PLAN.md` 全程保留，未删改原始方案）；② **项目做完、验证通过之前不推送 GitHub** —— 至今 `git remote -v` 为空，所有提交都在本地。

---

## 13. 最终状态（S11 收尾）

| 项 | 结果 |
|---|---|
| 阶段 | **S0–S11 全部完成** |
| 门禁 | `bash script/check.sh` → **ALL GREEN**（约 3.5 分钟，离线） |
| 代码 | **14,383 行 MoonBit**，152 个单测，12 个测试文件 |
| 语料 | **41 个 `.wasm`**（10 + 31），19 个畸形样本，全部有 SHA-256 与来源 |
| 正确性 | wabt 对拍 4,485/4,485；差分 384/384/0 失败；41/41 生成包零告警编译 |
| 文档 | `README.md`（含申报书）、`BOUNDARY.md`、`PLAN.md`、`docs/DESIGN.md`、`docs/ACCEPTANCE.md`、`docs/AI_USAGE.md`、`corpus/PROVENANCE.md` |
| 唯一待办 | **仓库公开**（需你确认后推送；改模块名与 git 身份后重跑门禁） |
| 本地提交 | `1a64953`(S7) → `5d23e9d`(S8) → `21d0e8b`(S9) → `e984b6a`(S10) → S11 |

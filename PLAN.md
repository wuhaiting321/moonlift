# moonlift 项目实施计划（v1，待确认）

> 项目：Wasm 字节码 → 可编译 MoonBit 源码的反编译器
> 路径：`F:\moonbit总文件\moonlift`
> 目标：通过 2026 MoonBit 黑客松 11 月赛验收，并具备拿季度奖的工程强度
> 本文档状态：**方案待你确认，确认后才开始写代码**

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
├── moon.mod                 # name = "moonlift/moonlift", license Apache-2.0
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
| **S6** | 结构化（原计划：Relooper） | `core/struct.mbt`：走 wasm 自带构造树，`block`→一次性 `while true`、`loop`→真 `while true`、跨层 `br` 用 `brk` 逐层解绕、`br_table`→`match`；`disasm --struct` / `--struct-stats` | **已完成**：131 测试（新增 7）；真实产物 **72/79 主体结构化、395/395 可达块各产出恰好一次、32 个 guard、0 个 switch、最大嵌套 7 层**；9 个夹具 0 条残留 `br`/`br_if`/`br_table`/`if (...)`；三端 `--struct` 逐字节一致 |
| **S7** | MoonBit 代码生成 + prelude | 函数体、导出包装、Host trait、Memory、trap、数学 helper | 生成物 `moon check` 零报错 |
| **S8** | 差分验证 harness | Node 参考 runner + MoonBit driver + 随机输入 + 位级比较 + 报告 | `verify` 输出通过率表；≥99% |
| **S9** | 语料建设 | 三层：① `tools/gen_corpus` 用 `moon build --target wasm` 批量产出（源码已知，可算期望值）② 手写 `.wat` 夹具经 npm wabt 汇编（覆盖边角指令）③ 可选公开 prebuilt `.wasm`（记录 URL + 许可证） | ≥40 个模块入库；每个都有 SHA-256 与来源说明 |
| **S10** | 边界与偏差清单 | `BOUNDARY.md`：支持矩阵、错误码、语义偏差逐条、未完成项 | 每条偏差都有「为什么」和「影响面」 |
| **S11** | 文档 + 指标 + 申报材料 | README、DESIGN、ACCEPTANCE 对照表、指标表、一页申报书 | 评委按 README 能 3 分钟复现 |

> 顺序理由：S1–S3 是纯机械劳动但必须先对；S4–S6 是算法难点，放在有测试保护之后；S7 之后每一步都要 `moon check` 生成物，形成闭环。
>
> S4 的一个实测结论直接改变了 S6 的做法：**结构化 wasm 只可能产生可归约 CFG**（`br` 只能指向外层标签，而这正是可归约的定义），20 KB 真实产物 78/78 可归约。原计划是「先按原生嵌套生成，跨层时调 Relooper 兜底」；实测之后改成**只走构造树、不写 Relooper**：wasm 自己就带着 `block`/`loop`/`if` 与 `end` 的嵌套树，图是从这棵树派生的，再从图反推结构属于把已有的信息丢掉再猜回来。唯一树解决不了的是「一条 `br` 同时离开多层」，它用一个 `int brk` 记住要逃到哪一层、逐层 guard 解绕。**被否方案**：无条件 Relooper（把普通 `if` 也变成状态机，代码不可读）、以及「未命中就退回图调度器」——后者在本输入子集里不可达（解码期 `check_label` 已拒绝越界标签），留着就是没人能跑、没人能测的死代码。代价写进 BOUNDARY §3 D3：`E108` 保留在错误码表但没有任何代码路径会返回它，这一点明说，而不是假装有。
>
> S5 的一个副产品是 **S4 的真 bug**：`end if2` 后面紧跟 `else if1` 时，两者落在同一个真实下标上。按"进入 else 臂"读，栈是空的；按"刚结束了一个构造"读，栈上是那个构造的结果。S4 的逃逸表只跳一层，于是两条语义不同的流被合并进同一个块，真实产物里 4 个函数因此报"同一块的两个前驱栈形状不同"。修法是给每个位置加一张 `resolve` 表：落在 else 位上的"构造结束"要继续跳到外层 `if` 的结束处，`br` 的目标同样过这张表。这条抓得很值——它是"先做分析、再写生成"顺序的直接回报，如果先写 Relooper，这个 bug 会以"生成的代码在某个分支上算错"的形式出现，而那种 bug 极难定位。
>
> S6 遇到的是语言侧的硬约束，不是算法侧的：**MoonBit 没有带标签的 `break`/`continue`**（`'outer : while true` 直接是词法错误，`break 'label` 不存在），而 `block` 的语义就是"跳到它的 `end`"。所以每个 `block` 都落成一次性 `while true { ...; break }`；`loop` 落成真 `while true`；`br_if` 指向最内层 `block` 时仍然只是一个干净 `break`（有测试断言该函数输出里**不出现** `brk = 1`）。三个失败模式都是先撞上再设计的：`match` 分支里 `break` 是否合法（合法，已实测）、tail 位置裸 `while true` 返回类型报错（改成标志位）、`for_blocks_in` 把"扫过界"当成"找到了"导致给每个 `if` 臂都套了一次性循环（分离 `found`/`go` 修掉）。**结构化最难的不是生成，是证明它没漏块**：因此把 `visited == reachable` 做成断言，再把"输出里不许残留 `br`/`br_if`/`br_table`"做成第二道断言——因为"什么都没做"的实现能通过所有只检查"能跑通"的测试。
>
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
| `reloop` | 结构化（实际：`core/struct.mbt`，走构造树而非 Relooper） | 420 → 实测 1,333 |
| `emit` | prelude + emitter + 命名 | 840 |
| `fixture` | wasm 二进制生成器 | 220 |
| `cmd/main` | CLI | 200 |
| 测试（`_test.mbt` / `_wbtest.mbt`） | 单测 + 快照 | 600+ |
| **合计** | | **≈ 4,460** |

---

## 7. 验证方案（评分维度 04）

**三层验证，缺一层都不算完**：

1. **单元层**：每个 pass 一个 `_wbtest.mbt`，用 `test "..." { assert_eq(...) }`；非法输入用 `inspect(..., content=...)` 快照
2. **快照层**：反汇编文本、CFG、生成代码三份 golden，`moon test --update` 刷新，diff 可审
3. **差分层**（最关键）：Node 跑原 wasm，MoonBit 跑生成代码，同一批随机输入，比返回值/trap/内存快照

差分测试的判据要写清楚：

- 整数：按位相等
- 浮点：`f32/f64` 按 IEEE 位相等；若不等，允许 ≤1 ULP 并单独计数（NaN 归一化为 canonical NaN）
- trap：两边都 trap 视为通过；一边 trap 一边返回值视为失败
- 内存：调用结束后比对整个线性内存的哈希

**要产出的指标表**（申报书直接用）：

| 指标 | 定义 |
|---|---|
| 解析成功率 | 语料中成功解析 / 总数 |
| 编译成功率 | 生成物 `moon check` 通过 / 总数 |
| 差分通过率 | 通过 case / 总 case |
| 反编译吞吐 | KB/s（输入字节 / 耗时） |
| 代码膨胀比 | 生成 `.mbt` 字节数 / 输入 `.wasm` 字节数 |
| 执行性能比 | 生成代码耗时 / 原 wasm 耗时（wasm-gc） |

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

1. **项目名 + 一句话**
2. **生态缺口**（带数据：3,882 模块全量检索 `decompiler` 0；GitHub `moonbit+decompiler` total_count 0）
3. **方案与关键技术**（构造树结构化 + `brk` 逐层解绕 + L1/L2 两级代码生成 + 差分验证闭环）
4. **边界**（MVP 子集 + 8 条语义偏差 + 未完成项）
5. **验证数据**（6 项指标表）
6. **开源合规 + AI 使用说明**（Apache-2.0；格式参考 WebAssembly spec，结构化策略为自研，逐项在 NOTICE 标注）

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

## 12. 需要你拍板的 3 件事（已按实测环境修订）

1. **边界策略**：接受「MVP 子集 + 明确报错」吗？（建议接受：追求跑所有 wasm 必然烂尾，官方评审把「范围变化和未完成事项交代清楚」列为加分项）
2. **native 后端**：默认**不装 MSVC**，验证矩阵用 `wasm` / `wasm-gc` / `js` 三端实跑，native 写进「环境依赖」。
   - 若你要求四端齐活：`winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools"`，约 6 GB、需管理员授权，装完 `moon build --target native` 可用。**它只增加一个运行后端，不改变生成代码的正确性判据**，建议省下这 6 GB。
3. **申报书**：要不要我在 S11 一并写中文一页申报书（含指标表），你直接贴飞书？

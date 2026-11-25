# 共享导入：绑定、别名，与实例化的时刻

本文回答初审的第二条意见：

> 声明完整支持 Core 1.0 的同时，将导入状态改为独立对象并要求预填，未覆盖共享实例的必要语义。请说明如何绑定和保持共享导入，并用同一可变全局被导入两次的读写案例解释迁移前后行为。

三句话概括答复：**①** 导入不再被"物化"成本地副本，而是由宿主通过 `moonlift_bind()` 交进来，生成代码直接使用宿主给的对象；**②** 同一 `(module, name)` 被导入多次时，绑定记录里只有**一个**字段，别名是结构性的，不是承诺；**③** 段在 `moonlift_init()` 里铺到**当前绑定的实例**上——所以"要求预填"这一条被删掉了，宿主什么都不用预先写。

## 1. 规范怎么说

WebAssembly 1.0 的语义分两层：

| 层 | 规范里的动作 | 本项目里对应什么 |
|---|---|---|
| 模块层 | 验证、执行指令 | 生成的反编译代码 |
| 嵌入层 | `instantiate(module, externvals)`：外部值按 import 顺序交给模块；`elem` / `data` 段在**这一刻**复制进实例；`start` 在**这一刻**执行 | `moonlift_bind(externs)` + `moonlift_init()` |

关键在于 import 的解析方式：**按 `(module, name)` 解析，不按索引**。同一个名字出现两次，得到两个全局索引，但它们指向**同一个外部值**：

```wat
(import "env" "counter" (global $a (mut i32)))
(import "env" "counter" (global $b (mut i32)))
```

`global.set $a 7` 之后 `global.get $b` 必须是 7。旧版把两个 import 条目各造一个 `Ref`，这一步就变成了 0——"能编译、算错"，正是本项目最不该出现的失败模式。

## 2. 旧实现错在哪（已复现）

旧版对每个 import 条目生成一个独立的 `pub let`：

```moonbit
pub let g0 : Ref[Int] = Ref(0)   // import "env" "counter"
pub let g1 : Ref[Int] = Ref(0)   // 同一个 counter，第二个 Ref
```

用 `bump`（写 `$a`、读 `$b`）一测就露：

```
$ bash script/verify.sh /tmp/aliasfix/alias.wasm
fixture   calls  matched  skipped
alias         2        0        0
Diff: -1  +0            ← 原件答 1，生成代码答 0
```

不是偏移算错，也不是类型错，是**对象身份错了**：两个导入条目本来该指向一个 cell，却成了两个。

## 3. 现在的模型：一张绑定记录

`moonlift decompile` 会按 `(kind, module, name)` 去重，为每个**不同**的导入生成一个字段：

```moonbit
/// The instances this module is compiled against: one field per distinct
/// `(module, name)` pair. ...
pub struct MoonliftExterns {
  env_counter : Ref[Int]     // 两个 import 条目共用这一个字段
  env_base : Ref[Int]
}

///|
let __ml_externs : Ref[MoonliftExterns] = Ref(default_externs())

///|
/// Set by `moonlift_bind()`; cleared by `moonlift_init()`, so segments and
/// `start` run once per instance rather than once per call.
let __ml_pending : Ref[Bool] = Ref(true)

pub fn moonlift_bind(e : MoonliftExterns) -> Unit {
  __ml_externs.val = e
  __ml_pending.val = true
}
```

导入的全局不再是 cell，而是一行访问器——两个索引指向同一个字段，别名由**类型**保证：

```moonbit
pub fn g0() -> Ref[Int] {
  __ml_externs.val.env_counter
}
pub fn g1() -> Ref[Int] {
  __ml_externs.val.env_counter
}
```

函数体因此长这样（生成的原文）：

```moonbit
pub fn f0() -> Int {
  // b0
  g0().val = (g0().val + 1)
  return g1().val
}
```

内存和表同理：`__ml_mem()` / `__ml_table()` 在导入时返回宿主绑定的对象，不在导入时返回模块自己建的那个。于是同一段函数体，对"自己的内存"和"宿主的内存"是同一种写法，没有两条路径可以走岔。

`__ml_pending` 解决的是顺序问题：`moonlift_bind()` 开始一个新的实例，下一次 `moonlift_init()` 铺段并跑 `start`，之后的 `moonlift_init()` 什么都不做。重复调用 `init` 不会把模块写过的内存重新覆盖回段的初始内容——这是真 bug，改之前 `memory.wasm` 的 `floats(7)` 就对不上了（`stores` 先写过字节，`init` 又把它盖回去）。

## 4. 段在实例化时铺，因此不需要预填

```moonbit
fn __ml_layout() -> Unit {
  g3.val = g2().val                                       // (global $copy i32 (global.get $base))
  __ml_mem().init_bytes(0, b"\x61\x62\x63")               // (data (i32.const 0) "abc")
  __ml_mem().init_bytes(g2().val, b"\x58\x59")            // (data (global.get $base) "XY")
  let t = __ml_table()
  ...
}

pub fn moonlift_init() -> Unit {
  if !__ml_pending.val {
    return
  }
  __ml_pending.val = false
  __ml_layout()
}
```

旧版把常量段写在 `make_memory()` 里（包加载时就执行），只有 `global.get` 段等到 init。现在全部等到 init，理由和规范一致：**段是往"实例"里铺的，而实例要到绑定时才存在**。宿主要做的只有两件：

```moonbit
moonlift_bind({ env_counter: Ref(0), env_base: Ref(4) })   // 1. 交实例
moonlift_init()                                            // 2. 实例化（铺段 + start）
```

## 5. 迁移前后行为：同一可变全局被导入两次

`corpus/good/alias.wasm`（手写，145 字节）：`bump` 把 `$a` 加一后返回 `$b`；`poke(v)` 写 `$b` 返回 `$a`；`$copy` 是定义全局，初值取自不可变的导入全局 `base`。

| 步骤 | 原件（Node + host） | 旧实现（物化 + 预填 `g0.val`） | 新实现：不绑定（替身） | 新实现：`moonlift_bind` 后 |
|---|---|---|---|---|
| `bump()`，初始 0 | **1** | 0 ❌ | 1 | **1** |
| 再 `bump()` | **2** | 0 ❌ | 2 | **2** |
| `peek()` | **2** | 0 ❌ | 2 | **2** |
| `poke(9)` | **9** | 0 ❌ | 9 | **9** |
| 宿主把 `counter` 设为 5，再 `bump()` | **6** | 0 ❌ | 1（替身从 0 起算） | **6** |
| 宿主把 `base` 设为 7，`copy()` | **7** | 0 ❌ | 7 | **7** |

"替身"一列是**未绑定**时的行为：默认实例是零填充的、尺寸正确的本地对象，别名仍然成立（所以 1/2/9 对），但它不是宿主的状态（所以 5→6 那两行不对）。这一列存在是为了让生成包在没有宿主时也能编译、自测；文档、注释、`BOUNDARY.md` 都把它叫作替身而不是语义。

"旧实现"一列是这次整改的直接动机：全部答 0。它不是边界，是 bug。

钉住这张表的是 `script/sharing.sh`（5 条属性，逐条 `moon test`）与 `script/verify.sh` 里 `alias` 的 17 个调用：

```
$ bash script/sharing.sh
ok   alias: unbound, two entries one cell                     Total tests: 1, passed: 1, failed: 0.
ok   alias: bound, 3 properties                               Total tests: 3, passed: 3, failed: 0.
ok   alias: two import entries, one binding field             env_counter
ok   imported: binding alone copies nothing                   Total tests: 1, passed: 1, failed: 0.
ok   imported: bound memory, table, globals (3 properties)    Total tests: 3, passed: 3, failed: 0.
sharing: 5 ok, 0 failed
```

"binding alone copies nothing" 与 "init copies the segments into the bound instance" 成对：先 bind 不 init，`load0()` 读到 0；bind 后 init，读到 97。这条对证明"段跟着绑定走"，也证明"不需要预填"。

## 6. 跨模块共享：两个模块用同一个内存

同一个模块里两次导入由 §3 解决。还有一层：模块 A 与模块 B 各自 `(import "env" "mem" (memory 1))`，宿主给它们**同一个** `Memory`；A `memory.grow` 之后 B 的 `memory.size` 要变大。

这一层不能靠"把同一个对象传给两个生成包"实现：每个生成包自带一份 `runtime.mbt`，`pkg_a.Memory` 与 `pkg_b.Memory` 是**两个不同的类型**，宿主无法把一个对象同时递给两边，用字段复制绕过去也会在 `grow` 换掉内部数组之后分叉。

正确做法是**把多个模块反编译进同一个包**：一份 `runtime.mbt`，一张 `MoonliftExterns`，两个模块的前缀 (`m1_` / `m2_`) 分开命名，`(module, name)` 相同的导入在记录里合并成一个字段。

> 状态：这一层（`decompile a.wasm b.wasm -o pkg/`）在本次整改中实现，验收是"`m1.grow()` 之后 `m2.size()` 变大"的一个可执行用例；在此之前，跨包共享写进 `BOUNDARY.md`，不假装支持。

## 7. 仍然需要人做的

- **函数导入**：生成的 `h{i}` 是 `trap` 桩，签名真实、行为没有。宿主必须替换函数体——宿主函数的行为不在二进制里，猜就是伪造。
- **跨包（未合并）的表内容**：表槽位存的是**本包函数索引**，把 A 包的表交给 B 包没有意义。合并进同一个包之后才有意义。
- **`table.set` / `table.grow`**：引用类型提案，不在 1.0，报 `E101`。

## 8. 复现

```bash
moon run cmd/main -- decompile corpus/good/alias.wasm -o /tmp/alias   # 看 MoonliftExterns 只有一个 env_counter
cd /tmp/alias && moon check                                            # 零错误零告警
bash script/sharing.sh                                                 # 5 条绑定属性
bash script/verify.sh corpus/good/alias.wasm                           # 17 个调用与 Node 逐值一致
```

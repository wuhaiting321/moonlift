# 导入：四条边界的落地方式

本文回答一个问题：一个**从宿主链接进来**的 wasm 模块——内存、表、全局都是从外面来的——被 moonlift 反编译之后，这些东西去哪了？

结论先说：它们被**物化**（materialised）成生成包里的模块级状态，尺寸取模块声明的下限，内容为零；宿主可以在 `moonlift_init()` 之前把需要的内容写进去。唯一的例外是"段偏移来自导入全局"的那种模块，它的段布局被推迟到 `moonlift_init()` 里执行，因为地址只有宿主知道。

对照的是 `corpus/good/imported.wasm`（手写，273 字节，五个导入：`env.mem` / `env.tbl` / `env.base` / `env.bump` / `env.host_add`）。

## 1. 四种导入，两种命运

| 导入种类 | 生成包里是什么 | 宿主需要做什么 |
|---|---|---|
| 函数 `(import "env" "f" (func ...))` | `pub fn h0(...) -> T { trap("import 0 is not implemented") }` | **必须**用真实实现替换函数体；签名已经是对的 |
| 内存 `(import "env" "mem" (memory 1 2))` | `pub let mem : Memory = make_memory()`，`Memory::new(1, 2)` | 可选：`moonlift_init()` 之前写入字节 |
| 表 `(import "env" "tbl" (table 8 funcref))` | `pub let __ml_table : Array[Int]`，长度 8，槽位 `-1`（空） | 可选：`moonlift_init()` 之前改槽位；`elem` 段会自动填 |
| 全局 `(import "env" "base" (global i32))` | `pub let g0 : Ref[Int] = Ref(0)` | 可选：`g0.val = 4`，再调 `moonlift_init()` |

"物化"是一个诚实的说法：对象存在、尺寸正确、可被索引、越界照样陷阱，但**内容是空的**。wasm 里这些内容的来源是宿主，而宿主不在二进制里——猜一个值比留空更糟，所以留空并把写入点写进文档。

## 2. 生成的代码长什么样

`moonlift decompile corpus/good/imported.wasm -o out/` 之后，`out/module.mbt` 的相关片段（原文，未改写）：

```moonbit
// Globals. Every one is a `Ref`, mutable or not, so that a store is
// `g3.val = ...` and a load is `g3.val` — one spelling for both.
//
// The first 2 are imported. The host owns them and may
// assign before calling moonlift_init(); zero is "never assigned", which
// is also what wasm gives a global nothing ever wrote to.
pub let g0 : Ref[Int] = Ref(0)
pub let g1 : Ref[Int] = Ref(0)

///|
/// The module's linear memory. Declared data segments are copied in here;
/// one placed at a `global.get` waits for `moonlift_init()`, because its
/// address is not known until the host has set that global.
pub let mem : Memory = make_memory()

///|
fn make_memory() -> Memory {
  let m = Memory::new(1, 2)
  m.init_bytes(0, b"\x61\x62\x63")   // (data (i32.const 0) "abc")
  m
}
```

而被推迟的那一段：

```moonbit
///|
/// Segments whose address is a `global.get`. They run from
/// `moonlift_init()`, after the host has set the imported global they name —
/// which is what instantiation does with them, too.
fn __ml_layout() -> Unit {
  mem.init_bytes(g0.val, b"\x58\x59")            // (data (global.get $base) "XY")
  // element segment 1, placed at g0.val
  let at1 = g0.val
  if at1 < 0 || at1 + 1 > __ml_table.length() {
    trap("element segment 1 does not fit table[0..8)")
  }
  __ml_table[at1 + 0] = 1                        // (elem (global.get $base) $double)
}

pub fn moonlift_init() -> Unit {
  // segments whose address comes from an imported global
  __ml_layout()
}
```

为什么不在模块加载时就铺好？因为 `pub let mem` 在包加载时求值，那个时刻宿主还没有机会执行 `g0.val = 4`。wasm 的语义是"实例化时铺"，而 `moonlift_init()` 就是生成包里的"实例化"——所以推迟到那里，语义反而更准。

## 3. 行为等价：同一组调用，两边都跑

`base = 4` 是这组用例的关键：默认 `base = 0` 时两个 data 段重叠，偏移算错也能读到"对的"字节；`base = 4` 之后，常量段留在 0、`global.get` 段搬到 4，错一位都看得见。

| 调用 | 原件（Node，`base=4`） | 生成包（`wasm-gc`，`g0.val = 4` 后 `moonlift_init()`） |
|---|---|---|
| `load0()` | `97`（`'a'`，常量段仍在 0） | `97` |
| `loadbase()` | `88`（`'X'`，段跟着 `base` 搬到 4） | `88` |
| `viabase(0)` | `10`（`table[4]` 由 `elem` 段填成 `$double`） | `10` |
| `bump1()` ×2 | `1`, `2`（导入的可变全局是模块自己的状态） | `1`, `2` |
| `memsize()` | `1`（导入内存的声明下限） | `1` |

复现：

```bash
moon run cmd/main -- verify corpus/good/imported.wasm -o /tmp/imp     # 写 calls.tsv（含 host 行）
cd corpus/tools
node oracle.js ../good/imported.wasm \
  '[["load0",[]],["loadbase",[]],["bump1",[]],["viabase",[0]],["memsize",[]]]' \
  /tmp/imp/calls.tsv '{"env.base":4}'
```

`script/verify.sh` 会自动跑这条路径（默认 `base = 0`，两边一致），`script/check.sh` 里再用 `script/smoke/imported_wbtest.mbt` 把 `base = 4` 的五个期望值钉住。

## 4. 宿主接入步骤

1. `moonlift info x.wasm` → 看 `imports` 行的四类计数，看 `tables` / `memories` / `globals` 的声明下限。
2. `moonlift decompile x.wasm -o out/` → 生成包，被拒绝的函数已经在 `--struct-stats` 里点过名。
3. `cd out && moon check` → 零告警是常态；有告警就是生成器的 bug。
4. 有函数导入 → 把 `h0` / `h1` … 的函数体换成真实实现（**这一步只能人工**，宿主语义无法从二进制猜出来）。
5. 需要预置内存 / 表 / 全局 → 在 `moonlift_init()` 之前赋值（全局 `g0.val = ...`；内存用 `mem.init_bytes`；表用 `__ml_table[i] = <函数索引>`）。
6. 宿主调一次 `moonlift_init()`：铺 `global.get` 段、跑 `start` 段。之后所有导出都可以调用。
7. `bash script/verify.sh x.wasm` → 与 Node 跑原件逐值比对。

## 5. 仍然需要人或无法做到的部分

- **函数导入没有默认实现**：生成的桩一律 `trap`，宿主必须接管。这是设计而非缺口——猜一个宿主函数的行为等于伪造语义。
- **运行期增删表项（`table.set` / `table.grow`）**：属于引用类型提案，不在 1.0；`__ml_table` 是编译期常量数组。
- **导入内存的初始内容**：不在二进制里。`Memory::new` 给的是全零，`memory.size` 与越界检查都是对的，但字节要宿主自己写。
- **多内存 / 多表**：1.0 至多各一个，多一个报 `E106`。
- **段偏移指向可变全局或模块自定义全局**：规范不允许（偏移必须每次实例化都一样），报 `E012`。

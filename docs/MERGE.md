# 跨模块共享：一次反编译两个模块

本文回答《共享导入》之后的下一层问题：**两个 wasm 模块导入同一个内存或同一张表，宿主交进去的是同一个实例时，`A.memory.grow` 之后 `B.memory.size` 必须变大，A 的 element 段填的槽位 B 必须调得到。**

在这个仓库里，内存这一半卡在一个类型上，表这一半卡在一个**索引**上，两者都不是卡在指令上。

## 1. 为什么"两个包 + 同一个对象"做不到

生成包是自包含的：每个包里都有一份 `runtime.mbt`。于是

```moonbit
// pkg_a/memory.mbt（生成）
pub struct Memory { ... }
```

```moonbit
// pkg_b/memory.mbt（生成，另一个包）
pub struct Memory { ... }
```

`pkg_a.Memory` 与 `pkg_b.Memory` 是**两个不同的类型**，即使字段一样（`Table` 同理）。宿主手里没有"能同时递给两边"的值：

- 传两次 `Memory::new(1, 4)`：两个对象，A `grow` 之后 B 还是 1 页 —— 这正是要避免的错误答案；
- 复制字段过去：`grow` 会换掉内部数组（`self.data = fresh`），之后两份立刻分叉，而且不报错。

这不是实现缺陷，是"一个包一个运行时"的必然结果。把它写进 `BOUNDARY.md` 说"跨包不支持"是诚实的，但评审问的是**必要语义**，而这条语义在 1.0 里是成立的。

## 2. 做法：把两个模块放进同一个包

```bash
moon run cmd/main -- decompile corpus/good/shared_a.wasm corpus/good/shared_b.wasm -o pkg
```

```
2 modules -> pkg/
  corpus/good/shared_a.wasm
    prefix m0_  functions 2 emitted, 0 refused, 0 skipped  exports 2
  corpus/good/shared_b.wasm
    prefix m1_  functions 2 emitted, 0 refused, 0 skipped  exports 2
files      moon.mod moon.pkg module.mbt funcs.mbt exports.mbt all.mbt runtime.mbt
```

三条规则，没有一条是新的语义：

1. **每个顶层名字带前缀**：`m0_f0`、`m1_f0`、`m0___ml_mem`、`m1_moonlift_bind`。MoonBit 一个包只有一个命名空间，而每个模块都想要 `f0`、`mem`、`__ml_externs`。前缀是唯一的冲突解决办法，也是唯一能让人一眼看出某行代码属于哪个模块的办法。
2. **类型名首字母大写**：`m0_MoonliftExterns` 不是合法类型名，生成的是 `M0_MoonliftExterns`。值用 `m0_`，类型用 `M0_`，规则写在 `type_pre` 里，`core/emit_wbtest.mbt` 钉住。
3. **一个实例化入口**：`all.mbt` 里生成 `moonlift_init_all()`，按输入顺序调用每个模块的 `moonlift_init()`。绑定仍然是逐模块的（每张记录形状不同），初始化可以一次做完。

单个模块不进前缀：`decompile m.wasm` 的输出与引入前缀之前**逐字节相同**（`core/emit_wbtest.mbt` 与门禁里的生成包检查都在钉这一点）。前缀只在"这个包里不止一个模块"时出现。

## 3. 生成代码

`module.mbt`：两张记录，同一个导入字段名。

```moonbit
// ===== module 0 (`m0_`) =====
pub struct M0_MoonliftExterns {
  env_mem : Memory
}

pub fn m0_moonlift_bind(e : M0_MoonliftExterns) -> Unit { ... }

fn m0___ml_layout() -> Unit {
  m0___ml_mem().init_bytes(8, b"\x2a\x00\x00\x00")   // shared_a 的 data 段
}

// ===== module 1 (`m1_`) =====
pub struct M1_MoonliftExterns {
  env_mem : Memory                                     // 同一个名字
}

pub fn m1_moonlift_bind(e : M1_MoonliftExterns) -> Unit { ... }
```

`all.mbt`：

```moonbit
pub fn moonlift_init_all() -> Unit {
  m0_moonlift_init()
  m1_moonlift_init()
}
```

`exports.mbt`：导出名带前缀，因为两个模块可能导出同名函数。

```moonbit
pub fn m0_grow(l0 : Int) -> Int { return m0_f0(l0) }
pub fn m1_pages() -> Int { return m1_f0() }
pub fn m1_peek(l0 : Int) -> Int { return m1_f1(l0) }
```

宿主侧就是三行：

```moonbit
let shared = Memory::new(1, 4)          // 一个实例
m0_moonlift_bind({ env_mem: shared })   // 交给 A
m1_moonlift_bind({ env_mem: shared })   // 同一个交给 B
moonlift_init_all()                     // 段铺进这个实例
```

## 4. 迁移前后行为

`corpus/good/shared_a.wasm`（91 B）有 `memory.grow` 和一段写在地址 8 的 `42`；`corpus/good/shared_b.wasm`（74 B）只读：`memory.size` 与 `i32.load8_u`。

| 步骤 | 原件（Node，一个 `WebAssembly.Memory` 喂两个实例） | 两个包（各一份 `Memory` 类型） | 合并成一个包（本版） |
|---|---|---|---|
| `b.peek(8)`（A 的 data 段） | **42** | 42（各铺各的） | **42** |
| `b.pages()` | **1** | 1 | **1** |
| `a.grow(1)` | **1**（返回旧页数） | 1 | **1** |
| `b.pages()` | **2** | **1** ❌ | **2** |
| `a.store(100, 7)`；`b.peek(100)` | **7** | 7（若宿主手工同步） | **7** |

第三行到第四行是全部意义所在：两个包那一列**在类型上不可能**做到，不是"没实现"。合并之后它是普通断言：

```moonbit
let shared = Memory::new(1, 4)
m0_moonlift_bind({ env_mem: shared })
m1_moonlift_bind({ env_mem: shared })
moonlift_init_all()
inspect(m1_pages(), content="1")
inspect(m0_grow(1), content="1")
inspect(m1_pages(), content="2")     // 门禁里的一行
```

反面对照也在同一份测试里：绑**两个**不同的 `Memory`，`m0_grow(2)` 之后 `m1_pages()` 仍是 1。共享是宿主的选择，不是合并偷偷做的。

## 5. 共享函数表：一张表，两个模块

表是 1.0 的另一种 externval，语义和内存一样：同一个表被两个模块导入时，**A 的 element 段填的槽位，B 的 `call_indirect` 能调到，并且调到的是 A 的函数**。这一层比内存难，因为它卡在索引上。

### 5.1 卡在哪：每个模块的函数都从 `0` 开始

槽位里存的是函数索引。按模块编号时，A 的 `$answer` 是 `0`，B 自己的第一个函数也是 `0`：

```
A: t[0] = 0     // A 的 answer，返回 42
B: t[0] -> 0 -> B 的 f0，返回 7      ← 能编译、算错
```

### 5.2 做法：一个包一个函数索引空间

| 规则 | 位置 |
|---|---|
| 模块 `i` 的函数基址 = 前面所有模块函数数之和 | `emit_package_multi` 的 `bases` |
| element 段写 `t.set(at, base + f)` | `layout_text` |
| 每个 dispatcher 除自己的函数外，还列**同包其它模块**的函数 | `dispatcher_arms` |

生成的原文（`module.mbt`，B 的 dispatcher）：

```moonbit
pub fn m1___ml_indirect_t0(i : Int) -> Int {
  match m1___ml_table_at(i) {
    2 => m1_f0()      // B 自己的函数 0
    3 => m1_f1()      // B 自己的函数 1
    0 => m0_f0()      // A 的 answer：A 的段填了这个槽
    1 => m0_f1()
    _ => trap("call_indirect: table[" + i.to_string() + "] does not have type () -> Int")
  }
}
```

单模块时 `base = 0`、无兄弟，`2 => m1_f0()` 这一行不会出现，输出与引入索引空间之前**逐字节相同**。

### 5.3 表是 `Table`，不是 `Array[Int]`

表升级成 `runtime.mbt` 里的一个类型，理由和 `Memory` 一样：每个生成包自带一份 runtime，`pkg_a.Table` 与 `pkg_b.Table` 是两个类型。于是"两个分开的包共享一张表"不是靠文档禁止，而是**编译不过**——否则同一张表在两边编号不同，又是一次"能编译、算错"。

宿主只需交同一个 `Table`：

```moonbit
let tab = Table::new(2)                 // 一张空的表：2 个槽位，全 null（-1）
m0_moonlift_bind({ env_tab: tab })
m1_moonlift_bind({ env_tab: tab })
moonlift_init_all()                     // A 的 element 段写进这张表
inspect(m0_a_slot0(), content="42")     // A 调自己的槽位
inspect(m1_b_slot0(), content="42")     // B 调同一个槽位：调到的是 A 的函数
```

### 5.4 迁移前后行为

`corpus/good/shared_tab_a.wasm`（74 B）把返回 42 的 `$answer` 放进槽位 0；`corpus/good/shared_tab_b.wasm`（65 B）只从槽位 0 取函数，它自己的函数 0 返回 **7**——所以按模块编号的实现会答 7，而不是 42。

| 步骤 | 原件（Node，一个 `WebAssembly.Table` 喂两个实例） | 按模块编号（旧） | 两个包（各一份 `Table` 类型） | 合并成一个包（本版） |
|---|---|---|---|---|
| `b.b_slot0()` | **42** | **7** ❌ | 类型上不可能 | **42** |
| `a.a_slot0()` | **42** | 42 | 42 | **42** |
| 槽位 1（没人填） | `null`，调用则 trap | `-1` | `-1` | **`-1`** |
| 绑两张不同的表后 `m1` 的槽位 0 | `null` | — | `-1` | **`-1`**（共享是宿主的选择） |

## 6. 仍未自动化的部分

- **函数导入**：`m0_h{i}` / `m1_h{i}` 仍是 `trap` 桩，行为必须由人补。合并只解决"名字不冲突"，不解决"宿主的函数是什么"。
- **跨包（未合并）的表共享**：和内存一样，两个分开的包不能共用一张表——`pkg_a.Table` 与 `pkg_b.Table` 是不同类型，这是编译错误而不是"能编译、算错"。合并进一个包即可（§5）。
- **表里放函数导入**：`elem` 可以引用一个导入的函数，槽位里于是是 `h{i}` 桩的编号，调到它就 trap。宿主函数的行为不在二进制里，这一点与直接调用导入一致。
- **多于两个模块**：前缀编号按输入顺序，`m0_`、`m1_`、`m2_`…… 语义不变，`moonlift_init_all()` 按同一顺序调用。没有做拓扑排序：`start` 之间如果互相依赖（通过导入的全局），顺序由命令行决定，这一点写在 §6 的错误处理里而不是猜。
- **`verify` 命令仍是单模块**：差分验证一次对一个模块跑 Node 对照，合并包的对照需要一个新的 oracle 场景（两个实例、一个内存），不在本次范围。

## 7. 复现

```bash
bash script/merge.sh
# ok   merge: two modules, one package                          2 prefixed
# ok   merge: the merged package compiles cleanly               moon check
# ok   merge: one name per import, two records                  env_mem × 2
# ok   merge: one instantiation entry point                     moonlift_init_all
# ok   merge: one memory, four properties                       Total tests: 4, passed: 4, failed: 0.
# ok   table: two modules, one table                            2 prefixed
# ok   table: the merged package compiles cleanly               moon check
# ok   table: one index space, both modules in it               0 => m0_f0, 2 => m1_f0
# ok   table: one table, three properties                       Total tests: 3, passed: 3, failed: 0.
```

单测（不需要编译器，纯文本）：

```bash
moon test --target wasm-gc -p moonlift/core
# 前缀、类型名大写、init_all 的顺序、单个模块不进前缀、
# 表的索引空间：0 => m0_f0 / 2 => m1_f0，单模块仍是本地索引
```

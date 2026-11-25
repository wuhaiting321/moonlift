# 跨模块共享：一次反编译两个模块

本文回答《共享导入》之后的下一层问题：**两个 wasm 模块导入同一个内存/表，宿主交进去的是同一个实例时，`A.memory.grow` 之后 `B.memory.size` 必须变大。**

在这个仓库里，这条语义卡在一个类型上，而不是卡在一条指令上。

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

`pkg_a.Memory` 与 `pkg_b.Memory` 是**两个不同的类型**，即使字段一样。宿主手里没有"能同时递给两边"的值：

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

## 5. 仍未自动化的部分

- **函数导入**：`m0_h{i}` / `m1_h{i}` 仍是 `trap` 桩，行为必须由人补。合并只解决"名字不冲突"，不解决"宿主的函数是什么"。
- **表内容的跨模块共享**：表的槽位存的是**本模块函数索引**。把两个模块的表当成一张，索引空间就对不上了；一个模块 `call_indirect` 跳到另一个模块的函数，仍然需要人工改表或改成显式的 `import`。1.0 允许表导入，但表里存什么不在二进制里。
- **多于两个模块**：前缀编号按输入顺序，`m0_`、`m1_`、`m2_`…… 语义不变，`moonlift_init_all()` 按同一顺序调用。没有做拓扑排序：`start` 之间如果互相依赖（通过导入的全局），顺序由命令行决定，这一点写在 §6 的错误处理里而不是猜。
- **`verify` 命令仍是单模块**：差分验证一次对一个模块跑 Node 对照，合并包的对照需要一个新的 oracle 场景（两个实例、一个内存），不在本次范围。

## 6. 复现

```bash
bash script/merge.sh
# ok   merge: two modules, one package                          2 prefixed
# ok   merge: the merged package compiles cleanly               moon check
# ok   merge: one name per import, two records                  env_mem × 2
# ok   merge: one instantiation entry point                     moonlift_init_all
# ok   merge: one memory, four properties                       Total tests: 4, passed: 4, failed: 0.
```

单测（不需要编译器，纯文本）：

```bash
moon test --target wasm-gc -p moonlift/core
# 前缀、类型名大写、init_all 的顺序、单个模块不进前缀
```

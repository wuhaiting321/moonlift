# 导入：四类外部值怎么进到生成包里

本文回答一个问题：一个**从宿主链接进来**的 wasm 模块——内存、表、全局、函数都是从外面来的——被 moonlift 反编译之后，这些东西在哪？

结论先说：内存、表、全局由宿主通过 `moonlift_bind()` **绑定**进来，生成代码直接使用宿主给的对象，不复制、不预填；函数导入生成真实签名的 `trap` 桩，必须由人接管。别名（同一个 `(module, name)` 被导入两次）与实例化的时刻，见 [SHARING.md](SHARING.md)。

对照 `corpus/good/imported.wasm`（手写，五个导入：`env.mem` / `env.tbl` / `env.base` / `env.bump` / `env.host_add`）。

## 1. 四种导入，两种处理

| 导入种类 | 生成包里是什么 | 宿主需要做什么 |
|---|---|---|
| 内存 `(import "env" "mem" (memory 1 2))` | `pub struct MoonliftExterns { env_mem : Memory ... }`；`__ml_mem()` 返回绑定值 | `moonlift_bind({ env_mem: m, ... })`，**不需要预先写入字节** |
| 表 `(import "env" "tbl" (table 8 funcref))` | `env_tbl : Array[Int]`，默认是 8 个 `-1` | 同上；`elem` 段由 `moonlift_init()` 填 |
| 全局 `(import "env" "base" (global i32))` | `env_base : Ref[Int]`，默认 `Ref(0)` | 同上；两个同名导入共用一个字段（见 SHARING.md） |
| 函数 `(import "env" "f" (func ...))` | `pub fn h0(...) -> T { trap("import 0 is not implemented") }` | **必须**换成真实实现，签名已经是对的 |

旧版把前三类"物化"成本地副本、要求宿主预填；这一版不再这样做。原因在 `SHARING.md` §1–§2：副本会切断别名，"预填"则要求宿主猜一个本该由绑定关系决定的顺序。

## 2. 生成的代码（原文）

```moonbit
pub struct MoonliftExterns {
  env_tbl : Array[Int]
  env_mem : Memory
  env_base : Ref[Int]
  env_bump : Ref[Int]
}

///|
fn default_externs() -> MoonliftExterns {
  {
    env_tbl: Array::make(8, -1),
    env_mem: Memory::new(1, 2),
    env_base: Ref(0),
    env_bump: Ref(0),
  }
}

pub fn moonlift_bind(e : MoonliftExterns) -> Unit {
  __ml_externs.val = e
  __ml_pending.val = true
}

///|
pub fn __ml_mem() -> Memory {
  __ml_externs.val.env_mem
}

///|
pub fn mem() -> Memory {
  __ml_mem()
}

pub fn g0() -> Ref[Int] {
  __ml_externs.val.env_base
}
```

段不在包加载时铺，全部在实例化时铺：

```moonbit
fn __ml_layout() -> Unit {
  __ml_mem().init_bytes(0, b"\x61\x62\x63")            // (data (i32.const 0) "abc")
  __ml_mem().init_bytes(g0().val, b"\x58\x59")         // (data (global.get $base) "XY")
  let t = __ml_table()
  // element segment 0, placed at 2
  let at0 = 2
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

`moonlift_init()` 是幂等的，且"每次 `moonlift_bind()` 之后重新武装一次"：实例化对一个模块只发生一次，重复调用不能把模块写过的内存盖回段的初始内容。这条不是细节——改之前 `memory.wasm` 的 `floats(7)` 就是被重复铺段盖掉的。

## 3. 行为等价（`base = 4`）

`base = 4` 是关键：默认 0 时两个 data 段重叠，偏移算错也能读到"对的"字节；4 之后常量段留在 0、`global.get` 段搬到 4，错一位都看得见。

| 调用 | 原件（Node，`base=4`） | 生成包（绑定 `base: Ref(4)` 后 `init`） |
|---|---|---|
| `load0()` | `97`（`'a'`） | `97` |
| `loadbase()` | `88`（`'X'`） | `88` |
| `viabase(0)` | `10` | `10` |
| `bump1()` ×2 | `1`, `2` | `1`, `2` |
| `memsize()` | `1` | `1` |

这五个值由 `script/sharing.sh` 与 `script/smoke/imported_wbtest.mbt` 两处钉住，后者走 `check.sh`。

## 4. 宿主接入步骤

1. `moonlift info x.wasm` → 看 `imports` / `tables` / `memories` / `globals` 的导入计数与声明下限。
2. `moonlift decompile x.wasm -o out/` → 生成包；被拒绝的函数已在 `--struct-stats` 里点名。
3. 打开 `out/module.mbt` 的 `MoonliftExterns`：**字段就是你要交的东西**——内存、表、每个不同的 `(module, name)` 全局各一个。
4. 写绑定与实例化两行：
   ```moonbit
   moonlift_bind({ env_mem: my_memory, env_tbl: my_table, env_base: Ref(4), env_bump: Ref(0) })
   moonlift_init()
   ```
   顺序不能反：段铺在绑定的实例上。
5. 有函数导入 → 把 `h0` / `h1` … 的函数体换成真实实现（这一步只能人工）。
6. `cd out && moon check` → 零错误零告警是常态；有告警就是生成器的 bug。
7. `bash script/verify.sh x.wasm` → 与 Node 跑原件逐值比对。

## 5. 边界

- **函数导入没有默认实现**：桩一律 `trap`。猜宿主函数的行为等于伪造语义。
- **`table.set` / `table.grow`**：引用类型提案，不在 1.0；`__ml_table()` 是普通数组，只有 `elem` 段会写它。
- **段偏移指向可变全局或模块自定义全局**：规范不允许（偏移必须每次实例化都一样），报 `E012`。
- **跨包共享同一内存**：每个生成包自带 `runtime.mbt`，类型不同名，宿主无法把同一个 `Memory` 交给两个包；需把多个模块反编译进同一个包。见 `SHARING.md` §6 与 `BOUNDARY.md`。
- **多内存 / 多表**：1.0 至多各一个，多一个报 `E106`。

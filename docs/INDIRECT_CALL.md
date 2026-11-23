# 函数表与间接调用：迁移前后行为与人工接入步骤

> 对应初审意见：「请补充完整标准支持的目标范围，并用含函数表间接调用的模块说明迁移前后行为及人工接入步骤。」
>
> 本文每个输出都是 `moonlift` 与 `bash script/indirect.sh` 的真实运行结果，不是示意。复现命令见第 6 节。

WebAssembly 1.0 的 `call_indirect` 是**唯一一条目标地址在运行期才知道的指令**：C 的函数指针、C++ 的虚表、Rust 的 `dyn`、解释器的 dispatch 循环，编译出来都是它。因此它不是"可选特性"，而是迁移真实产物的必经之路。

## 1. 输入模块

`corpus/src/indirect.wat`（339 B，手写，CC0），一张 8 槽表，5 个函数，3 种签名：

| 槽位 | 函数 | 签名 | 用途 |
|---|---|---|---|
| 0 | `$add1` | `(i32) -> i32` | 一元，`x + 1` |
| 1 | `$dbl` | `(i32) -> i32` | 一元，`x * 2` |
| 2 | `$add` | `(i32, i32) -> i32` | 二元 |
| 3 | `$mul` | `(i32, i32) -> i32` | 二元 |
| 4 | `$const` | `() -> i32` | 零元 |
| 5–7 | — | — | 未初始化（调用即陷阱） |

数据段在地址 0 放了 `0,1,2,3,4` 五个 i32，`vt(which, x)` 从内存里读出函数索引再间接调用——这就是虚表的形状。

## 2. 迁移前：原始 wasm 的行为（Node 22）

```
$ cd corpus/tools && node oracle.js ../good/indirect.wasm '[["apply1",[0,10]], ...]'
apply1(0,10)       = 11
apply1(1,10)       = 20
apply2(2,3,4)      = 7
apply0(4)          = 42
vt(0,10)           = 11
chain(5)           = 14
loopdispatch(3,4)  = 18
apply1(2,10)       = RuntimeError: null function or function signature mismatch
apply1(7,10)       = RuntimeError: null function or function signature mismatch
apply1(9,10)       = RuntimeError: table index is out of bounds
```

注意第 8 行：V8 把"槽位里是 null"和"槽位里的函数签名不对"合并成一条消息。wasm 语义里它们是两种不同的陷阱，我们的实现分开报。

## 3. 迁移后：生成的 MoonBit（`moonlift decompile` 的真实输出）

表按函数索引保存，`-1` 表示没有元素段填过的槽位：

```moonbit
fn build_table() -> Array[Int] {
  let t = Array::make(8, -1)
  // element segment 0: table[0..5]
  if 0 < 0 || 0 + 5 > t.length() {
    trap("element segment 0 does not fit table[0..8)")
  }
  t[0] = 0
  t[1] = 1
  t[2] = 2
  t[3] = 3
  t[4] = 4
  t
}
```

调用前两道检查（索引越界、槽位为空），然后是**类型检查**：

```moonbit
pub fn __ml_table_at(i : Int) -> Int {
  if i < 0 || i >= __ml_table.length() {
    trap("call_indirect: index " + i.to_string() + " is outside table[0.." + __ml_table.length().to_string() + ")")
  }
  let f = __ml_table[i]
  if f < 0 {
    trap("call_indirect: table[" + i.to_string() + "] is uninitialised")
  }
  f
}

pub fn __ml_indirect_t0(i : Int, a0 : Int) -> Int {
  match __ml_table_at(i) {
    0 => f0(a0)
    1 => f1(a0)
    7 => f7(a0)
    9 => f9(a0)
    11 => f11(a0)
    _ => trap("call_indirect: table[" + i.to_string() + "] does not have type (Int) -> Int")
  }
}
```

关键设计：**类型检查不是运行期比较，而是分支集合**。签名与 `type 0` 结构等价的函数才出现在分支里，其余函数索引落不到任何分支，直接进陷阱——这正是 wasm 引擎做的检查，只是从"运行期比较"变成了"编译期枚举"。按**签名**而不是按类型索引分组，是因为 1.0 的类型检查是结构等价：模块里可以有两个签名相同的 type 条目，按索引分组会拒掉原模块接受的调用。

`vt` 从内存读索引那一行，生成出来是：

```moonbit
t0 = __ml_indirect_t0(mem.load_i32((p0 * 4)), p1)
```

## 4. 行为对照（两侧真实运行）

| 调用 | 迁移前（Node 跑原始 wasm） | 迁移后（生成包，wasm-gc） | 判定 |
|---|---|---|---|
| `apply1(0, 10)` | `11` | `11` | 一致 |
| `apply1(1, 10)` | `20` | `20` | 一致 |
| `apply2(2, 3, 4)` | `7` | `7` | 一致 |
| `apply0(4)` | `42` | `42` | 一致 |
| `vt(0, 10)` | `11` | `11` | 一致 |
| `chain(5)` | `14` | `14` | 一致 |
| `loopdispatch(3, 4)` | `18` | `18` | 一致 |
| `apply1(2, 10)`（槽里是二元函数） | `RuntimeError: null function or function signature mismatch` | `trap: call_indirect: table[2] does not have type (Int) -> Int` | 同陷阱 |
| `apply1(7, 10)`（空槽） | `RuntimeError: null function or function signature mismatch` | `trap: call_indirect: table[7] is uninitialised` | 同陷阱 |
| `apply1(9, 10)`（越界） | `RuntimeError: table index is out of bounds` | `trap: call_indirect: index 9 is outside table[0..8)` | 同陷阱 |

全量不是这 10 条，而是**每一个计划中的调用**：`corpus/tools/oracle.js` 给出每个调用的参考结果，`script/indirect.sh` 一个进程跑一个用例（陷阱会结束进程，所以不能挤在一个测试里），逐条比"值相等"或"两侧都陷阱"，并且当参考侧的陷阱来自表时，要求我方消息里出现 `call_indirect`——避免把别处的崩溃算成正确的陷阱。

```
$ bash script/indirect.sh
fixture       cases  value   trap failed  note
indirect        106     65     41      0  memory access out of bounds;null function or function signature mismatch;table index is out of bounds
table            44     37      7      0  null function or function signature mismatch;table index is out of bounds
```

150 个用例：102 个值相等，48 个两侧同陷阱，0 失败。

## 5. 人工接入步骤

生成一个能跑的包，人要做的事只有 5 件，其中 3 件在**没有函数表**的模块里也一样要做：

1. `moonlift info lib.wasm` —— 看表的大小、元素段、导入。
2. `moonlift decompile lib.wasm -o lib_mbt/` —— 写出 6 个文件。含 `call_indirect` 的函数**不再是桩**，是真实函数体。
3. `cd lib_mbt && moon check` —— 生成包零依赖，编译即验证。
4. **（必须人工）** 如果模块有函数导入：`module.mbt` 里的 `h0`、`h1` … 是陷阱桩，它们的语义在宿主里，必须替换成真实实现。这一步与函数表无关。
5. **（必须人工）** 宿主在调用任何导出前调一次 `moonlift_init()`（对应 wasm 的 `start` 段与实例化）。
6. `bash script/verify.sh lib.wasm` —— 用 Node 跑原件，与生成包逐调用比对。

**函数表本身不需要人介入**：表内容、槽位顺序、空槽、三类陷阱都由 `elem` 段与 `Array[Int]` 直接还原。这正是这次修改的意义——之前 `E111` 要求"手工内联间接调用"，而运行期索引根本无法内联。

## 6. 什么情况下表还需要人动

三件事 1.0 里做不到，需要人工决策，逐条说明：

| 情况 | 为什么 | 人的动作 |
|---|---|---|
| 运行期 `table.set` / `table.grow` | 这两个指令属于 reference-types 提案，不是 1.0；1.0 的表只能由 `elem` 段在实例化时填一次 | 不在 1.0 目标范围内；遇到时按 `E110`/`E006` 报码停止 |
| 宿主提供表（`(import "env" "table")`） | 表内容在宿主里决定，二进制里只有尺寸 | 生成包按声明尺寸建表；宿主若预填过内容，需在 `moonlift_init` 之前写入 `__ml_table` |
| 元素段偏移读导入全局 | 1.0 允许，但那个值在宿主里（例如 `__table_base`） | 目前按"偏移未知"拒绝该模块（`E010` + 偏移），人工把 `.wat` 里的偏移改成常量后重跑 |

## 7. 复现

```sh
moon run cmd/main -- info corpus/good/indirect.wasm
moon run cmd/main -- disasm corpus/good/indirect.wasm --struct
moon run cmd/main -- decompile corpus/good/indirect.wasm -o /tmp/ind
bash script/indirect.sh          # 陷阱与值，一个用例一个进程
bash script/verify.sh corpus/good/indirect.wasm
bash script/check.sh             # 全量门禁，含上面两项
```

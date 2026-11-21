#!/usr/bin/env python3
"""Build the extended corpus: real MoonBit compiler output, one module per source.

Each source in ``sources/`` is a small, self-contained MoonBit program. We put it
in a throwaway module, run ``moon build --target wasm`` (the MVP backend), and
copy the resulting ``main.wasm`` into ``corpus/extended/``. Nothing here is
hand-assembled: every byte comes from the compiler, and the source that produced
it sits next to this script so the build is reproducible.

Usage:
    python corpus/tools/gen_corpus.py            # build every source
    python corpus/tools/gen_corpus.py NAME ...   # build just these

The binaries are committed. This script is not run by ``script/check.sh``; the
check script only reads the binaries, so the whole project works offline.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(HERE, "sources")
OUT = os.path.join(ROOT, "corpus", "extended")

# Every program prints its result. An executable package that computes and
# discards everything may be optimised away, which would make all 30 modules the
# same trivial wasm and defeat the point of having a corpus.
PROGRAMS = {
    "arith_i32": r'''
fn main {
  let a = 37
  let b = 5
  println(a + b)
  println(a - b)
  println(a * b)
  println(a / b)
  println(a % b)
  println(a & b)
  println(a | b)
  println(a ^ b)
}
''',
    "arith_i64": r'''
fn main {
  let a : Int64 = 4294967296L
  let b : Int64 = 7L
  println(a + b)
  println(a - b)
  println(a * b)
  println(a / b)
  println(a % b)
  println(a.asr(3))
}
''',
    "arith_double": r'''
fn main {
  let a = 3.5
  let b = 1.25
  println(a + b)
  println(a - b)
  println(a * b)
  println(a / b)
  println(a.sqrt())
}
''',
    "arith_float": r'''
fn main {
  let a : Float = (3.5 : Float)
  let b : Float = (1.25 : Float)
  println((a + b).to_double())
  println((a * b).to_double())
  println((a / b).to_double())
}
''',
    "cmp_int": r'''
fn main {
  let a = 17
  let b = 23
  println(a < b)
  println(a > b)
  println(a <= b)
  println(a >= b)
  println(a == b)
  println(a != b)
}
''',
    "cmp_float": r'''
fn main {
  let a = 2.5
  let b = 2.5000001
  println(a < b)
  println(a >= b)
  println(a == b)
  println(a.is_nan())
  println(a.is_inf())
}
''',
    "conversions": r'''
fn main {
  let i = 12345
  println(i.to_double())
  println(i.to_int64())
  let d = 3.75
  println(d.to_int())
  println(d.trunc())
  println(d.floor())
  println(d.ceil())
}
''',
    "shifts": r'''
fn main {
  let x = 0x12345678
  println(x << 4)
  println(x >> 4)
  println(x & 0xFF)
  println(x ^ 0xFF)
  println(x.clz())
  println(x.ctz())
}
''',
    "minmax": r'''
fn smaller(a : Int, b : Int) -> Int { if a < b { a } else { b } }
fn larger(a : Int, b : Int) -> Int { if a > b { a } else { b } }
fn absolute(a : Int) -> Int { if a < 0 { 0 - a } else { a } }
fn main {
  println(smaller(3, 9))
  println(larger(3, 9))
  println(smaller(-7, -2))
  println(larger(-7, -2))
  println(absolute(-42))
}
''',
    "loop_while": r'''
fn main {
  let mut i = 0
  let mut acc = 0
  while i < 20 {
    acc += i * i
    i += 1
  }
  println(acc)
}
''',
    "loop_for": r'''
fn main {
  let mut acc = 0
  for i in 0..<20 {
    acc += i
  }
  println(acc)
}
''',
    "loop_nested": r'''
fn main {
  let mut acc = 0
  for i in 0..<8 {
    for j in 0..<8 {
      acc += i * j
    }
  }
  println(acc)
}
''',
    "loop_break": r'''
fn main {
  let mut i = 0
  let mut acc = 0
  while true {
    i += 1
    if i % 3 == 0 { continue }
    if i > 25 { break }
    acc += i
  }
  println(acc)
}
''',
    "rec_fact": r'''
fn fact(n : Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}
fn main { println(fact(10)) }
''',
    "rec_gcd": r'''
fn gcd(a : Int, b : Int) -> Int {
  if b == 0 { a } else { gcd(b, a % b) }
}
fn main { println(gcd(1071, 462)) }
''',
    "match_int": r'''
fn classify(n : Int) -> Int {
  match n {
    0 => 100
    1 | 2 => 200
    3..=9 => 300
    _ => 400
  }
}
fn main { println(classify(0) + classify(5) + classify(50)) }
''',
    "match_option": r'''
fn value(o : Int?) -> Int {
  match o {
    Some(x) => x * 2
    None => -1
  }
}
fn main { println(value(Some(21)) + value(None)) }
''',
    "match_result": r'''
fn value(r : Result[Int, String]) -> Int {
  match r {
    Ok(x) => x + 1
    Err(_) => -1
  }
}
fn main { println(value(Ok(41)) + value(Err("no"))) }
''',
    "match_enum": r'''
enum Color {
  Red
  Green
  Blue
}
fn code(c : Color) -> Int {
  match c {
    Red => 1
    Green => 2
    Blue => 3
  }
}
fn main { println(code(Red) + code(Green) + code(Blue)) }
''',
    "struct_point": r'''
struct Point { x : Int; y : Int }
fn norm(p : Point) -> Int { p.x * p.x + p.y * p.y }
fn main {
  let p = { x: 3, y: 4 }
  println(norm(p))
}
''',
    "array_sum": r'''
fn main {
  let a : Array[Int] = [1, 2, 3, 4, 5, 6, 7, 8]
  let mut acc = 0
  for x in a { acc += x }
  println(acc)
  println(a.length())
  println(a[3])
}
''',
    "array_fixed": r'''
fn main {
  let a = FixedArray::make(12, 0)
  let mut i = 0
  while i < a.length() {
    a[i] = i * i
    i += 1
  }
  let mut acc = 0
  for x in a { acc += x }
  println(acc)
}
''',
    "array_grow": r'''
fn main {
  let a : Array[Int] = []
  let mut i = 0
  while i < 16 {
    a.push(i * 3)
    i += 1
  }
  println(a.length())
  println(a[15])
  a[15] = 99
  println(a[15])
}
''',
    "string_ops": r'''
fn main {
  let a = "moon"
  let b = "lift"
  let c = a + b
  println(c)
  println(c.length())
  println(c.substring(start=1, end=5))
  println(c.starts_with("oon"))
}
''',
    "string_chars": r'''
fn main {
  let s = "moonbit"
  let mut acc = 0
  for c in s {
    acc += c.to_int()
  }
  println(acc)
}
''',
    "tuple_values": r'''
fn swap(t : (Int, Int)) -> (Int, Int) { (t.1, t.0) }
fn main {
  let (a, b) = swap((3, 9))
  println(a * 10 + b)
}
''',
    "closure": r'''
fn apply(f : (Int) -> Int, x : Int) -> Int { f(x) }
fn main {
  let k = 7
  println(apply(fn(v) { v * k }, 6))
  println(apply(fn(v) { v + k }, 6))
}
''',
    "generic": r'''
fn[T] twice(x : T, f : (T) -> T) -> T { f(f(x)) }
fn main { println(twice(3, fn(v) { v + 1 })) }
''',
    "trait_impl": r'''
trait Desc { describe(Self) -> Int }
struct Box { v : Int }
impl Desc for Box with describe(self) { self.v * 2 }
fn use_desc(d : Box) -> Int { d.describe() }
fn main { println(use_desc(Box::{ v: 21 })) }
''',
    "table_switch": r'''
fn dispatch(n : Int) -> Int {
  match n {
    0 => 10
    1 => 20
    2 => 30
    3 => 40
    4 => 50
    5 => 60
    6 => 70
    7 => 80
    _ => 90
  }
}
fn main { println(dispatch(3) + dispatch(7) + dispatch(99)) }
''',
    "globals_counter": r'''
let counter : Array[Int] = [0]
fn bump() -> Int {
  counter[0] = counter[0] + 1
  counter[0]
}
fn main {
  let mut acc = 0
  let mut i = 0
  while i < 10 { acc += bump(); i += 1 }
  println(acc)
  println(counter[0])
}
''',
}


def write_sources():
    os.makedirs(SOURCES, exist_ok=True)
    for name, src in PROGRAMS.items():
        with open(os.path.join(SOURCES, name + ".mbt"), "w", encoding="utf-8") as f:
            f.write("// " + name + " — generated source for corpus/extended/" + name + ".wasm\n")
            f.write("// Hand-written for moonlift; no upstream source. CC0.\n")
            f.write(src.lstrip("\n"))


def build(name, src, tmp):
    proj = os.path.join(tmp, name)
    os.makedirs(os.path.join(proj, "main"), exist_ok=True)
    with open(os.path.join(proj, "moon.mod"), "w", encoding="utf-8") as f:
        f.write('name = "gen/' + name + '"\nversion = "0.1.0"\n')
    with open(os.path.join(proj, "main", "moon.pkg"), "w", encoding="utf-8") as f:
        f.write('pkgtype(kind: "executable")\n')
    with open(os.path.join(proj, "main", "main.mbt"), "w", encoding="utf-8") as f:
        f.write(src)
    r = subprocess.run(
        ["moon", "build", "--target", "wasm"],
        cwd=proj, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    if r.returncode != 0:
        print("FAIL build " + name + ":")
        print(r.stdout.strip()[-1200:])
        return None
    wasm = os.path.join(proj, "_build", "wasm", "debug", "build", "main", "main.wasm")
    if not os.path.isfile(wasm):
        print("FAIL no wasm for " + name)
        return None
    return wasm


def main():
    wanted = sys.argv[1:] or sorted(PROGRAMS)
    write_sources()
    os.makedirs(OUT, exist_ok=True)
    sums = []
    failed = []
    with tempfile.TemporaryDirectory(prefix="moonlift_corpus_") as tmp:
        for name in wanted:
            if name not in PROGRAMS:
                print("unknown source: " + name)
                failed.append(name)
                continue
            wasm = build(name, PROGRAMS[name], tmp)
            if wasm is None:
                failed.append(name)
                continue
            dest = os.path.join(OUT, name + ".wasm")
            shutil.copyfile(wasm, dest)
            data = open(dest, "rb").read()
            sums.append((hashlib.sha256(data).hexdigest(), name, len(data)))
            print("ok   %-20s %6d B" % (name, len(data)))
    with open(os.path.join(OUT, "SHA256SUMS"), "w", encoding="utf-8", newline="\n") as f:
        for digest, name, size in sorted(sums, key=lambda x: x[1]):
            f.write("%s  %s.wasm\n" % (digest, name))
    print("\n%d module(s) in corpus/extended/, %d failed" % (len(sums), len(failed)))
    if failed:
        print("failed: " + " ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

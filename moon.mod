// moonlift — WebAssembly (MVP) → compilable MoonBit source decompiler.
//
// Module name follows the `<owner>/<module>` form required by mooncakes.io and
// matches the public repository below.
name = "wuhaiting321/moonlift"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/wuhaiting321/moonlift"

license = "Apache-2.0"

import {
  "moonbitlang/x@0.5.6",
}

keywords = [
  "wasm",
  "webassembly",
  "decompiler",
  "reverse-engineering",
  "codegen",
]

preferred_target = "wasm-gc"

description = "Decompile WebAssembly (MVP subset) binaries into compilable, readable MoonBit source, with differential verification against a reference engine."

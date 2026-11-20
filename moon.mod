// moonlift — WebAssembly (MVP) → compilable MoonBit source decompiler.
//
// Module name follows the `<owner>/<module>` form required by mooncakes.io.
// If the project is later published under a different account, rename here and
// run: grep -rl "moonlift/moonlift" . | xargs sed -i 's|moonlift/moonlift|<owner>/moonlift|g'
name = "moonlift/moonlift"

version = "0.1.0"

readme = "README.md"

repository = ""

license = "Apache-2.0"

keywords = [
  "wasm",
  "webassembly",
  "decompiler",
  "reverse-engineering",
  "codegen",
]

preferred_target = "wasm-gc"

description = "Decompile WebAssembly (MVP subset) binaries into compilable, readable MoonBit source, with differential verification against a reference engine."

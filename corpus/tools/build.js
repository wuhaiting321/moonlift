// Assemble every .wat in corpus/src into corpus/good/<name>.wasm.
//
// Requires only Node and the `wabt` npm package (pure JS/WASM, no native
// toolchain). The generated binaries are committed, so building the corpus is
// never required to run the tests — this script exists so the binaries can be
// regenerated and audited.
//
//   npm i wabt && node corpus/tools/build.js
"use strict";
const fs = require("fs");
const path = require("path");
const wabt = require("wabt");

const root = path.resolve(__dirname, "..");
const srcDir = path.join(root, "src");
const outDir = path.join(root, "good");

// Fixtures that must carry a name section: `info` prints function names only
// when the producer emitted one, and wabt emits it only on request.
const WITH_NAMES = new Set(["fib", "table", "imports"]);

(async () => {
  const wabtModule = await wabt();
  fs.mkdirSync(outDir, { recursive: true });
  const files = fs.readdirSync(srcDir).filter((f) => f.endsWith(".wat")).sort();
  for (const f of files) {
    const name = path.basename(f, ".wat");
    const src = fs.readFileSync(path.join(srcDir, f), "utf8");
    const mod = wabtModule.parseWat(f, src, {
      mutable_globals: true,
      sat_float_to_int: false,
      sign_extension: false,
      simd: false,
      bulk_memory: false,
      reference_types: false,
      multi_value: false,
      tail_call: false,
    });
    mod.resolveNames();
    mod.validate();
    const { buffer } = mod.toBinary({
      canonicalize_lebs: true,
      write_debug_names: WITH_NAMES.has(name),
      log: false,
    });
    const out = path.join(outDir, name + ".wasm");
    fs.writeFileSync(out, Buffer.from(buffer));
    console.log(`${name}.wasm  ${buffer.length} bytes`);
  }
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});

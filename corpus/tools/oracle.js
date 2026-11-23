// The reference engine, for comparison against the generated MoonBit package.
//
//   node oracle.js <file.wasm> '[["fn",[args]], ...]' [host.tsv] [overrides]
//   node oracle.js --json <file.wasm> <calls.tsv>
//
// The first form is for reading by hand and prints `fn(args) = value`. The second
// is what `script/verify.sh` drives: it consumes the `calls.tsv` that
// `moonlift verify` writes and prints one tab-separated line per call:
//
//   ok<TAB>name<TAB>type<TAB>value
//   trap<TAB>name<TAB>type<TAB>reason
//   nan<TAB>name<TAB>type<TAB>-
//   error<TAB>-<TAB>-<TAB>reason
//
// Values are printed the way the generated code will print them, so the
// comparison is a string comparison: integers as decimal, `f32` and `f64` as
// their *bit patterns* (signed decimal). Bits because a decimal float literal has
// to survive a printer on both sides, and the thing a decompiler must never lose
// is the sign of a zero or a NaN payload.
//
// NaN results are reported as `nan` rather than a bit pattern: V8 and a MoonBit
// runtime may canonicalise a NaN produced by arithmetic differently, and that
// difference is not a decompilation bug.
const fs = require("fs");

// --- the host -------------------------------------------------------------
//
// A module that imports memory, table or global cannot be instantiated without
// objects of the right shape, and `WebAssembly.Module.imports()` reports the
// kind but not the limits: a memory one page too small fails with a LinkError
// that has nothing to do with the decompiler. So the plan carries the limits
// (`moonlift verify` writes one `host` line per imported object) and this builds
// exactly those objects.
//
// A function import gets a stub that traps. That matches the generated package,
// where the stub traps too: neither side has a host for it, so a call through one
// is skipped by the comparison rather than counted as agreement.

function hostLinesOf(tsv) {
  if (!tsv) return [];
  return fs
    .readFileSync(tsv, "utf8")
    .split("\n")
    .filter((l) => l.startsWith("host\t"))
    .map((l) => l.split("\t").slice(1));
}

function hostFor(bytes, hostLines, overrides) {
  const mod = new WebAssembly.Module(bytes);
  const byKind = { memory: [], table: [], global: [], function: [] };
  for (const w of WebAssembly.Module.imports(mod)) {
    (byKind[w.kind] || (byKind[w.kind] = [])).push(w);
  }
  const imports = {};
  const put = (w, obj) => {
    if (!imports[w.module]) imports[w.module] = {};
    imports[w.module][w.name] = obj;
  };
  for (const w of byKind.function) {
    put(w, () => {
      throw new WebAssembly.RuntimeError("import " + w.module + "." + w.name + " has no host");
    });
  }
  const seen = { memory: 0, table: 0, global: 0 };
  for (const [kind, ty, min, max, mut] of hostLines) {
    const w = (byKind[kind] || [])[seen[kind]++];
    if (!w) continue;
    if (kind === "memory") {
      put(w, new WebAssembly.Memory({ initial: Number(min), maximum: Number(max) }));
    } else if (kind === "table") {
      put(
        w,
        new WebAssembly.Table({
          initial: Number(min),
          maximum: Number(max),
          element: "anyfunc",
        }),
      );
    } else {
      const key = w.module + "." + w.name;
      const given = overrides && Object.prototype.hasOwnProperty.call(overrides, key);
      const zero = ty === "i64" ? 0n : 0;
      put(
        w,
        new WebAssembly.Global(
          { value: ty, mutable: mut === "mutable" },
          given ? overrides[key] : zero,
        ),
      );
    }
  }
  return imports;
}

function bitsOf(v, type) {
  if (type === "f32") {
    const dv = new DataView(new ArrayBuffer(4));
    dv.setFloat32(0, v, true);
    return String(dv.getInt32(0, true));
  }
  const dv = new DataView(new ArrayBuffer(8));
  dv.setFloat64(0, v, true);
  return dv.getBigInt64(0, true).toString();
}

function render(v, type) {
  if (type === "i64") return typeof v === "bigint" ? v.toString() : String(v);
  if (type === "f32" || type === "f64") {
    if (Number.isNaN(v)) return null;
    return bitsOf(v, type);
  }
  return String(v);
}

async function human(file, spec, tsv, overrides) {
  const calls = JSON.parse(spec);
  const bytes = fs.readFileSync(file);
  const imports = hostFor(bytes, hostLinesOf(tsv), overrides ? JSON.parse(overrides) : null);
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  for (const [fn, args] of calls) {
    let out;
    try {
      out = instance.exports[fn](...args);
    } catch (e) {
      out = "trap:" + e.constructor.name;
    }
    console.log(fn + "(" + args.join(",") + ") = " + out);
  }
}

async function machine(file, tsv) {
  const raw = fs
    .readFileSync(tsv, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "");
  const lines = raw.filter((l) => !l.startsWith("init\t") && !l.startsWith("host\t"));
  let instance;
  try {
    const bytes = fs.readFileSync(file);
    const mod = await WebAssembly.instantiate(bytes, hostFor(bytes, hostLinesOf(tsv)));
    instance = mod.instance;
  } catch (e) {
    // A module with host imports cannot be instantiated without a host. The
    // harness reports that instead of pretending the calls passed.
    console.log("error\t-\t-\t" + String(e.message).replace(/[\t\n]/g, " "));
    return;
  }
  for (const line of lines) {
    const [name, wasmName, type, , jsArgs] = line.split("\t");
    const fn = instance.exports[wasmName];
    if (typeof fn !== "function") {
      console.log("error\t" + name + "\t" + type + "\tno export named " + wasmName);
      continue;
    }
    const args = jsArgs === "" ? [] : jsArgs.split(",").map(Number);
    let v;
    try {
      v = fn(...args);
    } catch (e) {
      // The message, not just the constructor: `script/indirect.sh` compares
      // *which* trap fired, and an indirect call has three distinct ones.
      const why =
        e && e.message
          ? String(e.message).replace(/[\t\n]/g, " ")
          : e && e.constructor
            ? e.constructor.name
            : "trap";
      console.log("trap\t" + name + "\t" + type + "\t" + why);
      continue;
    }
    const text = render(v, type);
    if (text === null) {
      console.log("nan\t" + name + "\t" + type + "\t-");
    } else {
      console.log("ok\t" + name + "\t" + type + "\t" + text);
    }
  }
}

(async () => {
  if (process.argv[2] === "--json") {
    await machine(process.argv[3], process.argv[4]);
  } else {
    await human(process.argv[2], process.argv[3], process.argv[4], process.argv[5]);
  }
})().catch((e) => {
  console.log("error\t-\t-\t" + String(e.message).replace(/[\t\n]/g, " "));
  process.exitCode = 1;
});

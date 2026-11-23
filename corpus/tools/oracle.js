// The reference engine, for comparison against the generated MoonBit package.
//
//   node oracle.js <file.wasm> '[["fn",[args]], ...]'
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

async function human(file, spec) {
  const calls = JSON.parse(spec);
  const { instance } = await WebAssembly.instantiate(fs.readFileSync(file), {});
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
  const lines = fs
    .readFileSync(tsv, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "" && !l.startsWith("init\t"));
  let instance;
  try {
    const mod = await WebAssembly.instantiate(fs.readFileSync(file), {});
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
    await human(process.argv[2], process.argv[3]);
  }
})().catch((e) => {
  console.log("error\t-\t-\t" + String(e.message).replace(/[\t\n]/g, " "));
  process.exitCode = 1;
});

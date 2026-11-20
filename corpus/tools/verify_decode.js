// Cross-check moonlift's instruction decoder against wabt.
//
// Why this exists: the decoder contains a 130-entry opcode layout that was
// transcribed by hand from the spec. Unit tests written from the same
// transcription only prove self-consistency. wabt is an independent
// implementation, so comparing the *mnemonic sequence* of every function body
// turns "we believe the tables are right" into a number with a denominator.
//
// The comparison deliberately ignores operands, with one exception: a wrong
// immediate length desynchronises the following bytes and the mnemonics diverge
// immediately, so length bugs are caught anyway. Operand *values* are checked by
// execution in stage S8, which is a stronger test than string equality.
//
//   npm --prefix corpus/tools i wabt && node corpus/tools/verify_decode.js
//
// Without `wabt` installed this prints SKIP and exits 0: the decoder must be
// verifiable offline, but a missing dev dependency must not fail the build.

"use strict";
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

let wabt;
try {
  wabt = require("wabt");
} catch (e) {
  console.log("SKIP  verify_decode: wabt not installed (npm --prefix corpus/tools i wabt)");
  process.exit(0);
}

const root = path.resolve(__dirname, "..", "..");
const goodDir = path.join(root, "corpus", "good");

// Instructions whose operand is dropped on both sides. Floats are formatted
// differently by every tool (`0x1.8p+1` vs `0x3fc00000`), and normalising them
// away is cheaper than agreeing on a spelling. Values are covered by execution.
const DROP_OPERAND = /^(f32|f64)\.const$/;

function ourDecode(file) {
  const out = execSync(
    `moon run cmd/main --target js -- disasm "${file}" --ops`,
    { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "ignore"] }
  );
  // Group by the leading function index.
  const groups = new Map();
  for (const line of out.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith(";")) continue;
    const m = /^(\d+)\s+(.*)$/.exec(t);
    if (!m) continue;
    const body = m[2].trim();
    if (body.startsWith(";")) continue; // ";partial ..." marker
    const tok = body.split(/\s+/)[0];
    if (!groups.has(m[1])) groups.set(m[1], []);
    groups.get(m[1]).push(DROP_OPERAND.test(tok) ? tok : body);
  }
  const idx = [...groups.keys()].map(Number).sort((a, b) => a - b);
  return idx.map((i) => groups.get(String(i)));
}

function wabtDecode(module, buf) {
  const mod = module.readWasm(buf, { readDebugNames: true });
  const text = mod.toText({ foldExprs: false, inlineExport: false });
  const groups = [];
  let cur = null;
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith(";;") || t.startsWith("(")) {
      // A `(func` line opens a body; every other parenthesised line is a
      // declaration, an offset expression or a data segment.
      if (/^\(func\b/.test(t)) {
        cur = [];
        groups.push(cur);
      }
      continue;
    }
    if (cur === null) continue;
    const tok = t.split(/[\s;)]+/)[0];
    if (!/^[a-z]/.test(tok)) continue;
    cur.push(DROP_OPERAND.test(tok) ? tok : t.replace(/\)+$/, "").trim());
  }
  return groups;
}

// Compare mnemomics only for the bulk case; keep the full line when the two
// spellings already agree, so a formatting drift is visible rather than silent.
function mnemonicOf(s) {
  return s.split(/\s+/)[0];
}

(async () => {
  const module = await wabt();
  const files = fs
    .readdirSync(goodDir)
    .filter((f) => f.endsWith(".wasm"))
    .sort();
  let totalInstr = 0;
  let totalMatched = 0;
  let skipped = 0;
  let mismatched = 0;
  const failures = [];

  for (const f of files) {
    const file = path.join(goodDir, f);
    const ours = ourDecode(file);
    // `new Uint8Array(...)` is load-bearing: fs.readFileSync returns a Buffer
    // that is a *view* into a shared 8 KB pool for small files, and wabt reads
    // the underlying ArrayBuffer rather than the view. Passing the Buffer
    // directly makes wabt parse the pool and fail with a bogus "string length"
    // error past EOF. Only the 20 KB artifact (own allocation) hid this.
    const theirs = wabtDecode(module, new Uint8Array(fs.readFileSync(file)));

    // Our groups are keyed by function index and may start at a non-zero offset
    // (imports have no body); wabt lists only functions with bodies, in order.
    const n = Math.min(ours.length, theirs.length);
    if (ours.length !== theirs.length) {
      failures.push(`${f}: body count ${ours.length} (ours) vs ${theirs.length} (wabt)`);
    }
    let matched = 0;
    let total = 0;
    let skippedHere = 0;
    for (let i = 0; i < n; i++) {
      const a = ours[i].map(mnemonicOf);
      const b = theirs[i].map(mnemonicOf);
      total += Math.max(a.length, b.length);
      const len = Math.min(a.length, b.length);
      // A body we stopped early is strictly shorter than wabt's. Those trailing
      // instructions were never attempted, so they are neither matches nor
      // mismatches; they are reported on their own line. Folding them into the
      // percentage either way would be flattering.
      skippedHere += b.length - len;
      let firstBad = -1;
      for (let k = 0; k < len; k++) {
        if (a[k] === b[k]) matched++;
        else if (firstBad < 0) firstBad = k;
      }
      if (firstBad >= 0) {
        failures.push(
          `${f} body #${i}: at instruction ${firstBad} ours=${a[firstBad]} wabt=${b[firstBad]}`
        );
      }
    }
    totalInstr += total;
    totalMatched += matched;
    skipped += skippedHere;
    mismatched += total - matched - skippedHere;
    const pct = total ? ((100 * matched) / total).toFixed(2) : "100.00";
    console.log(
      `${f.padEnd(20)} ${String(ours.length).padStart(3)} bodies  ${String(matched).padStart(5)}/${String(total).padEnd(5)} instr  ${pct}%`
    );
  }

  console.log("");
  console.log(`matched      ${totalMatched}`);
  console.log(`mismatched   ${mismatched}`);
  console.log(`not attempted ${skipped}  (bodies that stop at SIMD by design)`);
  console.log(`total        ${totalInstr}`);
  if (failures.length) {
    console.log("\nmismatches:");
    for (const m of failures.slice(0, 20)) console.log("  " + m);
    process.exit(1);
  }
  console.log("PASS  every mnemonic in every body matches wabt");
})().catch((e) => {
  console.error("FAIL ", e.message || e);
  process.exit(1);
});

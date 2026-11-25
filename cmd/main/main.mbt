///|
/// `moonlift` command line entry point.
///
/// Design rule: the CLI is a *thin* shell. Every subcommand parses arguments,
/// calls exactly one library entry point, and formats the result. No decoding
/// logic lives here — that keeps the library usable from tests and from other
/// tools without spawning a process.
///
/// Exit codes (documented in README):
///   0 success, 2 usage error, 3 input rejected (E0xx/E1xx), 4 input unreadable
const EXIT_OK : Int32 = 0

///|
const EXIT_USAGE : Int32 = 2

///|
const EXIT_REJECTED : Int32 = 3

///|
const EXIT_UNREADABLE : Int32 = 4

///|
fn usage_text() -> String {
  let b = StringBuilder()
  b.write_string(@core.banner())
  b.write_string(
    "\n\nUsage:\n  moonlift <command> [options]\n\nCommands:\n  info <file.wasm>              print module structure\n  disasm <file.wasm> [--ops|--stats|--cfg|--stack|--struct]\n                                print the decoded listing, or the control-flow graph\n  decompile <file.wasm>... -o <dir>\n                                emit MoonBit sources into <dir>; several files\n                                become one package, sharing one Memory\n  verify <file.wasm> [-n N]     differential test against a reference engine\n  help                          show this text\n  version                       print version\n\nExit codes: 0 ok, 2 usage, 3 input rejected, 4 input unreadable.\n",
  )
  b.to_string()
}

///|
/// True when a token is almost certainly the host's program path rather than a
/// user argument: it contains a path separator, or ends in an executable
/// extension. Used only as a fallback heuristic — see `normalize_args`.
fn looks_like_program_path(t : String) -> Bool {
  t.contains("/") ||
  t.contains("\\") ||
  t.has_suffix(".js") ||
  t.has_suffix(".mjs") ||
  t.has_suffix(".wasm") ||
  t.has_suffix(".exe")
}

///|
/// Copy the tail of an argument vector into a fresh array.
fn tail_from(argv : Array[String], from : Int32) -> Array[String] {
  let out : Array[String] = []
  let mut i = from
  while i < argv.length() {
    out.push(argv[i])
    i = i + 1
  }
  out
}

///|
/// Strip the tokens the host injected in front of the user's arguments.
///
/// Measured, not assumed: the same command produces different vectors on the
/// three backends we run on.
///
///   wasm-gc   [ program, subcommand, args... ]
///   wasm      [ program, subcommand, args... ]
///   js        [ node, main.js, subcommand, args... ]
///
/// So instead of hard-coding "drop one", the first token that *is* a known
/// subcommand marks the start of the real arguments. When the subcommand is not
/// recognised, fall back to dropping leading tokens that look like program
/// paths, which is what makes `moonlift frobnicate` still report `frobnicate`
/// and not `node`.
fn normalize_args(argv : Array[String]) -> Array[String] {
  let known = [
    "info", "disasm", "decompile", "verify", "help", "--help", "-h", "version", "--version",
  ]
  let mut i = 0
  while i < argv.length() && !known.contains(argv[i]) {
    i = i + 1
  }
  if i < argv.length() {
    return tail_from(argv, i)
  }
  let mut j = 0
  while j < argv.length() && looks_like_program_path(argv[j]) {
    j = j + 1
  }
  tail_from(argv, j)
}

///|
/// Read a file, turning the platform's exception into `None`.
///
/// The IO failure is not a `Diag`: a missing file is not a malformed module, and
/// mixing the two would let `E0xx` codes mean "your wasm is broken" in one place
/// and "your path is broken" in another.
fn read_input(path : String) -> Bytes? {
  Some(@fs.read_file_to_bytes(path)) catch {
    _ => None
  }
}

///|
/// `info <file>`: decode and describe. Never modifies anything.
fn run_info(args : Array[String]) -> Int32 {
  if args.length() < 2 {
    println("moonlift: 'info' needs a path to a .wasm file")
    return EXIT_USAGE
  }
  let path = args[1]
  match read_input(path) {
    None => {
      println("moonlift: cannot read '\{path}'")
      EXIT_UNREADABLE
    }
    Some(data) =>
      match @core.decode_bytes(data) {
        Ok(m) => {
          println(@core.report(m, path))
          EXIT_OK
        }
        Err(d) => {
          println("moonlift: rejected '\{path}'")
          println("  \{d.render_verbose()}")
          EXIT_REJECTED
        }
      }
  }
}

///|
/// `disasm <file> [--ops|--stats|--cfg|--stack|--struct|--struct-stats]`: decode
/// every function body and print it.
///
/// Unlike `info`, this can fail on a body the decoder rejects, and that is the
/// point: `info` answers "what is in this file", `disasm` answers "what does the
/// decoder understand", so a rejection has to surface as a rejection.
fn run_disasm(args : Array[String]) -> Int32 {
  if args.length() < 2 {
    println("moonlift: 'disasm' needs a path to a .wasm file")
    return EXIT_USAGE
  }
  let path = args[1]
  // 0 listing, 1 ops, 2 stats, 3 control-flow graph, 4 typed stack, 5
  // structured tree, 6 structuring statistics. Last flag wins, so `--stats
  // --cfg` is the same as `--cfg` rather than an error: a reviewer pasting flags
  // should not have to think about ordering.
  let mut mode = 0
  let mut i = 2
  while i < args.length() {
    if args[i] == "--ops" {
      mode = 1
    } else if args[i] == "--stats" {
      mode = 2
    } else if args[i] == "--cfg" {
      mode = 3
    } else if args[i] == "--stack" {
      mode = 4
    } else if args[i] == "--struct" {
      mode = 5
    } else if args[i] == "--struct-stats" {
      mode = 6
    }
    i = i + 1
  }
  match read_input(path) {
    None => {
      println("moonlift: cannot read '\{path}'")
      EXIT_UNREADABLE
    }
    Some(data) =>
      match @core.decode_bytes(data) {
        Err(d) => {
          println("moonlift: rejected '\{path}'")
          println("  \{d.render_verbose()}")
          EXIT_REJECTED
        }
        Ok(m) => {
          let out = if mode == 1 {
            @core.disasm_ops_text(m)
          } else if mode == 2 {
            @core.disasm_stats_text(m)
          } else if mode == 3 {
            @core.cfg_text_result(m, path)
          } else if mode == 4 {
            @core.stack_text_result(m, path)
          } else if mode == 5 {
            @core.tree_text_result(m, path)
          } else if mode == 6 {
            @core.struct_summary_text(m)
          } else {
            @core.disasm_text(m, path)
          }
          match out {
            Ok(text) => {
              println(text)
              EXIT_OK
            }
            Err(d) => {
              // `--stack` adds type checking to the decode, so "cannot decode"
              // would understate what failed.
              let what = if mode == 4 { "type-check" } else { "decode" }
              println("moonlift: cannot \{what} the code section of '\{path}'")
              println("  \{d.render_verbose()}")
              EXIT_REJECTED
            }
          }
        }
      }
  }
}

///|
/// The runtime source that is copied into every generated package, printing where
/// it looked when it cannot be found.
///
/// The decompiler has to *read* it because the alternative is embedding it: a
/// file that lives in this repository is compiled by this repository's gate on
/// every run, and one embedded in a string literal is compiled only when someone
/// generates a package. The search is relative to the working directory, which is
/// the repository root in every documented invocation.
fn find_runtime(explicit : String?) -> String? {
  let candidates : Array[String] = []
  match explicit {
    Some(p) => candidates.push(p)
    None => ()
  }
  candidates.push("runtime/runtime.mbt")
  candidates.push("../runtime/runtime.mbt")
  candidates.push("../../runtime/runtime.mbt")
  let mut found : String? = None
  for c in candidates {
    if found is None && @fs.path_exists(c) {
      found = Some(c)
    }
  }
  found
}

///|
/// `decompile <file> -o <dir> [--runtime <path>]`: write a MoonBit package.
///
/// The package is meant to be checked and then edited: nothing here writes a file
/// that a later run will not overwrite, so the output directory is the user's
/// once it exists.
fn run_decompile(args : Array[String]) -> Int32 {
  let inputs : Array[String] = []
  let mut out_dir = ""
  let mut runtime : String? = None
  let mut i = 1
  while i < args.length() {
    if args[i] == "-o" && i + 1 < args.length() {
      out_dir = args[i + 1]
      i = i + 2
    } else if args[i] == "--runtime" && i + 1 < args.length() {
      runtime = Some(args[i + 1])
      i = i + 2
    } else if args[i] == "-o" || args[i] == "--runtime" {
      // A flag with no value is a usage error, reported by the checks below.
      i = i + 1
    } else {
      inputs.push(args[i])
      i = i + 1
    }
  }
  if inputs.length() == 0 {
    println("moonlift: 'decompile' needs a path to a .wasm file")
    return EXIT_USAGE
  }
  if out_dir == "" {
    println("moonlift: 'decompile' needs an output directory (-o <dir>)")
    return EXIT_USAGE
  }
  if inputs.length() == 1 {
    match write_package(inputs[0], out_dir, runtime) {
      None => EXIT_UNREADABLE
      Some((report, _)) => {
        println(@core.gen_summary_text(report, inputs[0], out_dir))
        EXIT_OK
      }
    }
  } else {
    match write_package_multi(inputs, out_dir, runtime) {
      None => EXIT_UNREADABLE
      Some(report) => {
        println(@core.gen_summary_multi_text(report, inputs, out_dir))
        EXIT_OK
      }
    }
  }
}

///|
/// `verify` writes the same package as `decompile`, plus `calls.tsv`: the list of
/// calls `script/verify.sh` should make against both the original module and the
/// generated one. The comparison itself runs outside MoonBit, because the tool
/// has no way to execute a wasm module (or to start Node) from inside a
/// `wasm-gc` or `js` process — and the whole point is to compare against an
/// implementation that is not this one.
fn run_verify(args : Array[String]) -> Int32 {
  if args.length() < 2 {
    println("moonlift: 'verify' needs a path to a .wasm file")
    return EXIT_USAGE
  }
  let path = args[1]
  let mut out_dir = ""
  let mut runtime : String? = None
  let mut per_func = 16
  let mut small = false
  let mut i = 2
  while i < args.length() {
    if args[i] == "-o" && i + 1 < args.length() {
      out_dir = args[i + 1]
      i = i + 1
    } else if args[i] == "--runtime" && i + 1 < args.length() {
      runtime = Some(args[i + 1])
      i = i + 1
    } else if args[i] == "--small" {
      small = true
    } else if args[i] == "-n" && i + 1 < args.length() {
      per_func = match parse_count(args[i + 1]) {
        Some(n) => n
        None => per_func
      }
      i = i + 1
    }
    i = i + 1
  }
  if out_dir == "" {
    println("moonlift: 'verify' needs an output directory (-o <dir>)")
    return EXIT_USAGE
  }
  match write_package(path, out_dir, runtime) {
    None => EXIT_UNREADABLE
    Some((report, m)) => {
      let plan = @core.plan_calls(m, report.emitted, per_func, small)
      write_text(out_dir + "/calls.tsv", @core.plan_text(plan))
      println(@core.plan_summary_text(plan, path, out_dir))
      println(@core.gen_summary_text(report, path, out_dir))
      EXIT_OK
    }
  }
}

///|
/// A non-negative decimal integer, or `None`.
///
/// `-n` takes a call count, so this is deliberately narrower than a general
/// number parser: digits only, no sign, no exponent. Anything else keeps the
/// default rather than failing the command.
fn parse_count(s : String) -> Int32? {
  if s.length() == 0 {
    return None
  }
  let mut n = 0
  let mut ok = true
  for c in s {
    if c >= '0' && c <= '9' {
      n = n * 10 + (c.to_int() - 48)
    } else {
      ok = false
    }
  }
  if ok {
    Some(n)
  } else {
    None
  }
}

///|
/// Decode, generate and write. The two commands that produce a package differ
/// only in what they do with the report, so the writing lives here once.
fn write_package(
  path : String,
  out_dir : String,
  runtime : String?,
) -> (@core.GenReport, @core.Module)? {
  let runtime_path = match find_runtime(runtime) {
    Some(p) => p
    None => {
      println("moonlift: cannot find runtime/runtime.mbt")
      println(
        "  run from the repository root, or pass --runtime <path-to-runtime.mbt>",
      )
      return None
    }
  }
  let data = match read_input(path) {
    None => {
      println("moonlift: cannot read '\{path}'")
      return None
    }
    Some(d) => d
  }
  let m = match @core.decode_bytes(data) {
    Err(d) => {
      println("moonlift: rejected '\{path}'")
      println("  \{d.render_verbose()}")
      return None
    }
    Ok(m) => m
  }
  let runtime_src = match read_text(runtime_path) {
    Some(t) => t
    None => {
      println("moonlift: cannot read '\{runtime_path}'")
      return None
    }
  }
  let report = @core.emit_package(m)
  if !@fs.path_exists(out_dir) {
    match
      (@fs.create_dir(out_dir) catch {
        _ => {
          println("moonlift: cannot create '\{out_dir}'")
          return None
        }
      }) {
      _ => ()
    }
  }
  for f in report.files {
    write_text(out_dir + "/" + f.name, f.text)
  }
  write_text(out_dir + "/runtime.mbt", runtime_src)
  Some((report, m))
}

///|
/// `decompile a.wasm b.wasm -o <dir>`: one package, both modules.
///
/// This is the only way to give two modules one `Memory`: each generated package
/// carries its own `runtime.mbt`, so `pkg_a.Memory` and `pkg_b.Memory` are
/// different types and no host can pass the same instance to both. In one
/// package there is one type, one `Memory`, and `memory.grow` in the first
/// module is visible through `memory.size` in the second.
fn write_package_multi(
  paths : Array[String],
  out_dir : String,
  runtime : String?,
) -> @core.MultiReport? {
  let runtime_path = match find_runtime(runtime) {
    Some(p) => p
    None => {
      println("moonlift: cannot find runtime/runtime.mbt")
      println(
        "  run from the repository root, or pass --runtime <path-to-runtime.mbt>",
      )
      return None
    }
  }
  let runtime_src = match read_text(runtime_path) {
    Some(t) => t
    None => {
      println("moonlift: cannot read '\{runtime_path}'")
      return None
    }
  }
  let mods : Array[@core.Module] = []
  for path in paths {
    let data = match read_input(path) {
      None => {
        println("moonlift: cannot read '\{path}'")
        return None
      }
      Some(d) => d
    }
    match @core.decode_bytes(data) {
      Err(d) => {
        println("moonlift: rejected '\{path}'")
        println("  \{d.render_verbose()}")
        return None
      }
      Ok(m) => mods.push(m)
    }
  }
  let report = @core.emit_package_multi(mods)
  if !@fs.path_exists(out_dir) {
    match
      (@fs.create_dir(out_dir) catch {
        _ => {
          println("moonlift: cannot create '\{out_dir}'")
          return None
        }
      }) {
      _ => ()
    }
  }
  for f in report.files {
    write_text(out_dir + "/" + f.name, f.text)
  }
  write_text(out_dir + "/runtime.mbt", runtime_src)
  Some(report)
}

///|
fn read_text(path : String) -> String? {
  Some(@fs.read_file_to_string(path)) catch {
    _ => None
  }
}

///|
fn write_text(path : String, text : String) -> Unit {
  @fs.write_string_to_file(path, text) catch {
    _ => ()
  }
}

///|
/// Command dispatcher. Returns the process exit code; `main` only prints it.
fn run(args : Array[String]) -> Int32 {
  if args.length() == 0 {
    println(usage_text())
    return EXIT_USAGE
  }
  let cmd = args[0]
  match cmd {
    "help" | "--help" | "-h" => {
      println(usage_text())
      EXIT_OK
    }
    "version" | "--version" => {
      println(@core.banner())
      EXIT_OK
    }
    "info" => run_info(args)
    "disasm" => run_disasm(args)
    "decompile" => run_decompile(args)
    "verify" => run_verify(args)
    _ => {
      println("moonlift: unknown command '\{cmd}'")
      println(usage_text())
      EXIT_USAGE
    }
  }
}

///|
fn main {
  let args = normalize_args(@env.args())
  let code = run(args)
  // MoonBit has no portable `exit()` today, so the code is echoed on stdout and
  // the demo script greps for it. Documented in BOUNDARY.md.
  if code != EXIT_OK {
    println("moonlift: exit \{code}")
  }
}

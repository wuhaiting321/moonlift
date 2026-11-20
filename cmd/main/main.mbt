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
    "\n\nUsage:\n  moonlift <command> [options]\n\nCommands:\n  info <file.wasm>              print module structure\n  disasm <file.wasm> [--ops|--stats|--cfg|--stack|--struct]\n                                print the decoded listing, or the control-flow graph\n  decompile <file.wasm> -o <dir> emit MoonBit sources into <dir>\n  verify <file.wasm> [-n N]     differential test against a reference engine\n  help                          show this text\n  version                       print version\n\nExit codes: 0 ok, 2 usage, 3 input rejected, 4 input unreadable.\n",
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
  if args.length() < 2 {
    println("moonlift: 'decompile' needs a path to a .wasm file")
    return EXIT_USAGE
  }
  let path = args[1]
  let mut out_dir = ""
  let mut runtime : String? = None
  let mut i = 2
  while i < args.length() {
    if args[i] == "-o" && i + 1 < args.length() {
      out_dir = args[i + 1]
      i = i + 1
    } else if args[i] == "--runtime" && i + 1 < args.length() {
      runtime = Some(args[i + 1])
      i = i + 1
    }
    i = i + 1
  }
  if out_dir == "" {
    println("moonlift: 'decompile' needs an output directory (-o <dir>)")
    return EXIT_USAGE
  }
  let runtime_path = match find_runtime(runtime) {
    Some(p) => p
    None => {
      println("moonlift: cannot find runtime/runtime.mbt")
      println(
        "  run from the repository root, or pass --runtime <path-to-runtime.mbt>",
      )
      return EXIT_UNREADABLE
    }
  }
  let data = match read_input(path) {
    None => {
      println("moonlift: cannot read '\{path}'")
      return EXIT_UNREADABLE
    }
    Some(d) => d
  }
  let m = match @core.decode_bytes(data) {
    Err(d) => {
      println("moonlift: rejected '\{path}'")
      println("  \{d.render_verbose()}")
      return EXIT_REJECTED
    }
    Ok(m) => m
  }
  let runtime_src = match read_text(runtime_path) {
    Some(t) => t
    None => {
      println("moonlift: cannot read '\{runtime_path}'")
      return EXIT_UNREADABLE
    }
  }
  let report = @core.emit_package(m)
  if !@fs.path_exists(out_dir) {
    match
      (@fs.create_dir(out_dir) catch {
        _ => {
          println("moonlift: cannot create '\{out_dir}'")
          return EXIT_UNREADABLE
        }
      }) {
      _ => ()
    }
  }
  let names : Array[String] = []
  for f in report.files {
    names.push(f.name)
    write_text(out_dir + "/" + f.name, f.text)
  }
  write_text(out_dir + "/runtime.mbt", runtime_src)
  names.push("runtime.mbt")
  let _ = names
  println(@core.gen_summary_text(report, path, out_dir))
  EXIT_OK
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
    "verify" => {
      println("moonlift: 'verify' is not implemented yet (planned stage S8)")
      EXIT_USAGE
    }
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

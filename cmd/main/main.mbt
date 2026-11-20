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
    "\n\nUsage:\n  moonlift <command> [options]\n\nCommands:\n  info <file.wasm>              print module structure\n  disasm <file.wasm> [--ops|--stats|--cfg]\n                                print the decoded listing, or the control-flow graph\n  decompile <file.wasm> -o <dir> emit MoonBit sources into <dir>\n  verify <file.wasm> [-n N]     differential test against a reference engine\n  help                          show this text\n  version                       print version\n\nExit codes: 0 ok, 2 usage, 3 input rejected, 4 input unreadable.\n",
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
/// `disasm <file> [--ops|--stats|--cfg]`: decode every function body and print
/// it.
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
  // 0 listing, 1 ops, 2 stats, 3 control-flow graph. Last flag wins, so
  // `--stats --cfg` is the same as `--cfg` rather than an error: a reviewer
  // pasting flags should not have to think about ordering.
  let mut mode = 0
  let mut i = 2
  while i < args.length() {
    if args[i] == "--ops" {
      mode = 1
    } else if args[i] == "--stats" {
      mode = 2
    } else if args[i] == "--cfg" {
      mode = 3
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
          } else {
            @core.disasm_text(m, path)
          }
          match out {
            Ok(text) => {
              println(text)
              EXIT_OK
            }
            Err(d) => {
              println("moonlift: cannot decode the code section of '\{path}'")
              println("  \{d.render_verbose()}")
              EXIT_REJECTED
            }
          }
        }
      }
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
    "decompile" | "verify" => {
      println(
        "moonlift: '\{cmd}' is not implemented yet (planned stage S7 / S8)",
      )
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

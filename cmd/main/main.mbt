///|
/// `moonlift` command line entry point.
///
/// Design rule: the CLI is a *thin* shell. Every subcommand parses arguments,
/// calls exactly one library entry point, and formats the result. No decoding
/// logic lives here — that keeps the library usable from tests and from other
/// tools without spawning a process.
///
/// Exit codes (documented in README):
///   0 success, 2 usage error, 3 input rejected (E0xx/E1xx), 1 internal error
const EXIT_OK : Int32 = 0

///|
const EXIT_USAGE : Int32 = 2

///|
fn usage_text() -> String {
  let b = StringBuilder()
  b.write_string(@core.banner())
  b.write_string(
    "\n\nUsage:\n  moonlift <command> [options]\n\nCommands:\n  info <file.wasm>              print module structure\n  decompile <file.wasm> -o <dir> emit MoonBit sources into <dir>\n  verify <file.wasm> [-n N]     differential test against a reference engine\n  help                          show this text\n  version                       print version\n\nStatus: scaffold only (stage S0). Only help/version are wired.\n",
  )
  b.to_string()
}

///|
/// Drop argv[0] when it is a program path rather than a subcommand.
///
/// WASI, Node and the test harness disagree about whether argv[0] is the
/// executable, so the dispatcher sniffs the first token instead of trusting
/// the host. This is the only host-dependent logic in the CLI.
fn normalize_args(argv : Array[String]) -> Array[String] {
  let known = [
    "info", "decompile", "verify", "help", "--help", "-h", "version", "--version",
  ]
  if argv.length() == 0 || known.contains(argv[0]) {
    return argv
  }
  let rest : Array[String] = []
  let mut i = 1
  while i < argv.length() {
    rest.push(argv[i])
    i = i + 1
  }
  rest
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
    "info" | "decompile" | "verify" => {
      println(
        "moonlift: '\{cmd}' is not implemented yet (planned stage S2/S7/S8)",
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
  // MoonBit has no portable `exit()` today, so the code is echoed on stderr-free
  // stdout and the demo script greps for it. Documented in BOUNDARY.md.
  if code != EXIT_OK {
    println("moonlift: exit \{code}")
  }
}

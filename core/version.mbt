///|
/// Semantic version of moonlift. Kept in sync with `moon.mod` by hand; the
/// release checklist (S11) greps both values and fails if they diverge.
pub const VERSION : String = "0.1.0"

///|
/// One-line project identity used by `--version` and by the demo script header.
pub fn banner() -> String {
  "moonlift \{VERSION} — WebAssembly (MVP) to MoonBit decompiler"
}

///|
/// One imported function.
///
/// A function import is the only import kind that needs a name of its own: the
/// other three are described exactly like their defined counterparts, so they go
/// into `tables`, `memories` and `globals` at the front of those arrays — the
/// same order the binary format puts them in, and the same order the index space
/// uses. `Module::imported_table_count` and friends say where the boundary is.
pub struct ImportedFunc {
  /// Module string as written by the producer, e.g. `wasi_snapshot_preview1`.
  module_name : String
  /// Field string, e.g. `fd_write`.
  field_name : String
  /// Index into the module's type table.
  type_idx : Int32
}

///|
/// A table. The element type is fixed to `funcref`: that is the only element
/// type the MVP allows, and the decoder never stores anything else.
pub struct Table {
  limits : Limits
}

///|
/// A linear memory. `Limits.min` and `.max` are expressed in 64 KiB pages, as
/// in the binary format; conversion to bytes happens at the point of use.
pub struct Memory {
  limits : Limits
}

///|
/// A global variable with its constant initialiser.
///
/// An imported global has no initialiser in the binary: the host supplies the
/// value. `init` is then the zero of `ty` and `imported` is true, so the emitter
/// knows to make it a host-settable cell rather than a copy of a constant.
pub struct Global {
  ty : ValType
  mutable : Bool
  init : ConstExpr
  imported : Bool
}

///|
/// One entry of the export section.
pub struct Export {
  name : String
  kind : ExternalKind
  index : Int32
}

///|
/// One run of identical local declarations. The binary format stores locals as
/// `(count, type)` pairs precisely so that a function with 500 zeroed i32
/// locals costs three bytes instead of a thousand; the IR keeps that shape
/// because the code generator wants to emit `let a : Int` lines, not a flat
/// list with duplicates.
pub struct LocalDecl {
  count : UInt32
  ty : ValType
}

///|
/// A function body: local declarations plus the raw instruction bytes.
///
/// The instruction stream is kept as bytes and decoded in stage S3. That split
/// is deliberate: section-level structure can be validated and reported without
/// understanding a single opcode, so `info` works on inputs the decompiler will
/// later refuse.
pub struct Code {
  locals : Array[LocalDecl]
  /// Sum of `locals[i].count`, precomputed because every consumer wants it.
  local_count : Int32
  body : Bytes
  /// Absolute offset of the first instruction byte, for diagnostics.
  body_offset : Int32
}

///|
/// An active element segment: initialises `table[offset ..]` with `funcs`.
pub struct Elem {
  offset : ConstExpr
  funcs : Array[Int32]
}

///|
/// An active data segment: copies `bytes` into memory at `offset`.
pub struct Data {
  offset : ConstExpr
  bytes : Bytes
  /// Absolute offset of the segment's first byte in the input file.
  offset_pos : Int32
}

///|
/// A custom section, kept only as metadata. Its payload is not interpreted
/// except for the `name` section, which is parsed on a best-effort basis.
pub struct Custom {
  name : String
  size : Int32
}

///|
/// Layout record for `info`: where each section starts and how big it is.
pub struct SectionRef {
  id : Byte
  /// Offset of the section id byte, i.e. the start of the section header.
  offset : Int32
  /// Payload size as declared in the header (excludes id and size fields).
  size : Int32
}

///|
/// A name from the `name` custom section.
pub struct FuncName {
  index : Int32
  name : String
}

///|
/// The decoded module.
///
/// Everything is a plain array in section order. No maps, no lazy fields: the
/// whole point of stage S2 is that a module can be printed, counted and
/// validated without any further decoding, and arrays keep that deterministic.
pub struct Module {
  /// Size of the input file in bytes.
  size : Int32
  types : Array[FuncType]
  imports : Array[ImportedFunc]
  /// Type index for each *defined* function, in code-section order.
  func_types : Array[Int32]
  tables : Array[Table]
  memories : Array[Memory]
  globals : Array[Global]
  /// How many entries at the front of `tables`, `memories` and `globals` came
  /// from the import section. Those arrays are the index spaces the binary
  /// format defines — imports first, definitions after — so a `global.get 2`
  /// needs no translation, and only code that must know *which* half a slot
  /// belongs to has to consult these.
  imported_tables : Int32
  imported_memories : Int32
  imported_globals : Int32
  exports : Array[Export]
  elems : Array[Elem]
  codes : Array[Code]
  datas : Array[Data]
  customs : Array[Custom]
  sections : Array[SectionRef]
  func_names : Array[FuncName]
  start_func : Int32
  has_start : Bool
  /// Value of the data-count section (bulk memory), or 0 when absent.
  data_count : Int32
  has_data_count : Bool
}

///|
pub fn Module::size(self : Module) -> Int32 {
  self.size
}

///|
pub fn Module::imported_func_count(self : Module) -> Int32 {
  self.imports.length()
}

///|
pub fn Module::defined_func_count(self : Module) -> Int32 {
  self.func_types.length()
}

///|
/// Total number of functions callable by index: imports come first, defined
/// functions follow, exactly as in the wasm function index space.
pub fn Module::func_count(self : Module) -> Int32 {
  self.imports.length() + self.func_types.length()
}

///|
/// Signature of the function at `idx` in the unified function index space.
/// `None` when the index is out of range or points at a missing type.
pub fn Module::func_type(self : Module, idx : Int32) -> FuncType? {
  let i = idx
  if i < 0 || i >= self.func_count() {
    return None
  }
  let type_idx = if i < self.imports.length() {
    self.imports[i].type_idx
  } else {
    self.func_types[i - self.imports.length()]
  }
  let t = type_idx
  if t < 0 || t >= self.types.length() {
    None
  } else {
    Some(self.types[t])
  }
}

///|
/// Human label for a function index: `env.fd_write` for imports, the name from
/// the `name` section when present, `$f12` otherwise.
pub fn Module::func_label(self : Module, idx : Int32) -> String {
  let i = idx
  if i >= 0 && i < self.imports.length() {
    let im = self.imports[i]
    return "\{im.module_name}.\{im.field_name}"
  }
  for n in self.func_names {
    if n.index == idx {
      return n.name
    }
  }
  "$f\{idx}"
}

///|
/// Body of a defined function, or `None` for imports and out-of-range indices.
pub fn Module::code_of(self : Module, idx : Int32) -> Code? {
  let i = idx - self.imports.length()
  if i < 0 || i >= self.codes.length() {
    None
  } else {
    Some(self.codes[i])
  }
}

///|
/// Count exports of one kind. Used by the summary line.
pub fn Module::export_count(self : Module, kind : ExternalKind) -> Int32 {
  let mut n = 0
  for e in self.exports {
    if e.kind.slot() == kind.slot() {
      n = n + 1
    }
  }
  n
}

///|
/// Total size of all function bodies, in bytes.
pub fn Module::code_bytes(self : Module) -> Int32 {
  let mut n = 0
  for c in self.codes {
    n = n + c.body.length()
  }
  n
}

///|
/// Largest local count of any defined function. Multi-value and large local
/// counts are the two things a code generator must budget for, so both are
/// surfaced by `info` instead of being discovered at generation time.
pub fn Module::max_local_count(self : Module) -> Int32 {
  let mut m : Int32 = 0
  for c in self.codes {
    if c.local_count > m {
      m = c.local_count
    }
  }
  m
}

///|
/// Number of defined functions whose signature needs the multi-value proposal.
pub fn Module::multi_value_func_count(self : Module) -> Int32 {
  let mut n = 0
  for t in self.types {
    if t.is_multi_value() {
      n = n + 1
    }
  }
  n
}

///|
/// Number of signatures that use a type the code generator cannot emit.
pub fn Module::unsupported_type_func_count(self : Module) -> Int32 {
  let mut n = 0
  for t in self.types {
    if t.has_unsupported_type() {
      n = n + 1
    }
  }
  n
}

///|
/// Number of function bodies that declare at least one local of a type the code
/// generator cannot emit. MoonBit's own wasm output hits this: its memcpy helper
/// keeps a `v128` local even though no signature mentions SIMD.
pub fn Module::unsupported_local_func_count(self : Module) -> Int32 {
  let mut n = 0
  for c in self.codes {
    let mut bad = false
    for l in c.locals {
      if !l.ty.is_generatable() {
        bad = true
      }
    }
    if bad {
      n = n + 1
    }
  }
  n
}

///|
/// Total payload bytes of all data segments. This is the static footprint that
/// a decompiled program has to reproduce with string/array literals.
pub fn Module::data_bytes(self : Module) -> Int32 {
  let mut n = 0
  for d in self.datas {
    n = n + d.bytes.length()
  }
  n
}

///|
/// True when any function body exists, i.e. the module is not import-only.
pub fn Module::has_code(self : Module) -> Bool {
  self.codes.length() > 0
}

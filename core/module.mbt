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
///
/// `module_name` and `field_name` are filled in only when the table came from
/// the import section: they are the identity the host resolves, and two imports
/// with the same pair must end up as one instance. A declared table leaves both
/// empty.
pub struct Table {
  limits : Limits
  module_name : String
  field_name : String
}

///|
/// A linear memory. `Limits.min` and `.max` are expressed in 64 KiB pages, as
/// in the binary format; conversion to bytes happens at the point of use.
/// The two name fields follow the same rule as `Table`.
pub struct Memory {
  limits : Limits
  module_name : String
  field_name : String
}

///|
/// A global variable with its constant initialiser.
///
/// An imported global has no initialiser in the binary: the host supplies the
/// value. `init` is then the zero of `ty` and `imported` is true, so the emitter
/// knows the cell belongs to the host. `module_name` / `field_name` say *which*
/// host object: two imports naming the same pair are the same cell, and the
/// emitter must spell them as one.
pub struct Global {
  ty : ValType
  mutable : Bool
  init : ConstExpr
  imported : Bool
  module_name : String
  field_name : String
}

///|
/// One distinct `(module, name, kind)` triple a module imports state through.
///
/// The import *section* may name the same thing more than once — a module can
/// import `env.counter` as two separate global indices — and WebAssembly says
/// both resolve to one external value. The emitters and the plan both need the
/// de-duplicated list, so it is built once, here, rather than in each of them.
pub struct ImportSlot {
  /// `"memory"`, `"table"` or `"global"`.
  kind : String
  /// Type of the extern: the global's type, or `funcref` for a table.
  ty : ValType
  mutable : Bool
  /// Declared minimum, in pages for a memory and slots for a table.
  min : Int32
  max : Int32
  module_name : String
  field_name : String
  /// Identifier used for this slot in the generated `MoonliftExterns` struct.
  /// Unique within the module, so two globals cannot share a field by accident.
  field : String
}

///|
/// Identifiers for generated struct fields: lower-case, `[a-z0-9_]` only, never
/// starting with a digit. Two different import names may land on the same
/// string ("a-b" and "a.b"); `import_slots` disambiguates with a suffix.
fn slot_ident(part : String) -> String {
  let b = StringBuilder()
  for ch in part {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9')
    b.write_char(if ok { ch } else { '_' })
  }
  let s = b.to_string()
  if s == "" {
    "x"
  } else {
    s
  }
}

///|
/// The distinct state imports of a module, in index order: tables, then
/// memories, then globals. Function imports are not here — a function has no
/// object to alias, and the generated module exposes them as stubs for the host
/// to replace.
pub fn import_slots(m : Module) -> Array[ImportSlot] {
  let out : Array[ImportSlot] = []
  let mut t = 0
  while t < m.imported_tables {
    let tab = m.tables[t]
    out.push({
      kind: "table",
      ty: V128,
      mutable: false,
      min: tab.limits.min.reinterpret_as_int(),
      max: if tab.limits.has_max {
        tab.limits.max.reinterpret_as_int()
      } else {
        65536
      },
      module_name: tab.module_name,
      field_name: tab.field_name,
      field: "",
    })
    t = t + 1
  }
  let mut i = 0
  while i < m.imported_memories {
    let mem = m.memories[i]
    out.push({
      kind: "memory",
      ty: V128,
      mutable: false,
      min: mem.limits.min.reinterpret_as_int(),
      max: if mem.limits.has_max {
        mem.limits.max.reinterpret_as_int()
      } else {
        65536
      },
      module_name: mem.module_name,
      field_name: mem.field_name,
      field: "",
    })
    i = i + 1
  }
  let mut g = 0
  while g < m.imported_globals {
    let gl = m.globals[g]
    out.push({
      kind: "global",
      ty: gl.ty,
      mutable: gl.mutable,
      min: 0,
      max: 0,
      module_name: gl.module_name,
      field_name: gl.field_name,
      field: "",
    })
    g = g + 1
  }
  // De-duplicate on (kind, module, name) — the identity the host resolves —
  // and give each survivor a field name that is unique inside the struct.
  let kept : Array[ImportSlot] = []
  for s in out {
    let mut seen = false
    for k in kept {
      if k.kind == s.kind &&
        k.module_name == s.module_name &&
        k.field_name == s.field_name {
        seen = true
      }
    }
    if !seen {
      kept.push(s)
    }
  }
  let mut n = 0
  while n < kept.length() {
    // Built by concatenation rather than one interpolation: an interpolation
    // containing `[...]` indexes is read as text, and a field name is the wrong
    // place to find that out.
    let base = slot_ident(kept[n].module_name) +
      "_" +
      slot_ident(kept[n].field_name)
    let mut name = base
    let mut bump = 2
    let mut clash = true
    while clash {
      clash = false
      let mut j = 0
      while j < n {
        if kept[j].field == name {
          clash = true
        }
        j = j + 1
      }
      if clash {
        name = "\{base}_\{bump}"
        bump = bump + 1
      }
    }
    kept[n] = { ..kept[n], field: name, }
    n = n + 1
  }
  kept
}

///|
/// The slot a global index belongs to, or `None` for a defined global.
pub fn imported_global_slot(m : Module, idx : Int32) -> ImportSlot? {
  if idx < 0 || idx >= m.imported_globals {
    return None
  }
  let g = m.globals[idx]
  for s in import_slots(m) {
    if s.kind == "global" &&
      s.module_name == g.module_name &&
      s.field_name == g.field_name {
      return Some(s)
    }
  }
  None
}

///|
/// The field a memory's or table's instance lives under in `MoonliftExterns`.
pub fn imported_instance_field(m : Module, kind : String) -> String? {
  for s in import_slots(m) {
    if s.kind == kind {
      return Some(s.field)
    }
  }
  None
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

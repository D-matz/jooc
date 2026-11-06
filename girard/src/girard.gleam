//// A type annotator for Gleam, written in Gleam.
////
//// Reports the inferred type of every expression — keyed by its source span —
//// and the signature of every top-level function and constant, for a single
//// module ([`annotate`](#annotate)) or a whole package
//// ([`annotate_package`](#annotate_package)). Give it source text or a
//// `glance` AST you parsed yourself.
////
//// Every result also reports which member each reference resolved to — a
//// record field, a module function, constant or constructor under the
//// module's canonical path, a local variable, or unresolved — for every field
//// access and every bare name in call position, and names every top-level
//// definition left out of the build for the other `Target`.
////
//// Imported modules are resolved through a [`Resolver`](#Resolver) to obtain
//// their public interfaces.

// import argv
import girard/internal/reference
import girard/internal/scc
import girard/internal/ty
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int

// import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string

// Public types
//
// The vocabulary a consumer pattern-matches on: the structured `Type` and
// its generalized `Scheme`, the inference `Error`, the per-expression
// `Annotation` and whole-module `AnnotatedModule` results, the
// `Resolution` / `ResolvedReference` vocabulary `AnnotatedModule` carries,
// and the `Resolver` and `Target` knobs that configure a run.

/// The structured type girard infers for an expression or definition. Pattern-
/// match on its variants to inspect an inferred type, or render it to Gleam
/// syntax with [`type_to_string`](#type_to_string).
pub type Type {
  /// A named, nominal type such as `Int`, `List(a)`, `Result(a, e)` or a
  /// user-defined custom type. `module` is `"gleam"` for prelude types.
  Named(module: String, name: String, arguments: List(Type))
  /// A function type `fn(a, b) -> c`.
  Fn(arguments: List(Type), return: Type)
  /// A type variable identified by `id`. During inference the substitution
  /// table may bind that id to another type; in a `Scheme`, `vars` identifies
  /// which ids are universally quantified (generic).
  Var(id: Int)
  /// A tuple type `#(a, b, c)`.
  Tuple(elements: List(Type))
}

/// A polymorphic type scheme `forall vars. type_`: the generalized type of a
/// top-level function or constant. `vars` are the ids of the `Var`s in `type_`
/// that are universally quantified (generic); a monomorphic binding is
/// `Scheme([], type_)`.
pub type Scheme {
  Scheme(vars: List(Int), type_: Type)
}

/// Why a module could not be typed. Variants describe the failure in terms of
/// the type system and the offending source construct.
pub type Error {
  TypeMismatch(left: Type, right: Type)
  ArityMismatch
  RecursiveType(id: Int, type_: Type)
  UnboundVariable(name: String)
  UnknownConstructor(name: String)
  UnknownModule(alias: String)
  NoSuchExport(module: String, name: String)
  NoSuchField(type_name: String, label: String)
  NotARecord
  NotATuple
  TupleIndexOutOfRange(index: Int)
  UnknownLabel(label: String)
  AmbiguousCall
  MissingArgument
  Unsupported(feature: String)
  ParseFailed(glance.Error)
}

/// The inferred type of a single expression, identified by its source span.
/// `type_` is a structured `Type` you can pattern-match on; render it with
/// [`type_to_string`](#type_to_string).
pub type Annotation {
  Annotation(span: glance.Span, type_: Type)
}

/// Everything girard inferred for one module: each top-level definition's
/// signature, the type of every expression in their bodies, and what every
/// field access and every bare name in call position resolved to.
///
/// `functions` and `constants` have one entry per top-level definition — its
/// generalized `Scheme` (a `type_` plus the ids of its quantified `Var`s).
/// `expressions` is finer-grained: the `Type` of *every* expression — literals,
/// calls, operators, sub-expressions — keyed by its `glance` source span, so
/// you can join inferred types onto your own AST. Render any type with
/// [`type_to_string`](#type_to_string).
///
/// `resolutions` is sorted by span, with one entry per span. The contract is
/// exact: an entry is recorded for every `glance.FieldAccess` girard walked,
/// wherever it sits, and for every bare name in call position — the callee of
/// a call, a capture or a `use`, and a bare pipe target. Nothing else is
/// recorded, so a name read outside call position (`let g = greet`), the
/// constructor of a record update or of a pattern, and a tuple index have no
/// entry. A span with no entry was therefore either not a recorded position or
/// never walked: nothing is recorded inside a definition `dropped` names, and,
/// for a record reached through [`annotate_package`](#annotate_package),
/// nothing inside one the enclosing [`ModuleResult`](#ModuleResult)'s
/// `skipped` names. The strict entry points return no `AnnotatedModule` at all
/// when a definition fails, so from them every walked definition the module
/// declares is in the record.
///
/// A resolution names a module by its canonical path, never the alias it was
/// imported under. The module under analysis is named as girard was given it:
/// its path under [`annotate_package`](#annotate_package), and `""` for a
/// module annotated on its own — the same name its own types carry in `Named`.
pub type AnnotatedModule {
  AnnotatedModule(
    /// Top-level function name to inferred signature scheme, in source order.
    functions: List(#(String, Scheme)),
    /// Top-level constant name to inferred scheme, in source order.
    constants: List(#(String, Scheme)),
    /// Expression span to inferred type, sorted by start offset.
    expressions: List(Annotation),
    /// What every field access and every bare name in call position resolved
    /// to, sorted by span, one entry per span.
    resolutions: List(ResolvedReference),
    /// Top-level functions and constants dropped for the other build
    /// [`Target`](#Target), with their spans, sorted by span.
    dropped: List(Dropped),
  )
}

/// A top-level function or constant left out of the build for the other
/// [`Target`](#Target): its name, and the span glance gave the definition —
/// from its `pub`, `fn` or `const` keyword to its closing token. Everything
/// written above that keyword is outside the span, including the doc comment
/// and the `@target` attribute that is the reason the definition is here at
/// all. It carries no target of its own — there are two, and the active one is
/// in the caller's [`Options`](#Options).
pub type Dropped {
  Dropped(name: String, span: glance.Span)
}

/// Which member a reference resolved to. The variants are named after the
/// compiler's `ValueConstructorVariant`, which is where the same distinction
/// lives there, plus `RecordField` for the case the compiler reaches through
/// `RecordAccess` rather than through a scope entry.
pub type Resolution {
  /// A field of the accessed value's nominal type — the compiler's
  /// `RecordAccess`. `receiver` is the type of the value the field was read
  /// from, the thing left of the dot. The compiler calls that field `record`;
  /// this is the one place girard does not take its name, because here it
  /// holds a *type* rather than the accessed expression, and because the same
  /// word then has to name both the whole access and one half of it.
  RecordField(receiver: Type, label: String)
  /// A module's function, under the module's canonical path.
  ModuleFn(module: String, name: String)
  /// A module's constant, under the module's canonical path.
  ModuleConstant(module: String, name: String)
  /// A custom-type constructor, under its defining module's canonical path and
  /// its declared name — `Near`, even where it was imported `as Close`. The
  /// compiler calls this variant `Record`; `Constructor` is the name it uses
  /// for the same thing wherever it faces outwards.
  Constructor(module: String, name: String)
  /// A local binding: a `let`, a parameter, or a pattern's binding.
  LocalVariable(name: String)
  /// girard reached no member *at* the reference. The reason says why.
  Unresolved(reason: UnresolvedReason)
}

/// Why girard reached no member at a reference.
pub type UnresolvedReason {
  /// The receiver's type was unknown at the access and no module of its name
  /// exported the label, so girard deferred the access and read the field only
  /// once later inference had fixed the type — after the point where a member
  /// could be named. The [`Annotation`](#Annotation) at the span is still
  /// girard's answer for the field's type; only the member is unreported.
  ///
  /// Named for the compiler error covering the same ground,
  /// `RecordAccessUnknownType`. girard defers where the compiler's own
  /// inference has not fixed the receiver's type at the access either — there
  /// the compiler rejects the program (`Unknown type for record access`) and
  /// girard is the more permissive of the two. Wherever the compiler pushes a
  /// known type into a lambda's parameters before walking its body, girard now
  /// does too, so a receiver the compiler can type is one girard resolves at
  /// the access rather than after it.
  ///
  /// That is measured rather than promised: over the corpora girard is checked
  /// against — its `fixtures/oracle/` and `fixtures/golden/` fixtures, and a resweep of lustre,
  /// mist, wisp, glint, birl, gleam_otp, maud and shore — no accepted program
  /// reports this reason. A finite census is not a proof, so a new one over
  /// code the compiler accepts is a gap in girard's inference order, and worth
  /// reporting as one.
  RecordAccessUnknownType
}

/// One reference and what it resolved to.
///
/// `span` is the whole access — the same span [`Annotation`](#Annotation)
/// carries for it — while `label_span` and `container_span` are the member and
/// the accessed value, named as the compiler names the two spans it computes
/// for a field access. For a bare name in call position the three are the same
/// span.
///
/// Note that the compiler's own `Reference` is a different notion: it records
/// the *syntax* a use took — qualified, unqualified, aliased — for renaming and
/// find-references. A `ResolvedReference` says which member the use reached,
/// and says nothing about how it was spelled.
pub type ResolvedReference {
  ResolvedReference(
    span: glance.Span,
    label_span: glance.Span,
    container_span: glance.Span,
    resolution: Resolution,
  )
}

/// Resolves an imported module path (e.g. `"gleam/list"`) to its source.
pub type Resolver =
  fn(String) -> Result(String, Nil)

/// The build target a module is compiled for. The target is a whole-build
/// setting in Gleam, so it applies to every module in one annotation run.
/// Definitions and imports annotated `@target(...)` are kept only when they
/// match the active target. `default_options()` selects `Erlang` (matching
/// `gleam build`'s default); use `with_target` for JavaScript.
pub type Target {
  Erlang
  JavaScript
}

// Options
//
// How a module is annotated — the resolver that finds imported modules and
// the build target to type for. Build one with `default_options` and adjust
// it with the `with_*` helpers.

/// How a module is annotated: which [`Resolver`](#Resolver) finds imported
/// modules, and which build [`Target`](#Target) to type for. Build one from
/// [`default_options`](#default_options) and customize it with
/// [`with_target`](#with_target) and [`with_resolver`](#with_resolver):
///
/// ```gleam
/// default_options()
/// |> with_target(JavaScript)
/// ```
pub opaque type Options {
  Options(resolver: Resolver, target: Target)
}

/// Default options: resolve imports from disk (`disk_resolver()`) and type for
/// the `Erlang` target (matching `gleam build`'s default).
pub fn default_options() -> Options {
  Options(resolver: disk_resolver(), target: Erlang)
}

/// Resolve imported modules with `resolver` — e.g. `fn(_) { Error(Nil) }` to
/// resolve none, or a custom in-memory resolver.
pub fn with_resolver(options: Options, resolver: Resolver) -> Options {
  Options(..options, resolver:)
}

/// Type for `target`. `@target(...)` definitions that do not match are dropped,
/// exactly as the compiler omits them from the build.
pub fn with_target(options: Options, target: Target) -> Options {
  Options(..options, target:)
}

// Default resolver
//
// The resolver `default_options` uses: read an imported module's source from
// `src/` or the installed packages under `build/packages`.

/// The default resolver: looks for an imported module's source under `src/`
/// first, then the `build/packages/*/src` dependency sources, relative to the
/// current working directory. Constructing the resolver touches no filesystem;
/// the `build/packages` listing and every source read happen lazily, when the
/// resolver is invoked. A missing `build/packages` or an unreadable source is
/// not an error here — the import is simply not found, surfaced as `Error(Nil)`
/// at resolution time.
pub fn disk_resolver() -> Resolver {
  fn(_) { Error(Nil) }
  // fn(path: String) -> Result(String, Nil) {
  //   // Prefer the project's own sources; only scan the installed packages when
  //   // the module is not found under `src/`, so in-project imports never pay for
  //   // the directory listing.
  //   case simplifile.read("src/" <> path <> ".gleam") {
  //     Ok(source) -> Ok(source)
  //     Error(_) -> {
  //       let packages =
  //         result.unwrap(simplifile.read_directory("build/packages"), [])
  //       first_readable(
  //         list.map(packages, fn(pkg) {
  //           "build/packages/" <> pkg <> "/src/" <> path <> ".gleam"
  //         }),
  //       )
  //     }
  //   }
  // }
}

// fn first_readable(paths: List(String)) -> Result(String, Nil) {
//   case paths {
//     [] -> Error(Nil)
//     [path, ..rest] ->
//       case simplifile.read(path) {
//         Ok(source) -> Ok(source)
//         Error(_) -> first_readable(rest)
//       }
//   }
// }

// Annotating a module
//
// The primary entry points. Annotate source text or a pre-parsed `glance`
// module, inferring every expression and top-level signature and resolving
// every reference, or return the first inference error.

/// Annotate a Gleam source string: parse it with `glance`, then annotate as
/// [`annotate_module`](#annotate_module). Returns the inferred error if the
/// module does not type. The quick path is `annotate(source, default_options())`.
pub fn annotate(
  source: String,
  options: Options,
) -> Result(AnnotatedModule, Error) {
  use module <- result.try(parse(source))
  annotate_module(module, options)
}

/// Annotate an already-parsed `glance.Module`. Use this when you have parsed the
/// source with `glance` yourself — the returned spans are glance's, so they line
/// up with your AST's node spans and you avoid parsing the same source twice.
/// (Imported modules are still parsed internally, via the resolver.) Returns the
/// inferred error if the module does not type; for partial results on an
/// ill-typed module, use [`annotate_package`](#annotate_package).
pub fn annotate_module(
  module: glance.Module,
  options: Options,
) -> Result(AnnotatedModule, Error) {
  use inferred <- result.try(infer_module(
    options,
    set.new(),
    dict.new(),
    "",
    module,
    best_effort: False,
  ))
  Ok(render(inferred))
}

fn parse(source: String) -> Result(glance.Module, Error) {
  glance.module(source) |> result.map_error(ParseFailed)
}

// Caching
//
// A reusable cache of inferred module interfaces, threaded across annotation
// calls so a shared import is resolved and inferred once rather than
// repeatedly — an editor re-checking a file, or a walk over a package.

/// A reusable cache of inferred module interfaces, threaded across
/// [`annotate_with_cache`](#annotate_with_cache) calls. Annotating a module
/// infers every module it imports — transitively — to obtain their interfaces;
/// without a shared cache each call repeats that work, so a tool re-checking a
/// module or walking a package re-infers the same dependencies again and again.
/// Carrying a `Cache` between calls infers each imported module once and reuses
/// it thereafter.
///
/// A cache keys interfaces by module path and assumes a fixed
/// [`Resolver`](#Resolver) and [`Target`](#Target): do not reuse one across
/// different resolvers or targets, or it would hand back interfaces built from
/// the wrong sources. Create one with [`new_cache`](#new_cache); when a module's
/// source changes, drop it with [`invalidate`](#invalidate).
pub opaque type Cache {
  Cache(interfaces: InterfaceCache)
}

/// An empty [`Cache`](#Cache) to seed a run of
/// [`annotate_with_cache`](#annotate_with_cache) calls.
pub fn new_cache() -> Cache {
  Cache(dict.new())
}

/// Annotate a source string like [`annotate`](#annotate), but reuse and extend
/// `cache`: imported modules already inferred in it are taken from the cache
/// rather than resolved and inferred again, and any newly inferred ones are
/// added. Returns the result and the updated cache to thread into the next call.
///
/// `annotate_with_cache(source, options, new_cache())` matches
/// `annotate(source, options)` exactly; the cache only pays off
/// when shared across calls that import overlapping modules — an editor
/// re-checking a file as it changes, or a walk over a package's modules.
pub fn annotate_with_cache(
  source: String,
  options: Options,
  cache: Cache,
) -> #(Result(AnnotatedModule, Error), Cache) {
  case parse(source) {
    Error(error) -> #(Error(error), cache)
    Ok(module) ->
      case
        infer_module(
          options,
          set.new(),
          cache.interfaces,
          "",
          module,
          best_effort: False,
        )
      {
        Error(error) -> #(Error(error), cache)
        Ok(inferred) -> #(Ok(render(inferred)), Cache(inferred.cache))
      }
  }
}

/// Drop the cached interface for `path` (the module path, e.g.
/// `"my_app/router"`), so the next [`annotate_with_cache`](#annotate_with_cache)
/// that needs it re-infers it from source. Use this when a module changes.
///
/// Only the named module is dropped. A cached module that *imports* the changed
/// one keeps its own (now possibly stale) interface, so after a change that
/// alters a module's public surface, also invalidate its importers — or start
/// from a [`new_cache`](#new_cache).
pub fn invalidate(cache: Cache, path: String) -> Cache {
  Cache(dict.delete(cache.interfaces, path))
}

// Annotating a package
//
// Annotate every module of a package in one pass, sharing inference of common
// imports. Best-effort per definition: one ill-typed definition (and its
// dependants) is reported as skipped while the rest are still annotated.

/// The result of annotating one module of a package: its
/// [`AnnotatedModule`](#AnnotatedModule) plus the definitions that could not be
/// typed. `skipped` names each top-level function or constant girard declined,
/// with the error that declined it; a definition in `skipped` is absent from
/// `annotated`, and nothing inside its span is annotated or resolved.
pub type ModuleResult {
  ModuleResult(annotated: AnnotatedModule, skipped: List(#(String, Error)))
}

/// Annotate every module in a package in one pass, sharing inference of common
/// imports across modules. `modules` maps each module's path (e.g.
/// `"my_app/router"`) to its parsed `glance.Module`; the result maps the same
/// paths to a [`ModuleResult`](#ModuleResult).
///
/// This is the batch counterpart to [`annotate_module`](#annotate_module): a
/// dependency imported by several modules is inferred once for the whole run
/// rather than once per
/// importing module. Cross-module references *within* the package are resolved
/// through the options' resolver, so it must also resolve the package's own
/// modules (a resolver wrapping the build's module sources does); a module
/// reached only that way is inferred for its interface and again here for its
/// annotations.
///
/// Best-effort per definition: a top-level function or constant that does not
/// type — along with any that depend on it — is reported in that module's
/// `skipped` list rather than failing the module, while every other definition
/// is still annotated. Definition failures therefore leave the module present
/// in the result; a fully strict check is `result.skipped == []`.
pub fn annotate_package(
  modules: List(#(String, glance.Module)),
  options: Options,
) -> dict.Dict(String, ModuleResult) {
  let #(results, _cache) =
    list.fold(modules, #(dict.new(), dict.new()), fn(acc, entry) {
      let #(results, cache) = acc
      let #(path, module) = entry
      case
        infer_module(options, set.new(), cache, path, module, best_effort: True)
      {
        // Best-effort mode converts definition failures to skipped entries, so
        // `infer_module` should not fail. If that invariant is broken, omit the
        // module rather than crashing the whole package run.
        Error(_) -> #(results, cache)
        Ok(inferred) -> {
          // Seed this module's own interface so a later module that imports it
          // hits the cache instead of re-resolving it through the resolver.
          let cache = dict.insert(inferred.cache, path, inferred.interface)
          let result = ModuleResult(render(inferred), inferred.skipped)
          #(dict.insert(results, path, result), cache)
        }
      }
    })
  results
}

// Reporting
//
// Human-readable rendering of inferred types and errors: a single `Type` to
// Gleam syntax, a whole module to a text report, or an `Error` to a short
// description.

/// A short, human-readable description of an inference error.
pub fn describe_error(error: Error) -> String {
  case error {
    TypeMismatch(a, b) ->
      "type mismatch: " <> to_string(a) <> " vs " <> to_string(b)
    ArityMismatch -> "wrong number of arguments"
    RecursiveType(_, type_) -> "recursive type: " <> to_string(type_)
    UnboundVariable(name) -> "unbound variable: " <> name
    UnknownConstructor(name) -> "unknown constructor: " <> name
    UnknownModule(alias) -> "unknown module: " <> alias
    NoSuchExport(module, name) ->
      "module `" <> module <> "` has no `" <> name <> "`"
    NoSuchField(type_name, label) ->
      "type `" <> type_name <> "` has no field `" <> label <> "`"
    NotARecord -> "field access or update on a non-record value"
    NotATuple -> "tuple index on a non-tuple value"
    TupleIndexOutOfRange(index) ->
      "tuple index out of range: " <> int.to_string(index)
    UnknownLabel(label) -> "unknown argument label: " <> label
    AmbiguousCall -> "labelled arguments to an unknown callable"
    MissingArgument -> "missing argument"
    Unsupported(feature) -> "unsupported: " <> feature
    ParseFailed(_) -> "could not parse source"
  }
}

/// Annotate a source string and render the result as a human-readable text
/// report (signatures and per-expression types). On failure the report is a
/// single `// error:` line.
///
/// ## Example
///
/// ```gleam
/// report("pub fn double(x) { x + x }")
/// ```
///
/// ```text
/// double: fn(Int) -> Int
/// 19-20: Int
/// 19-24: Int
/// 23-24: Int
/// ```
pub fn report(source: String) -> String {
  case annotate(source, default_options()) {
    Error(error) -> "// error: " <> describe_error(error)
    Ok(annotated) -> {
      // Share one printer context so type-variable names are consistent across
      // every signature and expression in the report.
      let names = new_names()
      let #(rev_sigs, names) =
        list.fold(
          list.append(annotated.functions, annotated.constants),
          #([], names),
          fn(acc, def) {
            let #(lines, names) = acc
            let #(text, names) = print(names, { def.1 }.type_)
            #([def.0 <> ": " <> text, ..lines], names)
          },
        )
      let #(rev_exprs, _names) =
        list.fold(annotated.expressions, #([], names), fn(acc, a) {
          let #(lines, names) = acc
          let #(text, names) = print(names, a.type_)
          let line =
            int.to_string(a.span.start)
            <> "-"
            <> int.to_string(a.span.end)
            <> ": "
            <> text
          #([line, ..lines], names)
        })
      string.join(
        list.append(list.reverse(rev_sigs), list.reverse(rev_exprs)),
        "\n",
      )
    }
  }
}

/// Render an inferred `Type` to Gleam syntax (e.g. `fn(Int) -> a`), naming type
/// variables `a, b, c, …`. Each call names variables independently: an `a` in
/// one rendered type is unrelated to an `a` in another.
pub fn type_to_string(type_: Type) -> String {
  to_string(type_)
}

// Command-line interface
//
// `gleam run` annotates a file or stdin and prints the text report.

// `gleam run -- <file.gleam>` annotates a file; `gleam run -- -` (or no
// arguments, or piped input) annotates stdin. Imports are resolved from disk.
// pub fn main() -> Nil {
//   case argv.load().arguments {
//     ["--help"] | ["-h"] -> io.println(usage())
//     [] | ["-"] -> emit(read_stdin())
//     [path] -> emit(read_file(path))
//     _ -> {
//       io.println_error("error: expected a single file path, `-`, or no input")
//       io.println_error(usage())
//     }
//   }
// }

// Why the CLI could not read its input.
// type InputError {
//   FileUnreadable(path: String)
//   StdinUnreadable
// }

// fn emit(source: Result(String, InputError)) -> Nil {
//   case source {
//     Ok(text) -> io.println(report(text))
//     Error(error) -> io.println_error("error: " <> input_error_message(error))
//   }
// }

// fn input_error_message(error: InputError) -> String {
//   case error {
//     FileUnreadable(path) -> "could not read file: " <> path
//     StdinUnreadable -> "could not read stdin"
//   }
// }

// fn read_file(path: String) -> Result(String, InputError) {
//   simplifile.read(path)
//   |> result.replace_error(FileUnreadable(path))
// }

// fn read_stdin() -> Result(String, InputError) {
//   simplifile.read("/dev/stdin")
//   |> result.replace_error(StdinUnreadable)
// }

// fn usage() -> String {
//   "girard — a type annotator for Gleam

// Usage:
//   gleam run -- <file.gleam>     annotate a file
//   gleam run -- -                annotate stdin
//   cat file.gleam | gleam run    annotate stdin

// Output: each top-level definition's inferred signature, then one
// `<start>-<end>: <type>` line per expression (by source byte span)."
// }

// Inference state and environment
//
// The threaded inference `State` and lexical `Env`, plus the prelude seeding
// that starts every run. `State` carries the substitution, recorded
// annotations, deferred accesses and rigid variables; `Env` carries the
// value, type, alias, accessor and module bindings in scope.
//
// `ModuleInterface` is the public surface of an inferred module, consumed
// when importing it elsewhere.

type State {
  State(
    next_id: Int,
    // Bound type variables. Absence means unbound.
    subst: Dict(Int, ty.Type),
    // Inferred type recorded for each annotated source span, in reverse order
    // of discovery. Types are stored "live" and zonked at the end.
    annotations: List(#(glance.Span, ty.Type)),
    // What every field access and every called bare name resolved to, in
    // reverse order of discovery. An accessed record is stored "live" and
    // zonked at the end, as an annotation's type is.
    references: List(Reference),
    // Field accesses and tuple indexes whose container type was not yet known
    // when encountered; resolved by `resolve_pending` once inference has fixed
    // the container type (deferred resolution, like the real compiler).
    pending: List(Pending),
    // Variable ids that are *rigid*: a type variable written in a function's
    // signature annotation, skolemized for that function's body. A rigid var
    // unifies only with itself or a flexible var (which binds to it), never
    // with a concrete type or a different rigid — matching the compiler, which
    // keeps annotated type variables generic and rejects pinning them.
    rigid: Set(Int),
  )
}

// A deferred access awaiting its container's type.
type Pending {
  // `record.label` — the field type goes in `result`.
  PendingField(container: ty.Type, label: String, result: ty.Type)
  // `tuple.index` — the element type goes in `result`.
  PendingIndex(container: ty.Type, index: Int, result: ty.Type)
}

// A reference and what it resolved to, live. The accessed record is an
// inference-side type that later unification may still refine, so it is kept
// as one and `publish_reference` zonks and converts it at the end, exactly as
// `render` does for an annotation. The public `Resolution` cannot be built
// here — it holds the public `Type`, and one module cannot give two types the
// same constructor names.
type Reference {
  Reference(spans: Spans, resolved: Resolved)
}

type Resolved {
  ResolvedField(record: ty.Type, label: String)
  // The scope entry's variant the name was read at, which is what says which
  // member it resolved to and under what name. Published as `ModuleFn`,
  // `ModuleConstant`, `Constructor` or `LocalVariable`, one arm per variant.
  ResolvedValue(variant: ValueVariant)
  // Published as `Unresolved(RecordAccessUnknownType)`.
  ResolvedDeferred
}

// The three spans the compiler records for a reference: the whole access, its
// label and its container (`type_/expression.rs:1362-1379`). For a bare name
// in call position the three coincide.
type Spans {
  Spans(span: glance.Span, label: glance.Span, container: glance.Span)
}

// One scope entry per name, as the compiler's `ValueConstructor`
// (`type_.rs:1490`): the value's scheme and what kind of value it is.
type ValueConstructor {
  ValueConstructor(scheme: ty.Scheme, variant: ValueVariant)
}

// What kind of value a scope entry holds, as the compiler's
// `ValueConstructorVariant` (`type_.rs:720`). A module-level value carries the
// canonical path of the module that declared it and the name it has there, so
// an entry imported under an alias keeps its identity; and the two kinds that
// can take labelled arguments carry their field map, because a constant and a
// local have none and the shape says so. Every variant carries the name the
// value is published under, so a reference needs nothing but the variant.
// Names are prefixed because
// `ModuleFn`, `ModuleConstant`, `Constructor` and `LocalVariable` are already
// the public `Resolution`'s constructors.
type ValueVariant {
  LocalValue(name: String)
  FunctionValue(module: String, name: String, field_map: Option(FieldMap))
  ConstantValue(module: String, name: String)
  ConstructorValue(module: String, name: String, field_map: Option(FieldMap))
}

// The label of each of a callable's positional parameters, `None` where the
// position is unlabelled. Used to reorder labelled and shorthand arguments at
// call and pattern sites.
type FieldMap =
  List(Option(String))

// A callable's field map, or `None` when no position is labelled — the
// compiler's `FieldMap` is optional for the same reason. The one place that
// normalisation happens, so no reader has to ask whether an all-`None` list
// means "no labels".
fn field_map_of(labels: FieldMap) -> Option(FieldMap) {
  use <- bool.guard(when: list.all(labels, fn(l) { l == None }), return: None)
  Some(labels)
}

// The labels a call on this entry may use: the compiler's
// `ValueConstructor::field_map()` (`type_.rs:1611`), which is a projection off
// the variant rather than a table of its own. `None` all the way from where it
// was stored — a callable that labels no position, a value that takes no
// arguments at all, and a call the reader could not attribute to any entry are
// one answer, and the readers turn it into `AmbiguousCall` or an empty list at
// the one place each cares.
fn field_map(variant: ValueVariant) -> Option(FieldMap) {
  case variant {
    FunctionValue(field_map:, ..) | ConstructorValue(field_map:, ..) ->
      field_map
    ConstantValue(..) | LocalValue(..) -> None
  }
}

// A record type's field accessors: the labels every variant declares
// compatibly, and each variant's own, in declaration order. Each map is
// `label -> fn(record) -> field`, generalized over the type's parameters. A
// value known to be one variant reads that variant's map, so it reaches
// fields the other variants do not declare.
type Accessors {
  Accessors(
    shared: Dict(String, ty.Scheme),
    by_variant: List(Dict(String, ty.Scheme)),
  )
}

type Env {
  Env(
    // Value bindings in scope: locals, parameters, top-level functions and
    // custom-type constructors. One entry per name, as the compiler's
    // `Environment.scope` (`environment.rs:61`) keeps it: a name's scheme, its
    // labels and its identity are one thing, so binding a name replaces all of
    // them and cannot leave half of a shadowed binding behind.
    values: Dict(String, ValueConstructor),
    // The subset of `values` that can contribute free type variables to the
    // environment — bindings whose scheme has a type variable not bound by its
    // own quantifier (live monomorphic bindings: locals, parameters, SCC
    // members mid-inference). Fully-generalized and imported schemes quantify
    // every variable in their type, so they contribute nothing regardless of
    // the substitution and are omitted. `env_free_vars` scans only these, which
    // are few, instead of every binding in scope (mostly closed imports).
    // Maintained alongside `values` in `install_entry`, its sole writer.
    open_values: Dict(String, ty.Scheme),
    // Locally-defined type aliases: name -> (parameter names, aliased type
    // AST), expanded during hydration in this module's environment.
    aliases: Dict(String, #(List(String), glance.Type)),
    // Type aliases brought in by unqualified imports, already resolved to a
    // type with the alias's parameters as variables (param ids + body), so
    // they need no re-hydration in this module's environment.
    imported_aliases: Dict(String, #(List(Int), ty.Type)),
    // Record field accessors, by the name of the type they belong to.
    accessors: Dict(String, Accessors),
    // In-scope type names -> (origin module, origin name, arity). Covers types
    // defined in the current module and types brought in by unqualified
    // imports. Used during hydration to resolve a bare type name to its module
    // and to the name it has *there* — an `import x.{type T as U}` is in scope
    // as `U` but must hydrate to `x`'s `T`, not a phantom `x.U`.
    local_types: Dict(String, #(String, String, Int)),
    // The name of the module currently being inferred. Local types are minted
    // with this module so they stay distinct from imported types.
    current_module: String,
    // Imported modules available for qualified access, keyed by the alias used
    // in source (e.g. `list` for `import gleam/list`).
    modules: Dict(String, ModuleInterface),
    // Every interface reachable from `modules` (directly imported modules and,
    // transitively, the modules they expose), keyed by its real module name
    // (`interface.name`, the full path — unique per run, unlike an alias). A
    // flat index of the same graph `modules` spans, maintained alongside it in
    // `import_qualified`, so resolving a type's accessors by origin module
    // (`accessors_of_module`) is one `dict.get` rather than a transitive walk
    // of the whole interface graph on every field access.
    module_index: Dict(String, ModuleInterface),
    // Names of the strongly-connected-component members currently being
    // inferred. A reference to one of these resolves its bound scheme through
    // the current substitution before instantiating, so a type the provider's
    // already-inferred body has settled (an unannotated parameter absorbed into
    // a signature variable, say) is seen by a later sibling — the compiler's
    // shared mutable type cells, in girard's threaded substitution. Empty
    // outside an SCC, so finished schemes instantiate verbatim.
    live: Set(String),
  )
}

// The public surface of a module, used when importing it elsewhere.
type ModuleInterface {
  ModuleInterface(
    name: String,
    // One entry per public value, as the compiler's `ModuleInterface.values`
    // (`type_.rs:1021`) holds them: an export's scheme, its labels and the
    // identity it was declared under travel together, so an importer reads
    // what the exporting module had in scope rather than a reconstruction of
    // it.
    values: Dict(String, ValueConstructor),
    types: Dict(String, #(String, String, Int)),
    // Public type aliases, resolved to a type with the alias's parameters as
    // variables (param ids + body).
    aliases: Dict(String, #(List(Int), ty.Type)),
    accessors: Dict(String, Accessors),
    // The modules this one imports, so a type it exposes from another module
    // (e.g. a `glance.Span` field) keeps its accessors reachable transitively.
    // Keyed by the alias they are reachable under *here*, which is why a
    // discard-aliased import is absent from it: it has no qualified name.
    modules: Dict(String, ModuleInterface),
    // Everything this module resolved, keyed by real module name — the same
    // graph, addressed the way `accessors_of_module` addresses it. A
    // discard-aliased import is in here, so an importer can still find the
    // accessors of a type this module exposes from one.
    reachable: Dict(String, ModuleInterface),
  )
}

fn new_state() -> State {
  State(
    next_id: 0,
    subst: dict.new(),
    annotations: [],
    references: [],
    pending: [],
    rigid: set.new(),
  )
}

fn mark_rigid(st: State, ids: List(Int)) -> State {
  State(..st, rigid: list.fold(ids, st.rigid, set.insert))
}

fn is_rigid(st: State, id: Int) -> Bool {
  set.contains(st.rigid, id)
}

fn new_env() -> Env {
  Env(
    values: dict.new(),
    open_values: dict.new(),
    aliases: dict.new(),
    imported_aliases: dict.new(),
    accessors: dict.new(),
    local_types: dict.new(),
    current_module: "",
    modules: dict.new(),
    module_index: dict.new(),
    live: set.new(),
  )
}

// Set the name of the module currently being inferred.
fn set_module(env: Env, name: String) -> Env {
  Env(..env, current_module: name)
}

// Declare a local type name (and arity) so references to it during hydration
// resolve to the current module. Call this for every custom type before
// registering any of them, so forward references resolve correctly.
fn declare_type(env: Env, name: String, arity: Int) -> Env {
  Env(
    ..env,
    local_types: dict.insert(env.local_types, name, #(
      env.current_module,
      name,
      arity,
    )),
  )
}

// Register a type alias so references to it expand during hydration.
fn register_type_alias(env: Env, alias: glance.TypeAlias) -> Env {
  Env(
    ..env,
    aliases: dict.insert(env.aliases, alias.name, #(
      alias.parameters,
      alias.aliased,
    )),
  )
}

fn fresh_id(st: State) -> #(Int, State) {
  #(st.next_id, State(..st, next_id: st.next_id + 1))
}

fn fresh(st: State) -> #(ty.Type, State) {
  let #(id, st) = fresh_id(st)
  #(ty.Var(id), st)
}

// The id of a type variable. Callers pass freshly-minted `Var`s (custom-type
// parameters, instantiated constructor heads), so a non-`Var` is `Error` rather
// than a fabricated id.
fn var_id(type_: ty.Type) -> Result(Int, Nil) {
  case type_ {
    ty.Var(id) -> Ok(id)
    _ -> Error(Nil)
  }
}

// Mint a fresh type variable (a thin wrapper over `fresh`).
fn fresh_var(st: State) -> #(ty.Type, State) {
  fresh(st)
}

// Mark `names` as the live members of the strongly-connected component being
// inferred, so a reference to one resolves its scheme through the current
// substitution before instantiating (see `Env.live`).
fn mark_live(env: Env, names: List(String)) -> Env {
  Env(..env, live: set.from_list(names))
}

// The prelude value constructors (`True`, `False`, `Nil`, `Ok`, `Error`) as
// named scope entries, with `Ok`'s and `Error`'s type variables minted from
// `st`. Every one of them is a constructor of a prelude type, so the entries
// are built here and one table serves both the initial environment and the
// `gleam` interface — neither has to know how to wrap the other's.
fn prelude_values(st: State) -> #(List(#(String, ValueConstructor)), State) {
  // Ok(a) -> Result(a, e), the prelude's first variant.
  let #(ok_a, st) = fresh_id(st)
  let #(ok_e, st) = fresh_id(st)
  let ok =
    ty.Scheme(
      [ok_a, ok_e],
      ty.Fn(
        [ty.Var(ok_a)],
        stamp(st, prelude_result(ty.Var(ok_a), ty.Var(ok_e)), 0),
      ),
    )

  // Error(e) -> Result(a, e), the second.
  let #(err_a, st) = fresh_id(st)
  let #(err_e, st) = fresh_id(st)
  let error =
    ty.Scheme(
      [err_a, err_e],
      ty.Fn(
        [ty.Var(err_e)],
        stamp(st, prelude_result(ty.Var(err_a), ty.Var(err_e)), 1),
      ),
    )

  let values =
    list.map(
      [
        #("True", ty.Scheme([], prelude_bool())),
        #("False", ty.Scheme([], prelude_bool())),
        #("Nil", ty.Scheme([], prelude_nil())),
        #("Ok", ok),
        #("Error", error),
      ],
      fn(value) {
        let #(name, scheme) = value
        #(
          name,
          ValueConstructor(scheme, ConstructorValue(prelude_module, name, None)),
        )
      },
    )
  #(values, st)
}

// The initial environment and state, seeded with the prelude value
// constructors.
fn prelude() -> #(Env, State) {
  let #(values, st) = prelude_values(new_state())
  let env =
    list.fold(values, new_env(), fn(env, value) {
      install_entry(env, value.0, value.1)
    })
  #(env, st)
}

// The implicit `gleam` prelude module's public interface, used to resolve
// `import gleam` / `import gleam.{Error as Err}`. The prelude has no source
// file; the compiler treats `gleam` as a built-in module exposing the prelude
// types and value constructors. An interface's schemes are instantiated on
// use, so the ids their variables carry here do not matter.
fn prelude_interface() -> ModuleInterface {
  let module = prelude_module
  let #(values, _st) = prelude_values(new_state())
  let types_ =
    dict.from_list([
      #("Int", #(module, "Int", 0)),
      #("Float", #(module, "Float", 0)),
      #("String", #(module, "String", 0)),
      #("Bool", #(module, "Bool", 0)),
      #("Nil", #(module, "Nil", 0)),
      #("BitArray", #(module, "BitArray", 0)),
      #("UtfCodepoint", #(module, "UtfCodepoint", 0)),
      #("List", #(module, "List", 1)),
      #("Result", #(module, "Result", 2)),
    ])
  ModuleInterface(
    name: module,
    values: dict.from_list(values),
    types: types_,
    aliases: dict.new(),
    accessors: dict.new(),
    modules: dict.new(),
    reachable: dict.new(),
  )
}

// Install a whole scope entry under a name, replacing whatever it held. The
// only writer of `values`, and with it the only maintainer of `open_values`,
// so the index cannot fall out of step with the table it indexes.
fn install_entry(env: Env, name: String, entry: ValueConstructor) -> Env {
  Env(
    ..env,
    values: dict.insert(env.values, name, entry),
    // Track whether this binding can contribute environment free variables, so
    // `env_free_vars` need not re-walk every closed scheme. A closed scheme
    // shadowing an open one must evict the stale open entry, hence the delete.
    open_values: case scheme_is_closed(entry.scheme) {
      True -> dict.delete(env.open_values, name)
      False -> dict.insert(env.open_values, name, entry.scheme)
    },
  )
}

// Install a name at a scheme and a variant, building the entry for a caller
// that does not already hold one.
fn install(
  env: Env,
  name: String,
  scheme: ty.Scheme,
  variant: ValueVariant,
) -> Env {
  install_entry(env, name, ValueConstructor(scheme, variant))
}

// Bind a local value: a `let`, a parameter, a pattern's binding. Replacing the
// entry is what shadows a module-level name's labels and identity along with
// its type.
fn bind_local(env: Env, name: String, scheme: ty.Scheme) -> Env {
  install(env, name, scheme, LocalValue(name))
}

// Whether a scheme can never contribute a free variable to the environment:
// every type variable in its type is bound by its own quantifier. This is
// purely syntactic and so substitution-independent — `scheme_free_vars`
// resolves and collects only variables *not* in `bound`, so a scheme with none
// such yields nothing for any substitution, now or later.
fn scheme_is_closed(scheme: ty.Scheme) -> Bool {
  let bound = set.from_list(scheme.vars)
  all_vars_bound(scheme.type_, bound)
}

fn all_vars_bound(type_: ty.Type, bound: Set(Int)) -> Bool {
  case type_ {
    ty.Var(id) -> set.contains(bound, id)
    ty.Named(_, _, args, _) -> list.all(args, all_vars_bound(_, bound))
    ty.Fn(args, ret) ->
      list.all(args, all_vars_bound(_, bound)) && all_vars_bound(ret, bound)
    ty.Tuple(elements) -> list.all(elements, all_vars_bound(_, bound))
  }
}

// Look up a value's scheme in the environment.
fn lookup(env: Env, name: String) -> Result(ty.Scheme, Nil) {
  dict.get(env.values, name) |> result.map(fn(entry) { entry.scheme })
}

// Module inference
//
// The driver: fully infer a module by resolving imports, registering types,
// ordering definitions by strongly-connected component, and inferring each
// component before generalizing at the top-level boundary. Best-effort mode
// keeps going past a component that fails to type.

// A top-level definition that participates in the dependency graph.
type Def {
  FunctionDef(glance.Function)
  ConstantDef(glance.Constant)
}

// Install a top-level definition as one scope entry: its scheme, its identity
// and, for a function, the labels its parameters declare. A definition whose
// component fails to type has that component's whole environment discarded, so
// a name it shadowed reverts whole — an unqualified import of the same name
// keeps its scheme, its labels and its origin together, rather than any two of
// the three.
fn define_def(env: Env, def: Def, scheme: ty.Scheme) -> Env {
  install(env, def_name(def), scheme, def_variant(env, def))
}

fn def_variant(env: Env, def: Def) -> ValueVariant {
  case def {
    FunctionDef(f) ->
      FunctionValue(
        env.current_module,
        f.name,
        field_map_of(list.map(f.parameters, fn(p) { p.label })),
      )
    ConstantDef(c) -> ConstantValue(env.current_module, c.name)
  }
}

fn def_name(def: Def) -> String {
  case def {
    FunctionDef(f) -> f.name
    ConstantDef(c) -> c.name
  }
}

fn def_span(def: Def) -> glance.Span {
  case def {
    FunctionDef(f) -> f.location
    ConstantDef(c) -> c.location
  }
}

// `#(value references, field-access qualifier names)` of a definition.
fn def_refs(def: Def) -> #(List(String), List(String)) {
  case def {
    FunctionDef(f) -> reference.in_function(f)
    ConstantDef(c) -> reference.in_constant(c)
  }
}

fn infer_def(
  env: Env,
  st: State,
  def: Def,
) -> Result(#(ty.Type, State), Error) {
  case def {
    FunctionDef(f) -> infer_function(env, st, f)
    ConstantDef(c) -> infer_constant(env, st, c)
  }
}

// Interfaces resolved so far in this run, keyed by module path. Resolving a
// module is expensive (it infers the whole module), and a deep import graph
// imports the same dependency many times; memoizing keeps each module inferred
// once rather than re-inferring it exponentially.
type InterfaceCache =
  dict.Dict(String, ModuleInterface)

// Everything one module's inference produced. A tuple ran out of room at four
// elements; naming the parts also keeps the three public callers and
// `resolve_uncached` from destructuring positionally past what each needs.
//
// It holds the definitions inference *walked* rather than the module they came
// from, so `render` has no module to look a definition up in and cannot
// publish one that was never walked. That is what the caller's own unfiltered
// module used to let it do.
type Inferred {
  Inferred(
    functions: List(Def),
    constants: List(Def),
    env: Env,
    st: State,
    interface: ModuleInterface,
    cache: InterfaceCache,
    skipped: List(#(String, Error)),
    dropped: List(Dropped),
  )
}

// Fully infer a module: resolve imports, register types, and infer every
// definition in dependency order. Returns the final environment and state
// plus the module's public interface.
fn infer_module(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  module_name: String,
  module: glance.Module,
  best_effort best_effort: Bool,
) -> Result(Inferred, Error) {
  // Drop definitions and imports compiled only for another target. A pair of
  // target-specific siblings may have different types, so the inactive one
  // must not shadow the active definition.
  let #(module, dropped) = for_target(module, options.target)
  let #(prelude_env, st) = prelude()
  let env = set_module(prelude_env, module_name)

  // 1. Imports.
  use #(env, cache) <- result.try(process_imports(
    options,
    loading,
    cache,
    env,
    module.imports,
    best_effort:,
  ))

  // 2. Pre-declare local type names so forward references resolve, then
  //    register aliases and custom-type constructors/accessors. A function's
  //    or constant's labels need no early pass: they are installed with its
  //    value, by `prereg_def` before any body of its component is walked, and
  //    no earlier component can reference it or it would not be earlier.
  let env =
    list.fold(module.custom_types, env, fn(env, d) {
      let ct = d.definition
      declare_type(env, ct.name, list.length(ct.parameters))
    })
  let env =
    list.fold(module.type_aliases, env, fn(env, d) {
      register_type_alias(env, d.definition)
    })
  let #(env, st) =
    list.fold(module.custom_types, #(env, st), fn(acc, d) {
      let #(env, st) = acc
      register_custom_type(env, st, d.definition)
    })

  // 3. Infer definitions in strongly-connected-component order.
  let functions =
    list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants =
    list.map(module.constants, fn(d) { ConstantDef(d.definition) })
  let defs = list.append(functions, constants)
  // Names in scope as imported modules. A field access `name.member` whose
  // `name` is one of these is qualified module access, not a dependency on a
  // same-named local definition.
  let module_aliases =
    set.from_list(
      list.filter_map(module.imports, fn(d) { qualified_alias(d.definition) }),
    )
  use #(#(final_env, st), skipped) <- result.try(infer_defs(
    env,
    st,
    module_aliases,
    defs,
    best_effort:,
  ))

  let interface =
    build_interface(
      final_env,
      st,
      module_name,
      public_value_names(module),
      public_type_names(module),
      public_accessor_type_names(module),
    )
  Ok(Inferred(
    functions:,
    constants:,
    env: final_env,
    st:,
    interface:,
    cache:,
    skipped:,
    dropped:,
  ))
}

fn infer_defs(
  env: Env,
  st: State,
  module_aliases: Set(String),
  defs: List(Def),
  best_effort best_effort: Bool,
) -> Result(#(#(Env, State), List(#(String, Error))), Error) {
  let by_name = dict.from_list(list.map(defs, fn(d) { #(def_name(d), d) }))
  let names = list.map(defs, def_name)
  let name_set = set.from_list(names)
  let edges =
    dict.from_list(
      list.map(defs, fn(d) {
        let #(values, qualifiers) = def_refs(d)
        // A qualifier edge survives only for a local definition that is not a
        // shadowed module name; value references always count.
        let kept_qualifiers =
          list.filter(qualifiers, fn(name) {
            !set.contains(module_aliases, name)
          })
        let refs =
          list.filter(list.append(values, kept_qualifiers), set.contains(
            name_set,
            _,
          ))
        #(def_name(d), refs)
      }),
    )
  // Each component is a group of mutually recursive definitions, in dependency
  // order. Resolve the names back to definitions up front.
  let groups =
    list.map(scc.components(names, edges), fn(group) {
      list.filter_map(group, dict.get(by_name, _))
    })

  // Strict mode stops at the first component that fails to type, returning its
  // error. Best-effort mode keeps the pre-component environment on a failure —
  // discarding that component's partial annotations and substitution — records
  // every definition in it as skipped (with the error), and carries on; a later
  // component referring to a skipped one fails in turn (an unbound variable) and
  // cascades naturally.
  case best_effort {
    False -> {
      use #(env, st) <- result.map(
        list.try_fold(groups, #(env, st), fn(acc, group) {
          let #(env, st) = acc
          infer_group(env, st, group)
        }),
      )
      #(#(env, st), [])
    }
    True -> Ok(list.fold(groups, #(#(env, st), []), best_effort_group))
  }
}

// One best-effort step over a strongly-connected component: on success adopt
// the new environment; on failure keep the prior one (discarding the
// component's partial work) and record every definition in it as skipped.
fn best_effort_group(
  acc: #(#(Env, State), List(#(String, Error))),
  group: List(Def),
) -> #(#(Env, State), List(#(String, Error))) {
  let #(#(env, st), skipped) = acc
  case infer_group(env, st, group) {
    Ok(env_st) -> #(env_st, skipped)
    Error(error) -> {
      let entries = list.map(group, fn(d) { #(def_name(d), error) })
      #(#(env, st), list.append(skipped, entries))
    }
  }
}

// Infer one strongly-connected component of mutually recursive definitions,
// then generalize each against the surrounding environment and add it back for
// later components.
//
// A function with signature variables is pre-registered at a scheme over those
// variables so recursion and siblings see it polymorphically; its body is
// checked against the signature with those variables rigid, and within its own
// body it sees itself at the rigid monotype (no polymorphic recursion). Every
// other definition is inferred monomorphically against a fresh placeholder.
// The members are marked *live* (see `mark_live`): a reference to a
// sibling resolves its scheme through the current substitution, so once a
// member's body has settled an unannotated part (absorbing it into a signature
// variable) a later sibling sees the resolved type — the compiler's shared
// mutable cells, reproduced through girard's threaded substitution. Because of
// that, bodies are inferred *provider-first*: a member whose signature has an
// unannotated part is typed before the fully-annotated members that consume it
// (a dependency-respecting order within the component, as Tarjan provides).
fn infer_group(
  env: Env,
  st: State,
  group: List(Def),
) -> Result(#(Env, State), Error) {
  let #(group_env, rev_items, st) =
    list.fold(group, #(env, [], st), fn(acc, def) {
      let #(env, items, st) = acc
      prereg_def(env, items, st, def)
    })
  let group_env = mark_live(group_env, list.map(group, def_name))
  let items = list.reverse(rev_items)
  // Type members with an unannotated parameter or return first: their bodies
  // settle those placeholders, which a later sibling reference then resolves.
  let #(providers, consumers) =
    list.partition(items, fn(item) {
      case item {
        AnnotatedDef(_, f, _, _) ->
          f.return == option.None
          || list.any(f.parameters, fn(p) { p.type_ == option.None })
        PlaceholderDef(..) -> False
      }
    })
  use st <- result.try(
    list.try_fold(list.append(providers, consumers), st, fn(st, item) {
      case item {
        AnnotatedDef(def, f, params, return_type) -> {
          // Inside its own body the function sees itself at the rigid
          // (un-generalized) signature, so a self-recursive call must be at
          // the same type — no polymorphic recursion. Bind the self-name
          // first, then the parameters on top, so a parameter that shares the
          // function's name shadows it (as in the source).
          let body_env =
            bind_params(
              define_def(group_env, def, rigid_self_scheme(params, return_type)),
              f,
              params,
            )
          check_body(body_env, st, f, return_type)
        }
        PlaceholderDef(def, var) -> {
          use #(inferred, st) <- result.try(infer_def(group_env, st, def))
          unify(st, var, inferred)
        }
      }
    }),
  )
  // The component's bodies are fully inferred, so any field accesses deferred
  // because their record type was unknown can now be resolved — before we
  // generalize, so the field types are reflected in the schemes.
  use st <- result.try(resolve_pending(group_env, st))
  let env =
    list.fold(items, env, fn(env, item) {
      case item {
        AnnotatedDef(def, _, params, return_type) ->
          define_def(env, def, function_scheme(env, st, params, return_type))
        PlaceholderDef(def, var) ->
          define_def(env, def, generalize(st, env, var))
      }
    })
  Ok(#(env, st))
}

// A member of a strongly-connected component during inference.
type GroupItem {
  // A fully-annotated function: bound at its declared scheme up front; its body
  // is checked against the signature (rigid variables).
  AnnotatedDef(
    def: Def,
    function: glance.Function,
    params: List(ty.Type),
    return_type: ty.Type,
  )
  // Any other definition: inferred monomorphically against `var`, then
  // generalized.
  PlaceholderDef(def: Def, var: ty.Type)
}

fn placeholder(
  env: Env,
  items: List(GroupItem),
  st: State,
  def: Def,
) -> #(Env, List(GroupItem), State) {
  let #(var, st) = fresh_var(st)
  #(
    define_def(env, def, ty.Scheme([], var)),
    [PlaceholderDef(def, var), ..items],
    st,
  )
}

// Pre-register one SCC member: a function with signature variables is bound at
// its declared scheme (`AnnotatedDef`); any other definition gets a fresh
// monomorphic placeholder.
fn prereg_def(
  env: Env,
  items: List(GroupItem),
  st: State,
  def: Def,
) -> #(Env, List(GroupItem), State) {
  let annotated = case def {
    FunctionDef(f) ->
      case has_annotation_vars(f) {
        True -> Ok(f)
        False -> Error(Nil)
      }
    ConstantDef(_) -> Error(Nil)
  }
  case annotated {
    Error(_) -> placeholder(env, items, st, def)
    Ok(f) -> {
      let #(params, return_type, rigid_ids, st) = signature_skeleton(env, st, f)
      #(
        define_def(env, def, rigid_scheme(rigid_ids, params, return_type)),
        [AnnotatedDef(def, f, params, return_type), ..items],
        st,
      )
    }
  }
}

// Import resolution
//
// Resolve each import to a `ModuleInterface` — from the run's cache, the
// prelude, or by inferring the imported module's source through the resolver
// — and bring its qualified alias and unqualified items into scope.

fn process_imports(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  env: Env,
  imports: List(glance.Definition(glance.Import)),
  best_effort best_effort: Bool,
) -> Result(#(Env, InterfaceCache), Error) {
  list.try_fold(imports, #(env, cache), fn(acc, definition) {
    let #(env, cache) = acc
    let import_ = definition.definition
    let path = import_.module
    // Cyclic import: break the cycle by skipping.
    use <- bool.guard(
      when: set.contains(loading, path),
      return: Ok(#(env, cache)),
    )
    use #(maybe_interface, cache) <- result.try(resolve_interface(
      options,
      loading,
      cache,
      path,
      best_effort:,
    ))
    case maybe_interface {
      // Unresolvable or unparsable: best effort, skip (uses of it surface later
      // as unbound variables).
      None -> Ok(#(env, cache))
      Some(interface) -> Ok(#(import_items(env, import_, interface), cache))
    }
  })
}

// Bring an import's qualified alias and unqualified values/types into scope.
fn import_items(
  env: Env,
  import_: glance.Import,
  interface: ModuleInterface,
) -> Env {
  // A discarded alias (`import x as _y`) imports the module for its unqualified
  // items only — it must NOT be bound under any qualified name, or we'd bind it
  // under the module's last segment and shadow a real import sharing that name
  // (mist's `gleam/http as _ghttp` vs `mist/internal/http`). Its interface is
  // still indexed by real module name: an unqualified constructor taken from it
  // builds a value whose type names that module, and the accessors for that
  // type are found through `module_index`, which is keyed by real name and so
  // cannot shadow anything. The index travels to importers as this module's
  // `reachable`, so the entry is found from further away too.
  let env = case qualified_alias(import_) {
    Ok(alias) -> import_qualified(env, alias, interface)
    Error(_) ->
      Env(..env, module_index: index_interface(env.module_index, interface))
  }
  let env =
    list.fold(import_.unqualified_values, env, fn(env, u) {
      import_value(env, option.unwrap(u.alias, u.name), interface, u.name)
    })
  list.fold(import_.unqualified_types, env, fn(env, u) {
    import_type(env, option.unwrap(u.alias, u.name), interface, u.name)
  })
}

fn resolve_interface(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  path: String,
  best_effort best_effort: Bool,
) -> Result(#(Option(ModuleInterface), InterfaceCache), Error) {
  // `import gleam` refers to the built-in prelude module, which has no source
  // file; resolve it to a synthetic interface of the prelude's types/values.
  use <- bool.lazy_guard(when: path == prelude_module, return: fn() {
    Ok(#(Some(prelude_interface()), cache))
  })
  case dict.get(cache, path) {
    // Already inferred in this run: reuse it rather than inferring again.
    Ok(interface) -> Ok(#(Some(interface), cache))
    Error(_) -> resolve_uncached(options, loading, cache, path, best_effort:)
  }
}

fn resolve_uncached(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  path: String,
  best_effort best_effort: Bool,
) -> Result(#(Option(ModuleInterface), InterfaceCache), Error) {
  case options.resolver(path) {
    Error(_) -> Ok(#(None, cache))
    Ok(source) ->
      case glance.module(source) {
        Error(_) -> Ok(#(None, cache))
        Ok(module) -> {
          // An import's own skipped definitions (best-effort) are irrelevant to
          // the importer; only its public interface, partial or not, matters.
          use inferred <- result.try(infer_module(
            options,
            set.insert(loading, path),
            cache,
            path,
            module,
            best_effort:,
          ))
          Ok(#(
            Some(inferred.interface),
            dict.insert(inferred.cache, path, inferred.interface),
          ))
        }
      }
  }
}

// The name under which an import is accessible for qualified access, or
// `Error` when the module is imported with a discarded alias (`as _x`) and so
// has no qualified name at all.
fn qualified_alias(import_: glance.Import) -> Result(String, Nil) {
  case import_.alias {
    Some(glance.Named(alias)) -> Ok(alias)
    Some(glance.Discarded(_)) -> Error(Nil)
    None -> Ok(last_segment(import_.module))
  }
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(segment) -> segment
    Error(_) -> path
  }
}

// Module interfaces
//
// Build an inferred module's public interface, and bring an imported
// interface's values, types, aliases and accessors into the environment
// (under a qualified alias, or unqualified).

// Build the public interface of an inferred module by keeping only the named
// public values and types.
fn build_interface(
  env: Env,
  st: State,
  name: String,
  value_names: List(String),
  type_names: List(String),
  accessor_type_names: List(String),
) -> ModuleInterface {
  ModuleInterface(
    name: name,
    // The scope entry each public name holds, verbatim. In best-effort mode a
    // public definition girard declined leaves the entry of whatever it
    // shadowed — an unqualified import, say — and exporting that entry whole
    // is what tells an importer the identity it was actually typed against.
    values: take(env.values, value_names),
    types: take(env.local_types, type_names),
    aliases: resolve_aliases(env, st, type_names),
    // Only non-opaque public types expose their field accessors: an opaque
    // type's fields are private to its defining module.
    accessors: take(env.accessors, accessor_type_names),
    modules: env.modules,
    reachable: env.module_index,
  )
}

// Resolve each named public alias to a concrete type, in this module's full
// environment, with the alias's parameters as variables. Resolving here (not
// when the alias is used elsewhere) keeps the bodies' type references — which
// may be imported into this module — correctly attributed.
fn resolve_aliases(
  env: Env,
  st: State,
  type_names: List(String),
) -> Dict(String, #(List(Int), ty.Type)) {
  list.fold(type_names, #(dict.new(), st), fn(acc, name) {
    let #(resolved, st) = acc
    case dict.get(env.aliases, name) {
      Error(_) -> #(resolved, st)
      Ok(#(params, body)) -> {
        let #(param_vars, st) = fresh_n(st, list.length(params))
        let param_ids = list.filter_map(param_vars, var_id)
        let names = dict.from_list(list.zip(params, param_vars))
        let #(type_, st) = hydrate_in(env, names, st, body)
        #(dict.insert(resolved, name, #(param_ids, type_)), st)
      }
    }
  }).0
}

// Instantiate a resolved alias `#(param ids, body)` with concrete arguments.
fn instantiate_alias(
  params: List(Int),
  body: ty.Type,
  arguments: List(ty.Type),
) -> ty.Type {
  substitute(dict.from_list(list.zip(params, arguments)), body)
}

fn take(d: Dict(String, v), keys: List(String)) -> Dict(String, v) {
  list.fold(keys, dict.new(), fn(acc, key) {
    case dict.get(d, key) {
      Ok(value) -> dict.insert(acc, key, value)
      Error(_) -> acc
    }
  })
}

// Make a module available for qualified access (`alias.value`/`alias.Type`).
fn import_qualified(
  env: Env,
  alias: String,
  interface: ModuleInterface,
) -> Env {
  // Bring the module's own imports along (under their aliases, but not
  // overriding the importer's direct imports) so types it exposes from other
  // modules keep their accessors reachable. Then bind the module itself.
  let modules =
    dict.fold(env.modules, interface.modules, fn(acc, alias, interface) {
      dict.insert(acc, alias, interface)
    })
  Env(
    ..env,
    modules: dict.insert(modules, alias, interface),
    // Index the newly reachable interfaces by real name. The bound interface's
    // transitive closure covers everything merged in above (each merged module
    // is itself within that closure), so one walk keeps the index complete.
    module_index: index_interface(env.module_index, interface),
  )
}

// Add `interface` and every interface it transitively exposes to `index`,
// keyed by real module name. First insert wins (a name already present is left
// as-is), which both guards the DAG against re-walking shared modules and is
// unambiguous: a real module name resolves to one inferred interface per run.
//
// `reachable` is what carries the transitive half, rather than a walk over
// `modules`: `modules` is keyed by the alias a module was imported under, so a
// discard-aliased import is missing from it and everything only that import
// could reach would be unreachable from here.
fn index_interface(
  index: Dict(String, ModuleInterface),
  interface: ModuleInterface,
) -> Dict(String, ModuleInterface) {
  // Already indexed: stop. Guards the DAG against re-walking shared modules.
  use <- bool.guard(when: dict.has_key(index, interface.name), return: index)
  let index = dict.insert(index, interface.name, interface)
  dict.fold(interface.reachable, index, fn(acc, name, nested) {
    case dict.has_key(acc, name) {
      True -> acc
      False -> dict.insert(acc, name, nested)
    }
  })
}

// Bring a single value (function/constant/constructor) into scope unqualified.
fn import_value(
  env: Env,
  local: String,
  interface: ModuleInterface,
  original: String,
) -> Env {
  // The entry is copied verbatim, so the identity it carries stays the one it
  // was declared under — the exporting module's real path and the name the
  // value has *there*, never the alias it reached this module under. Through
  // `install_entry` rather than a raw insert, so `open_values` is maintained
  // from the entry's own scheme like every other write.
  case dict.get(interface.values, original) {
    Error(_) -> env
    Ok(entry) -> install_entry(env, local, entry)
  }
}

// Bring a single type into scope unqualified.
fn import_type(
  env: Env,
  local: String,
  interface: ModuleInterface,
  original: String,
) -> Env {
  let env = case dict.get(interface.types, original) {
    Ok(info) ->
      Env(..env, local_types: dict.insert(env.local_types, local, info))
    Error(_) -> env
  }
  let env = case dict.get(interface.aliases, original) {
    Ok(alias) ->
      Env(
        ..env,
        imported_aliases: dict.insert(env.imported_aliases, local, alias),
      )
    Error(_) -> env
  }
  case dict.get(interface.accessors, original) {
    Ok(accessors) ->
      Env(..env, accessors: dict.insert(env.accessors, local, accessors))
    Error(_) -> env
  }
}

// Target filtering and public surface
//
// Drop definitions and imports compiled for the other build target, and
// collect the names of a module's public values, types and field-accessor
// types for its interface.

// Keep only the definitions and imports compiled for `target`: those with no
// `@target` attribute, or one naming the active target. A definition annotated
// for the other target is dropped, exactly as the compiler omits it.
//
// The dropped functions and constants come back with the filtered module, to
// be published: they are the definitions that hold expressions, so they are
// the ones a consumer can find a span inside and no annotation at. A dropped
// import, custom type or alias has no body, so its absence needs no
// explanation and none is reported.
fn for_target(
  module: glance.Module,
  target: Target,
) -> #(glance.Module, List(Dropped)) {
  let #(functions, dropped_functions) =
    list.partition(module.functions, on_target(_, target))
  let #(constants, dropped_constants) =
    list.partition(module.constants, on_target(_, target))
  let module =
    glance.Module(
      imports: list.filter(module.imports, on_target(_, target)),
      custom_types: list.filter(module.custom_types, on_target(_, target)),
      type_aliases: list.filter(module.type_aliases, on_target(_, target)),
      constants:,
      functions:,
    )
  // glance keeps functions and constants in separate lists, so concatenating
  // the two is per-category order; the span sort restores source order, which
  // is what an interleaved pair was written in.
  let dropped =
    list.append(
      list.map(dropped_functions, fn(d) {
        Dropped(d.definition.name, d.definition.location)
      }),
      list.map(dropped_constants, fn(d) {
        Dropped(d.definition.name, d.definition.location)
      }),
    )
  #(module, sort_dropped(dropped))
}

fn on_target(definition: glance.Definition(a), target: Target) -> Bool {
  let active = case target {
    Erlang -> "erlang"
    JavaScript -> "javascript"
  }
  list.all(definition.attributes, fn(attr) {
    case attr.name, attr.arguments {
      "target", [glance.Variable(_, t)] -> t == active
      _, _ -> True
    }
  })
}

fn public_value_names(module: glance.Module) -> List(String) {
  let functions =
    list.filter_map(module.functions, fn(d) {
      case d.definition.publicity {
        glance.Public -> Ok(d.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  let constants =
    list.filter_map(module.constants, fn(d) {
      case d.definition.publicity {
        glance.Public -> Ok(d.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  // Constructors of public, non-opaque types are public values.
  let constructors =
    list.flat_map(module.custom_types, fn(d) {
      let ct = d.definition
      case ct.publicity, ct.opaque_ {
        glance.Public, False -> list.map(ct.variants, fn(v) { v.name })
        _, _ -> []
      }
    })
  list.flatten([functions, constants, constructors])
}

fn public_type_names(module: glance.Module) -> List(String) {
  let types =
    list.filter_map(module.custom_types, fn(d) {
      case d.definition.publicity {
        glance.Public -> Ok(d.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  let aliases =
    list.filter_map(module.type_aliases, fn(d) {
      case d.definition.publicity {
        glance.Public -> Ok(d.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  list.append(types, aliases)
}

// Public types whose field accessors are reachable from other modules: public,
// non-opaque custom types. An `opaque` type's fields are private to its
// defining module, so its accessors are not exported — a same-named module
// function then wins over the inaccessible field at an external call site, as
// with an opaque `Schema` that has both a private `decode` field and a public
// `decode` function.
fn public_accessor_type_names(module: glance.Module) -> List(String) {
  list.filter_map(module.custom_types, fn(d) {
    case d.definition.publicity, d.definition.opaque_ {
      glance.Public, False -> Ok(d.definition.name)
      _, _ -> Error(Nil)
    }
  })
}

// Substitution
//
// Resolve a variable to its head constructor, fully apply the substitution
// (`zonk`), and collect free variables — treating a scheme's own quantified
// variables as opaque.

// Follow bound variables one level to expose the head constructor.
fn resolve(st: State, type_: ty.Type) -> ty.Type {
  case type_ {
    ty.Var(id) ->
      case dict.get(st.subst, id) {
        Ok(bound) -> resolve(st, bound)
        Error(_) -> type_
      }
    _ -> type_
  }
}

// Fully apply the substitution, leaving only unbound variables as `Var`.
fn zonk(st: State, type_: ty.Type) -> ty.Type {
  case resolve(st, type_) {
    ty.Named(module, name, args, variant) ->
      ty.Named(module, name, list.map(args, zonk(st, _)), variant)
    ty.Fn(args, ret) -> ty.Fn(list.map(args, zonk(st, _)), zonk(st, ret))
    ty.Tuple(elements) -> ty.Tuple(list.map(elements, zonk(st, _)))
    ty.Var(id) -> ty.Var(id)
  }
}

fn free_vars(st: State, type_: ty.Type) -> List(Int) {
  free_vars_loop(zonk(st, type_), [])
}

fn free_vars_loop(type_: ty.Type, acc: List(Int)) -> List(Int) {
  case type_ {
    ty.Var(id) ->
      case list.contains(acc, id) {
        True -> acc
        False -> [id, ..acc]
      }
    ty.Named(_, _, args, _) ->
      list.fold(args, acc, fn(a, t) { free_vars_loop(t, a) })
    ty.Fn(args, ret) ->
      free_vars_loop(
        ret,
        list.fold(args, acc, fn(a, t) { free_vars_loop(t, a) }),
      )
    ty.Tuple(elements) ->
      list.fold(elements, acc, fn(a, t) { free_vars_loop(t, a) })
  }
}

fn env_free_vars(st: State, env: Env) -> List(Int) {
  // Only open bindings can contribute; closed schemes (the bulk — every import
  // and generalized definition) are omitted from `open_values`, so this scans a
  // handful of live monomorphic bindings rather than the whole environment.
  dict.fold(env.open_values, [], fn(acc, _name, scheme) {
    // A scheme's quantified variables are bound *within the scheme*; they must
    // not be resolved against the ambient substitution. This matters because
    // imported schemes carry variable ids minted in their own module, which can
    // collide with — and have since been bound to unrelated types by — the
    // importing module's substitution. Treating them as opaque (rather than
    // zonking them) keeps such collisions from leaking phantom free variables
    // that would wrongly block generalization here.
    scheme_free_vars(st, scheme.type_, scheme.vars, acc)
  })
}

// Free variables of `type_`, treating `bound` ids as opaque: a bound id
// contributes nothing and is never resolved through the substitution, while a
// free id is resolved and its remaining variables collected.
fn scheme_free_vars(
  st: State,
  type_: ty.Type,
  bound: List(Int),
  acc: List(Int),
) -> List(Int) {
  case type_ {
    ty.Var(id) ->
      case list.contains(bound, id) {
        True -> acc
        False ->
          case resolve(st, type_) {
            ty.Var(resolved) ->
              case list.contains(acc, resolved) {
                True -> acc
                False -> [resolved, ..acc]
              }
            other -> scheme_free_vars(st, other, bound, acc)
          }
      }
    ty.Named(_, _, args, _) ->
      list.fold(args, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) })
    ty.Fn(args, ret) ->
      scheme_free_vars(
        st,
        ret,
        bound,
        list.fold(args, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) }),
      )
    ty.Tuple(elements) ->
      list.fold(elements, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) })
  }
}

// Inferred variants
//
// The variant a value is known to have been built with, carried on the
// inference-side `Named`. A constructor's return type is stamped with its
// index; binding a type variable to a type erases the variant of what it is
// bound to, and generalizing a top-level definition erases every variant in
// its type. The compiler's `set_custom_type_variant` and
// `generalise_custom_type_variant`.

// Mark a type as known to be its `variant`th constructor. Named types only,
// through a bound variable; functions and tuples carry no variant, so they are
// returned as they are.
fn stamp(st: State, type_: ty.Type, variant: Int) -> ty.Type {
  case resolve(st, type_) {
    ty.Named(module, name, args, _) ->
      ty.Named(module, name, args, Some(variant))
    other -> other
  }
}

// The variant a (resolved) type is known to have been built with.
fn variant_of(type_: ty.Type) -> Option(Int) {
  case type_ {
    ty.Named(_, _, _, variant) -> variant
    _ -> None
  }
}

// Forget which variant a value was built with, as happens when it is bound to
// a type variable. It reaches through functions and tuples but *not* into a
// named type's arguments: a `List(Loud)` still knows its elements are `Loud`.
// No substitution walk is needed — the type arrives resolved, and anything
// reachable through a bound variable below it was itself erased when that
// variable was bound.
fn erase_variant(type_: ty.Type) -> ty.Type {
  case type_ {
    ty.Named(module, name, args, _) -> ty.Named(module, name, args, None)
    ty.Fn(args, ret) -> ty.Fn(list.map(args, erase_variant), erase_variant(ret))
    ty.Tuple(elements) -> ty.Tuple(list.map(elements, erase_variant))
    ty.Var(_) -> type_
  }
}

// Erase every variant at every depth, arguments included. This is the erase a
// top-level definition's generalization performs, where `erase_variant`'s
// shallower reach is the one a variable binding performs.
fn erase_all(type_: ty.Type) -> ty.Type {
  case type_ {
    ty.Named(module, name, args, _) ->
      ty.Named(module, name, list.map(args, erase_all), None)
    ty.Fn(args, ret) -> ty.Fn(list.map(args, erase_all), erase_all(ret))
    ty.Tuple(elements) -> ty.Tuple(list.map(elements, erase_all))
    ty.Var(_) -> type_
  }
}

// Unification
//
// Unify two types, binding flexible variables and rejecting rigid ones, with
// the occurs check that guards against infinite types.

fn unify(st: State, left: ty.Type, right: ty.Type) -> Result(State, Error) {
  let left = resolve(st, left)
  let right = resolve(st, right)
  case left, right {
    ty.Var(i), ty.Var(j) if i == j -> Ok(st)
    // A rigid variable never binds; a flexible one may bind to it. Two distinct
    // rigid variables, or a rigid variable against a concrete type, mismatch.
    ty.Var(i), ty.Var(j) ->
      case is_rigid(st, i), is_rigid(st, j) {
        True, True -> Error(type_mismatch(left, right))
        True, False -> bind_var(st, j, left)
        False, _ -> bind_var(st, i, right)
      }
    ty.Var(i), other ->
      case is_rigid(st, i) {
        True -> Error(type_mismatch(left, right))
        False -> bind_var(st, i, other)
      }
    other, ty.Var(j) ->
      case is_rigid(st, j) {
        True -> Error(type_mismatch(left, right))
        False -> bind_var(st, j, other)
      }

    ty.Named(m1, n1, a1, _), ty.Named(m2, n2, a2, _) if m1 == m2 && n1 == n2 ->
      unify_many(st, a1, a2)

    ty.Fn(args1, r1), ty.Fn(args2, r2) -> {
      use st <- result.try(unify_many(st, args1, args2))
      unify(st, r1, r2)
    }

    ty.Tuple(e1), ty.Tuple(e2) -> unify_many(st, e1, e2)

    _, _ -> Error(type_mismatch(left, right))
  }
}

fn unify_many(
  st: State,
  left: List(ty.Type),
  right: List(ty.Type),
) -> Result(State, Error) {
  case left, right {
    [], [] -> Ok(st)
    [x, ..xs], [y, ..ys] -> {
      use st <- result.try(unify(st, x, y))
      unify_many(st, xs, ys)
    }
    _, _ -> Error(ArityMismatch)
  }
}

fn bind_var(st: State, id: Int, type_: ty.Type) -> Result(State, Error) {
  use <- bool.lazy_guard(when: occurs(st, id, type_), return: fn() {
    Error(recursive_type(id, type_))
  })
  // A value bound to a type variable is no longer known to be any one variant:
  // this is the compiler's erase, in the one place a variable is ever bound.
  Ok(State(..st, subst: dict.insert(st.subst, id, erase_variant(type_))))
}

fn occurs(st: State, id: Int, type_: ty.Type) -> Bool {
  list.contains(free_vars(st, type_), id)
}

// Generalization and instantiation
//
// Generalize a type into a scheme at a definition boundary — quantifying
// variables free in the type but not the environment — and instantiate a
// scheme back to a monotype with fresh variables.

fn generalize(st: State, env: Env, type_: ty.Type) -> ty.Scheme {
  // A generalized definition is used at types its body never saw, so nothing
  // it returns is known to be one variant any more.
  let zonked = erase_all(zonk(st, type_))
  let env_vars = env_free_vars(st, env)
  let quantified =
    list.filter(free_vars(st, zonked), fn(id) { !list.contains(env_vars, id) })
  ty.Scheme(quantified, zonked)
}

// Generalize a type over a specific set of candidate variable ids only (the
// rest stay monomorphic). Used for a `let`-bound function, which Gleam makes
// polymorphic over exactly the type variables written in its annotations.
fn generalize_over(
  st: State,
  env: Env,
  type_: ty.Type,
  candidate_ids: List(Int),
) -> ty.Scheme {
  let zonked = zonk(st, type_)
  let env_vars = env_free_vars(st, env)
  let free = free_vars(st, zonked)
  // Each annotation var may have been unified with another; follow it to its
  // representative and keep it only if it is still a free variable of the type.
  let reps =
    list.filter_map(candidate_ids, fn(id) {
      case zonk(st, ty.Var(id)) {
        ty.Var(rep) -> Ok(rep)
        _ -> Error(Nil)
      }
    })
  let quantified =
    list.unique(
      list.filter(reps, fn(id) {
        list.contains(free, id) && !list.contains(env_vars, id)
      }),
    )
  ty.Scheme(quantified, zonked)
}

// The type-variable names written in a `fn`'s parameter and return annotations.
fn fn_annotation_var_names(
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
) -> List(String) {
  let from_params =
    list.flat_map(params, fn(p) {
      case p.type_ {
        Some(t) -> type_var_names(t)
        None -> []
      }
    })
  case return_annotation {
    Some(t) -> list.append(from_params, type_var_names(t))
    None -> from_params
  }
}

fn type_var_names(ast: glance.Type) -> List(String) {
  case ast {
    glance.VariableType(_, name) -> [name]
    glance.NamedType(_, _, _, parameters) ->
      list.flat_map(parameters, type_var_names)
    glance.TupleType(_, elements) -> list.flat_map(elements, type_var_names)
    glance.FunctionType(_, parameters, return) ->
      list.append(
        list.flat_map(parameters, type_var_names),
        type_var_names(return),
      )
    glance.HoleType(..) -> []
  }
}

// Instantiate a scheme by replacing each quantified variable with a fresh one.
fn instantiate(st: State, scheme: ty.Scheme) -> #(ty.Type, State) {
  let #(mapping, st) =
    list.fold(scheme.vars, #(dict.new(), st), fn(acc, old) {
      let #(mapping, st) = acc
      let #(fresh_type, st) = fresh(st)
      #(dict.insert(mapping, old, fresh_type), st)
    })
  #(substitute(mapping, scheme.type_), st)
}

// Instantiate `name`'s scheme. For a live SCC member, resolve its type through
// the current substitution first, so a variable the provider's body has since
// settled (e.g. an unannotated parameter absorbed into a quantified signature
// variable) is reflected — and then freshened along with the quantified set,
// exactly as the compiler's shared mutable cells propagate to a sibling. For
// any other binding the scheme is already final, so this is plain instantiate.
fn instantiate_in(
  env: Env,
  st: State,
  name: String,
  scheme: ty.Scheme,
) -> #(ty.Type, State) {
  case set.contains(env.live, name) {
    True -> instantiate(st, ty.Scheme(scheme.vars, zonk(st, scheme.type_)))
    False -> instantiate(st, scheme)
  }
}

fn substitute(mapping: Dict(Int, ty.Type), type_: ty.Type) -> ty.Type {
  case type_ {
    ty.Var(id) ->
      case dict.get(mapping, id) {
        Ok(replacement) -> replacement
        Error(_) -> type_
      }
    ty.Named(module, name, args, variant) ->
      ty.Named(module, name, list.map(args, substitute(mapping, _)), variant)
    ty.Fn(args, ret) ->
      ty.Fn(list.map(args, substitute(mapping, _)), substitute(mapping, ret))
    ty.Tuple(elements) -> ty.Tuple(list.map(elements, substitute(mapping, _)))
  }
}

// Top-level definitions
//
// Infer a top-level function or constant and register a custom type's
// constructors and accessors, then resolve the field and tuple accesses
// deferred until inference fixed their container types.

// Whether a function's signature names any type variable. The compiler makes
// such a variable rigid for the body and keeps the function polymorphic over it
// in its own recursion / SCC (rather than inferring it monomorphically against
// a placeholder, which would pin a phantom parameter). A function with only
// concrete annotations, or none, takes the ordinary placeholder path.
fn has_annotation_vars(function: glance.Function) -> Bool {
  function_annotation_var_names(function) != []
}

fn function_annotation_var_names(function: glance.Function) -> List(String) {
  let from_params =
    list.flat_map(function.parameters, fn(p) {
      case p.type_ {
        Some(t) -> type_var_names(t)
        None -> []
      }
    })
  case function.return {
    Some(t) -> list.append(from_params, type_var_names(t))
    None -> from_params
  }
}

// Hydrate a function's signature into a *skeleton*: each annotated part uses
// its written type with the signature's type variables made rigid (skolemized)
// for the body; each unannotated part is a fresh flexible variable (inferred
// and shared monomorphically, like a placeholder). Returns the parameter types,
// return type, and the ids made rigid; those ids are also recorded in `State`.
fn signature_skeleton(
  env: Env,
  st: State,
  function: glance.Function,
) -> #(List(ty.Type), ty.Type, List(Int), State) {
  // One rigid id per distinct annotation variable name, shared across the whole
  // signature (so a parameter `a` and the return `a` are the same variable).
  let #(names, rigid_ids, st) =
    list.fold(
      list.unique(function_annotation_var_names(function)),
      #(dict.new(), [], st),
      fn(acc, name) {
        let #(names, ids, st) = acc
        let #(id, st) = fresh_id(st)
        #(dict.insert(names, name, ty.Var(id)), [id, ..ids], st)
      },
    )
  let st = mark_rigid(st, rigid_ids)
  let #(rev_param_types, st) =
    list.fold(function.parameters, #([], st), fn(acc, param) {
      let #(types_, st) = acc
      let #(t, st) = case param.type_ {
        Some(ann) -> hydrate_in(env, names, st, ann)
        None -> fresh(st)
      }
      #([t, ..types_], st)
    })
  let #(return_type, st) = case function.return {
    Some(ann) -> hydrate_in(env, names, st, ann)
    None -> fresh(st)
  }
  #(list.reverse(rev_param_types), return_type, rigid_ids, st)
}

// Bind a function's parameters to the given types in `env`.
fn bind_params(
  env: Env,
  function: glance.Function,
  param_types: List(ty.Type),
) -> Env {
  list.fold(list.zip(function.parameters, param_types), env, fn(env, pair) {
    let #(param, t) = pair
    case param.name {
      glance.Named(name) -> bind_local(env, name, ty.Scheme([], t))
      glance.Discarded(_) -> env
    }
  })
}

// Infer a fully-annotated function's body and check it against the declared
// return type. `@external` functions have no body and pass trivially.
fn check_body(
  env: Env,
  st: State,
  function: glance.Function,
  return_type: ty.Type,
) -> Result(State, Error) {
  case function.body {
    [] -> Ok(st)
    _ -> {
      use #(body_type, st) <- result.try(infer_statements(
        env,
        st,
        function.body,
      ))
      unify(st, body_type, return_type)
    }
  }
}

// The scheme a function with signature variables is bound at within its SCC:
// polymorphic over its rigid signature variables, but with any unannotated
// (flexible placeholder) parts left free, so they stay shared/monomorphic
// across the component until the body fixes them.
fn rigid_scheme(
  rigid_ids: List(Int),
  param_types: List(ty.Type),
  return_type: ty.Type,
) -> ty.Scheme {
  ty.Scheme(rigid_ids, ty.Fn(param_types, return_type))
}

// Generalize a function's final parameter/return types into a scheme,
// quantifying every variable still free after the body is inferred.
fn function_scheme(
  env: Env,
  st: State,
  param_types: List(ty.Type),
  return_type: ty.Type,
) -> ty.Scheme {
  generalize(st, env, ty.Fn(param_types, return_type))
}

// The *monomorphic* scheme a fully-annotated function sees for itself inside
// its own body. Its signature variables stay rigid (un-quantified), so a
// self-recursive call must be at the same type — Gleam has no polymorphic
// recursion, and recursing at a concrete type where the signature is generic
// is a mismatch, exactly as the compiler reports.
fn rigid_self_scheme(
  param_types: List(ty.Type),
  return_type: ty.Type,
) -> ty.Scheme {
  ty.Scheme([], ty.Fn(param_types, return_type))
}

// Infer a top-level function, returning its (still ungeneralized) `Fn` type.
fn infer_function(
  env: Env,
  st: State,
  function: glance.Function,
) -> Result(#(ty.Type, State), Error) {
  // Type-variable names are shared across the whole signature so that, e.g.,
  // a parameter `a` and the return `a` refer to the same variable.
  let #(rev_param_types, body_env, st, names) =
    list.fold(function.parameters, #([], env, st, dict.new()), fn(acc, param) {
      let #(types_, env, st, names) = acc
      let #(t, st, names) = case param.type_ {
        Some(ann) -> hydrate_threaded(env, names, st, ann)
        None -> {
          let #(t, st) = fresh(st)
          #(t, st, names)
        }
      }
      let env = case param.name {
        glance.Named(name) -> bind_local(env, name, ty.Scheme([], t))
        glance.Discarded(_) -> env
      }
      #([t, ..types_], env, st, names)
    })
  let param_types = list.reverse(rev_param_types)
  case function.body {
    // External functions (e.g. `@external`) have no body; their type comes
    // entirely from the signature annotations.
    [] -> {
      let #(return_type, st) = case function.return {
        Some(ann) -> {
          let #(t, st, _names) = hydrate_threaded(env, names, st, ann)
          #(t, st)
        }
        None -> fresh(st)
      }
      Ok(#(ty.Fn(param_types, return_type), st))
    }
    _ -> {
      use #(body_type, st) <- result.try(infer_statements(
        body_env,
        st,
        function.body,
      ))
      use st <- result.try(case function.return {
        Some(ann) -> {
          let #(t, st, _names) = hydrate_threaded(env, names, st, ann)
          unify(st, body_type, t)
        }
        None -> Ok(st)
      })
      Ok(#(ty.Fn(param_types, body_type), st))
    }
  }
}

// Infer a module constant, returning its type (an annotation, if present, is
// applied).
fn infer_constant(
  env: Env,
  st: State,
  constant: glance.Constant,
) -> Result(#(ty.Type, State), Error) {
  use #(value_type, st) <- result.try(infer_expr(env, st, constant.value))
  case constant.annotation {
    Some(ann) -> {
      let #(t, st) = hydrate(env, st, ann)
      use st <- result.try(unify(st, value_type, t))
      Ok(#(value_type, st))
    }
    None -> Ok(#(value_type, st))
  }
}

// Register a custom type's constructors as value schemes in the environment,
// generalized over the type's parameters.
fn register_custom_type(
  env: Env,
  st: State,
  custom_type: glance.CustomType,
) -> #(Env, State) {
  // Record the type as local first so its own fields can refer to it.
  let env =
    declare_type(env, custom_type.name, list.length(custom_type.parameters))
  let #(rev_param_ids, st) =
    list.fold(custom_type.parameters, #([], st), fn(acc, _name) {
      let #(ids, st) = acc
      let #(id, st) = fresh_id(st)
      #([id, ..ids], st)
    })
  let param_ids = list.reverse(rev_param_ids)
  let param_vars = list.map(param_ids, ty.Var)
  let names = dict.from_list(list.zip(custom_type.parameters, param_vars))
  let return_type =
    ty.Named(env.current_module, custom_type.name, param_vars, None)

  // Build constructors, keeping each variant's fields in declaration order
  // (label and type per position) so we can later expose accessors for labels
  // shared across all variants.
  let #(env, st, rev_variant_fields) =
    list.index_fold(
      custom_type.variants,
      #(env, st, []),
      fn(acc, variant, index) {
        let #(env, st, variant_fields) = acc
        let #(rev_fields, st) =
          list.fold(variant.fields, #([], st), fn(acc, field) {
            let #(fields, st) = acc
            let #(t, st) = hydrate_in(env, names, st, variant_field_type(field))
            let label = case field {
              glance.LabelledVariantField(_, label) -> Some(label)
              glance.UnlabelledVariantField(..) -> None
            }
            #([#(label, t), ..fields], st)
          })
        let fields = list.reverse(rev_fields)
        let #(labels, field_types) = list.unzip(fields)
        // A constructor's return type is known to be that constructor, so
        // construction narrows with nothing else having to notice.
        let built = stamp(st, return_type, index)
        let ctor_type = case field_types {
          [] -> built
          _ -> ty.Fn(field_types, built)
        }
        let env =
          install(
            env,
            variant.name,
            ty.Scheme(param_ids, ctor_type),
            ConstructorValue(
              env.current_module,
              variant.name,
              field_map_of(labels),
            ),
          )
        #(env, st, [fields, ..variant_fields])
      },
    )

  // A label is shared iff every variant declares it at the same position with
  // the same type. (Single-variant records are the degenerate case where every
  // label qualifies.) A value known to be one variant reads that variant's own
  // map instead, where every label it declares qualifies.
  let variant_fields = list.reverse(rev_variant_fields)
  let shared = shared_accessors(variant_fields, param_ids, return_type)
  let accessors =
    Accessors(shared:, by_variant: case variant_fields {
      // Every label of a single-variant type is shared, so the two maps are
      // the same one and the type keeps one copy.
      [_] -> [shared]
      _ ->
        list.map(variant_fields, variant_accessors(_, param_ids, return_type))
    })
  let env =
    Env(
      ..env,
      accessors: dict.insert(env.accessors, custom_type.name, accessors),
    )
  #(env, st)
}

// Accessor schemes for the labels every variant declares at the same position
// with the same type, given each variant's fields in declaration order. This
// is the compiler's `get_compatible_record_fields`: it walks the first
// variant's labelled fields by index and keeps a label only when every other
// variant has that label, with that type, at that index.
fn shared_accessors(
  variants: List(List(#(Option(String), ty.Type))),
  param_ids: List(Int),
  return_type: ty.Type,
) -> Dict(String, ty.Scheme) {
  case variants {
    [] -> dict.new()
    [first, ..rest] ->
      list.index_fold(first, dict.new(), fn(accessors, field, index) {
        let shared =
          list.all(rest, fn(variant) { list_at(variant, index) == Ok(field) })
        case field, shared {
          #(Some(label), field_type), True ->
            dict.insert(
              accessors,
              label,
              ty.Scheme(param_ids, ty.Fn([return_type], field_type)),
            )
          _, _ -> accessors
        }
      })
  }
}

// Accessor schemes for one variant's own labelled fields. This is the
// compiler's `custom_type_accessors`: a value known to be this variant reads
// every label the variant declares, shared with the others or not. The
// argument type is the *unstamped* return type, so a stamped record still
// unifies with it.
fn variant_accessors(
  fields: List(#(Option(String), ty.Type)),
  param_ids: List(Int),
  return_type: ty.Type,
) -> Dict(String, ty.Scheme) {
  list.fold(fields, dict.new(), fn(accessors, field) {
    case field {
      #(Some(label), field_type) ->
        dict.insert(
          accessors,
          label,
          ty.Scheme(param_ids, ty.Fn([return_type], field_type)),
        )
      #(None, _) -> accessors
    }
  })
}

// Look up the accessor scheme for `label` on a (resolved) record type. The
// accessors live with whichever module defined the type — the current module,
// or an imported one identified by the type's origin module.
fn accessor(
  env: Env,
  record: ty.Type,
  label: String,
) -> Result(ty.Scheme, Error) {
  case record {
    ty.Named(module, name, _, variant) -> {
      let accessors = accessors_of_module(env, module)
      case dict.get(accessors, name) {
        Ok(found) ->
          case dict.get(accessors_for_variant(found, variant), label) {
            Ok(scheme) -> Ok(scheme)
            Error(_) -> Error(NoSuchField(name, label))
          }
        Error(_) -> Error(NoSuchField(name, label))
      }
    }
    _ -> Error(NotARecord)
  }
}

// The accessors a record grants: the known variant's own where the value is
// known to be one, else the labels every variant shares. A variant's map is
// the whole answer, not an addition to the shared one, so a value known to be
// a variant that does not declare the label has no accessor for it. An index
// out of range falls back to the shared map, as the compiler's
// `accessors_for_variant` does.
fn accessors_for_variant(
  accessors: Accessors,
  variant: Option(Int),
) -> Dict(String, ty.Scheme) {
  case variant {
    Some(index) ->
      result.unwrap(list_at(accessors.by_variant, index), accessors.shared)
    None -> accessors.shared
  }
}

fn accessors_of_module(env: Env, module: String) -> Dict(String, Accessors) {
  // A type can surface from a module the current one never imports directly (a
  // helper returning another module's record), and an alias collision can evict
  // that module from the alias-keyed `modules` map — so resolve by origin name
  // through `module_index`, which holds the whole transitively-reachable graph.
  case module == env.current_module {
    True -> env.accessors
    False ->
      case dict.get(env.module_index, module) {
        Ok(interface) -> interface.accessors
        Error(_) -> env.accessors
      }
  }
}

// Resolve field accesses that were deferred because the record type was
// unknown when first seen. By now inference has fixed the record types; any
// that are still unknown are genuinely ambiguous (the compiler rejects these
// too).
fn resolve_pending(env: Env, st: State) -> Result(State, Error) {
  // Process in discovery order so inner accesses of a chain (`a.b.c`) resolve
  // before the outer ones, and loop to a fixpoint for any remaining cross
  // dependencies. Anything still unresolved is genuinely ambiguous.
  let pending = list.reverse(st.pending)
  resolve_pending_loop(
    env,
    State(..st, pending: []),
    pending,
    list.length(pending),
  )
}

fn resolve_pending_loop(
  env: Env,
  st: State,
  pending: List(Pending),
  fuel: Int,
) -> Result(State, Error) {
  case pending, fuel <= 0 {
    [], _ -> Ok(st)
    [_, ..], True -> Error(NotARecord)
    _, False -> {
      use #(st, remaining, progressed) <- result.try(
        list.try_fold(pending, #(st, [], False), fn(acc, item) {
          let #(st, remaining, progressed) = acc
          use #(st, resolved) <- result.try(resolve_one(env, st, item))
          case resolved {
            True -> Ok(#(st, remaining, True))
            False -> Ok(#(st, [item, ..remaining], progressed))
          }
        }),
      )
      case progressed {
        True -> resolve_pending_loop(env, st, list.reverse(remaining), fuel - 1)
        False -> Error(NotARecord)
      }
    }
  }
}

// Try to resolve one deferred access. Returns `#(state, resolved?)`: `False`
// means the container is still an unbound variable, so keep it for a later
// pass. A container fixed to the wrong shape is a hard error.
fn resolve_one(
  env: Env,
  st: State,
  item: Pending,
) -> Result(#(State, Bool), Error) {
  case item {
    PendingField(container, label, field) ->
      case resolve(st, container) {
        ty.Named(_, _, _, _) as record -> {
          use scheme <- result.try(accessor(env, record, label))
          let #(accessor_type, st) = instantiate(st, scheme)
          use st <- result.try(unify(
            st,
            accessor_type,
            ty.Fn([container], field),
          ))
          Ok(#(st, True))
        }
        ty.Var(_) -> Ok(#(st, False))
        _ -> Error(NotARecord)
      }
    PendingIndex(container, index, result) ->
      case resolve(st, container) {
        ty.Tuple(elements) ->
          case list_at(elements, index) {
            Ok(element) -> {
              use st <- result.try(unify(st, element, result))
              Ok(#(st, True))
            }
            Error(_) -> Error(TupleIndexOutOfRange(index))
          }
        ty.Var(_) -> Ok(#(st, False))
        _ -> Error(NotATuple)
      }
  }
}

fn variant_field_type(field: glance.VariantField) -> glance.Type {
  case field {
    glance.LabelledVariantField(item, _label) -> item
    glance.UnlabelledVariantField(item) -> item
  }
}

// Expression inference
//
// Infer the type of every expression: literals, variables, calls and
// captures, operators and pipes, field access and record updates, tuples,
// lists, lambdas, blocks and bit arrays — with the reordering that labelled
// and shorthand arguments need to reach their declared positions.

fn infer_expr(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(ty.Type, State), Error) {
  use #(type_, st) <- result.try(infer_expr_inner(env, st, expr))
  Ok(#(type_, record(st, span(expr), type_)))
}

fn infer_expr_inner(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(ty.Type, State), Error) {
  case expr {
    glance.Int(..) -> Ok(#(prelude_int(), st))
    glance.Float(..) -> Ok(#(prelude_float(), st))
    glance.String(..) -> Ok(#(prelude_string(), st))

    glance.Variable(_, name) ->
      case lookup(env, name) {
        Ok(scheme) -> Ok(instantiate_in(env, st, name, scheme))
        Error(_) -> Error(UnboundVariable(name))
      }

    glance.NegateInt(_, value) -> {
      use #(t, st) <- result.try(infer_expr(env, st, value))
      use st <- result.try(unify(st, t, prelude_int()))
      Ok(#(prelude_int(), st))
    }

    glance.NegateBool(_, value) -> {
      use #(t, st) <- result.try(infer_expr(env, st, value))
      use st <- result.try(unify(st, t, prelude_bool()))
      Ok(#(prelude_bool(), st))
    }

    glance.Tuple(_, elements) -> {
      use #(elem_types, st) <- result.try(infer_each(env, st, elements))
      Ok(#(ty.Tuple(elem_types), st))
    }

    glance.List(_, elements, rest) -> {
      let #(elem, st) = fresh(st)
      use st <- result.try(
        list.try_fold(elements, st, fn(st, e) {
          use #(t, st) <- result.try(infer_expr(env, st, e))
          unify(st, t, elem)
        }),
      )
      use st <- result.try(case rest {
        Some(r) -> {
          use #(t, st) <- result.try(infer_expr(env, st, r))
          unify(st, t, prelude_list(elem))
        }
        None -> Ok(st)
      })
      Ok(#(prelude_list(elem), st))
    }

    glance.Fn(_, params, return_annotation, body) ->
      infer_fn(env, st, params, return_annotation, body)

    glance.Call(span, function, arguments) ->
      infer_call(env, st, span, function, arguments)

    glance.FnCapture(span, label, function, before, after) ->
      infer_capture(env, st, span, label, function, before, after)

    glance.BinaryOperator(span, op, left, right) ->
      infer_binop(env, st, span, op, left, right)

    glance.Block(_, statements) -> infer_statements(env, st, statements)

    glance.Case(_, subjects, clauses) -> infer_case(env, st, subjects, clauses)

    glance.TupleIndex(_, tuple, index) -> {
      use #(t, st) <- result.try(infer_expr(env, st, tuple))
      case resolve(st, t) {
        ty.Tuple(elements) ->
          case list_at(elements, index) {
            Ok(element) -> Ok(#(element, st))
            Error(_) -> Error(TupleIndexOutOfRange(index))
          }
        // The tuple type is not known yet; defer until inference fixes it.
        ty.Var(_) -> {
          let #(element, st) = fresh(st)
          let st =
            State(..st, pending: [PendingIndex(t, index, element), ..st.pending])
          Ok(#(element, st))
        }
        _ -> Error(NotATuple)
      }
    }

    // `panic` and `todo` are bottom, so the result is a fresh variable that
    // unifies with anything. The message is still walked — and checked against
    // `String`, as the compiler requires — so its subexpressions get annotated.
    glance.Todo(_, message) | glance.Panic(_, message) ->
      case message {
        Some(m) -> {
          use st <- result.try(check(env, st, m, prelude_string()))
          Ok(fresh(st))
        }
        None -> Ok(fresh(st))
      }

    glance.Echo(_, expression, _message) ->
      case expression {
        Some(e) -> infer_expr(env, st, e)
        None -> Ok(#(prelude_nil(), st))
      }

    glance.FieldAccess(access, container, label) -> {
      use #(type_, _, st) <- result.try(infer_field_access(
        env,
        st,
        access,
        container,
        label,
      ))
      Ok(#(type_, st))
    }

    glance.RecordUpdate(_, module, constructor, record, fields) ->
      infer_record_update(env, st, module, constructor, record, fields)

    glance.BitString(_, segments) -> {
      use st <- result.try(
        list.try_fold(segments, st, fn(st, segment) {
          infer_bit_segment(env, st, segment)
        }),
      )
      Ok(#(prelude_bit_array(), st))
    }
  }
}

// Check one record-update field: its new value (or shorthand variable) must
// match the field's declared type.
fn update_field(
  env: Env,
  st: State,
  field: glance.RecordUpdateField(glance.Expression),
  label_types: Dict(String, ty.Type),
  type_name: String,
) -> Result(State, Error) {
  use #(value_type, st) <- result.try(case field.item {
    Some(value) -> infer_expr(env, st, value)
    // Shorthand `label:` refers to the variable named `label`.
    None ->
      case lookup(env, field.label) {
        Ok(scheme) -> Ok(instantiate(st, scheme))
        Error(_) -> Error(UnboundVariable(field.label))
      }
  })
  case dict.get(label_types, field.label) {
    Ok(expected) -> unify(st, value_type, expected)
    Error(_) -> Error(NoSuchField(type_name, field.label))
  }
}

// Check one bit-array segment's value and its size option against their
// expected types.
fn infer_bit_segment(
  env: Env,
  st: State,
  segment: #(
    glance.Expression,
    List(glance.BitStringSegmentOption(glance.Expression)),
  ),
) -> Result(State, Error) {
  let #(value, options) = segment
  let default = case value {
    glance.String(..) -> prelude_string()
    glance.Float(..) -> prelude_float()
    _ -> prelude_int()
  }
  use st <- result.try(check(
    env,
    st,
    value,
    segment_value_type(options, default),
  ))
  list.try_fold(options, st, fn(st, option) {
    case option {
      glance.SizeValueOption(size) -> check(env, st, size, prelude_int())
      _ -> Ok(st)
    }
  })
}

// Which branch a `name.label` access took. A call reads it to pick the
// callee's field map, which is a property of the branch, not of the alias, and
// the resolver reads it to record which member the access resolved to.
type Access {
  // A record field: the compiler's `RecordAccess`, which has no field map.
  // Carries the accessed record's nominal type, live — the reference publishes it
  // zonked, so later unification still refines it.
  Field(record: ty.Type)
  // A module export, by what the interface says it is: the variant carries
  // both the labels a call may use and the identity to publish. The scheme the
  // entry also held has been instantiated by the time the branch is read, so
  // the branch does not carry it.
  Export(variant: ValueVariant)
  // Neither yet: the container's type is still a variable and no module of its
  // name exports the label, so a `PendingField` was queued and no member was
  // decided here.
  Deferred
}

// The export `name.label` reaches when `name` is an imported module: the whole
// scope entry, or nothing when there is no such module or no such export. One
// lookup answers every question a caller has about the export, because the
// interface stores what the caller needs as one thing.
fn module_access(
  env: Env,
  name: String,
  label: String,
) -> Option(ValueConstructor) {
  case dict.get(env.modules, name) {
    Error(_) -> None
    Ok(interface) -> option.from_result(dict.get(interface.values, label))
  }
}

// The one resolver for `name.label`, in projection and in call position
// alike. The compiler's rule: a valid record access wins unconditionally, a
// failing one falls through to a same-named module export, and the record
// error is reported only when neither exists. Which fields the record grants
// is the type's business: a value known to be one variant reaches that
// variant's own fields.
fn infer_field_access(
  env: Env,
  st: State,
  access: glance.Span,
  container: glance.Expression,
  label: String,
) -> Result(#(ty.Type, Access, State), Error) {
  let spans = access_spans(access, container, label)
  use #(type_, branch, st) <- result.try(case container {
    // Only a bare name can also denote a module, so only there is there a
    // module export for a failing record access to fall through to.
    glance.Variable(_, name) -> {
      let export = module_access(env, name, label)
      case dict.has_key(env.values, name) {
        True -> value_field(env, st, container, label, export)
        False -> module_or_record(env, st, container, label, export)
      }
    }
    _ -> module_or_record(env, st, container, label, None)
  })
  Ok(#(type_, branch, record_access(st, spans, label, branch)))
}

// Record the branch the access took, once, wherever it was reached from. A
// deferred access is recorded here too, at the point the deferral is decided:
// the field type it later resolves to is girard's answer, but no member was
// named *at* the access, and a deferral that never resolves fails its whole
// component, whose state — this record included — is discarded with it.
fn record_access(
  st: State,
  spans: Spans,
  label: String,
  access: Access,
) -> State {
  case access {
    Field(record) -> reference(st, spans, ResolvedField(record, label))
    Export(variant) -> reference(st, spans, ResolvedValue(variant))
    Deferred -> reference(st, spans, ResolvedDeferred)
  }
}

// The three spans of a field access. glance builds one as
// `Span(container.start, label_start + byte_size(label))`, so the label is the
// access's last token and its span is exactly the tail of the access.
fn access_spans(
  access: glance.Span,
  container: glance.Expression,
  label: String,
) -> Spans {
  Spans(
    span: access,
    label: glance.Span(access.end - string.byte_size(label), access.end),
    container: span(container),
  )
}

// Instantiate a module export: the branch a record access fell through to.
fn module_export(
  st: State,
  entry: ValueConstructor,
) -> Result(#(ty.Type, Access, State), Error) {
  let #(type_, st) = instantiate(st, entry.scheme)
  Ok(#(type_, Export(entry.variant), st))
}

// Defer `container.label` until inference fixes the container's type.
fn pending_field(
  st: State,
  container_type: ty.Type,
  label: String,
) -> Result(#(ty.Type, Access, State), Error) {
  let #(field, st) = fresh(st)
  let st =
    State(..st, pending: [
      PendingField(container_type, label, field),
      ..st.pending
    ])
  Ok(#(field, Deferred, st))
}

// Field access where the container names a bound value: prefer a record field
// when the value's type has it, else a same-named module export.
fn value_field(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
  export: Option(ValueConstructor),
) -> Result(#(ty.Type, Access, State), Error) {
  use #(container_type, st) <- result.try(infer_expr(env, st, container))
  case resolve(st, container_type) {
    ty.Named(_, _, _, _) as record ->
      case accessor(env, record, label) {
        Ok(_) -> {
          use #(field, st) <- result.try(field_type(env, st, record, label))
          Ok(#(field, Field(record), st))
        }
        // Not a field of this record; a same-named module may export it.
        Error(field_error) ->
          case export {
            Some(export) -> module_export(st, export)
            None -> Error(field_error)
          }
      }
    // The record type is not known yet. Prefer a same-named module export;
    // otherwise defer until inference fixes the type.
    ty.Var(_) ->
      case export {
        Some(export) -> module_export(st, export)
        None -> pending_field(st, container_type, label)
      }
    _ ->
      case export {
        Some(export) -> module_export(st, export)
        None -> Error(NotARecord)
      }
  }
}

// Field access where the container is not a bound value: a qualified module
// export takes precedence, else it is a record field on the container's value.
fn module_or_record(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
  export: Option(ValueConstructor),
) -> Result(#(ty.Type, Access, State), Error) {
  case export {
    Some(export) -> module_export(st, export)
    None -> {
      use #(container_type, st) <- result.try(infer_expr(env, st, container))
      case resolve(st, container_type) {
        ty.Named(_, _, _, _) as record -> {
          use #(field, st) <- result.try(field_type(env, st, record, label))
          Ok(#(field, Field(record), st))
        }
        ty.Var(_) -> pending_field(st, container_type, label)
        _ -> Error(NotARecord)
      }
    }
  }
}

// Resolve `record.label` for a known record type, returning the field type.
fn field_type(
  env: Env,
  st: State,
  record: ty.Type,
  label: String,
) -> Result(#(ty.Type, State), Error) {
  // Resolve through the substitution: a caller may pass a variable that has
  // since been bound to the record type (e.g. record-update's kept fields).
  use accessor_scheme <- result.try(accessor(env, resolve(st, record), label))
  let #(accessor_type, st) = instantiate(st, accessor_scheme)
  let #(field, st) = fresh(st)
  use st <- result.try(unify(st, accessor_type, ty.Fn([record], field)))
  Ok(#(field, st))
}

fn infer_record_update(
  env: Env,
  st: State,
  module: Option(String),
  constructor: String,
  record: glance.Expression,
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> Result(#(ty.Type, State), Error) {
  // A record update produces a *fresh* value of the type: updated fields take
  // their new value's type and kept fields are copied from the record. This is
  // what lets an update change a type parameter, as in
  // `Request(..req, body:)` : `fn(Request(a), b) -> Request(b)` — the kept
  // fields tie only the parameters they share, not all of them.
  use entry <- result.try(constructor_entry(env, module, constructor))
  let #(ctor_type, st) = instantiate(st, entry.scheme)
  let #(field_types, return_type) = case ctor_type {
    ty.Fn(arguments, return) -> #(arguments, return)
    other -> #([], other)
  }
  case return_type {
    ty.Named(type_module, type_name, type_parameters, variant) -> {
      let labels = positional_labels(entry.variant)
      let label_types =
        list.fold(list.zip(labels, field_types), dict.new(), fn(acc, pair) {
          case pair.0 {
            Some(label) -> dict.insert(acc, label, pair.1)
            None -> acc
          }
        })
      let updated = list.map(fields, fn(field) { field.label })

      // Fix the record's head to this type with independent parameters, so its
      // own type variables aren't conflated with the result's.
      let #(record_parameters, st) = fresh_n(st, list.length(type_parameters))
      use #(record_type, st) <- result.try(infer_expr(env, st, record))
      use st <- result.try(unify(
        st,
        record_type,
        ty.Named(type_module, type_name, record_parameters, variant),
      ))

      // Updated fields take their new value's type.
      use st <- result.try(
        list.try_fold(fields, st, fn(st, field) {
          update_field(env, st, field, label_types, type_name)
        }),
      )

      // Kept fields are copied from the record. The record carries the same
      // constructor, so each kept field's type is the constructor's field type
      // with the result's parameters swapped for the record's. Unifying the two
      // ties only the parameters a kept field actually uses, which is what lets
      // an *updated* field change a parameter. Deriving this from the named
      // constructor (rather than a field accessor) means it works even for
      // fields not shared by every variant of a multi-variant type.
      let to_record_params =
        dict.from_list(list.zip(
          list.filter_map(type_parameters, var_id),
          record_parameters,
        ))
      use st <- result.try(
        list.try_fold(dict.to_list(label_types), st, fn(st, pair) {
          let #(label, expected) = pair
          case list.contains(updated, label) {
            True -> Ok(st)
            False -> unify(st, substitute(to_record_params, expected), expected)
          }
        }),
      )

      Ok(#(return_type, st))
    }
    _ -> Error(NotARecord)
  }
}

// The per-position labels a callable declares, as a list: the positions of a
// callable with no labelled position at all, which is the empty list because
// there is nothing to reorder against.
fn positional_labels(variant: ValueVariant) -> FieldMap {
  option.unwrap(field_map(variant), [])
}

fn is_upper(name: String) -> Bool {
  case string.first(name) {
    Ok(c) -> string.uppercase(c) == c && string.lowercase(c) != c
    Error(_) -> False
  }
}

fn infer_each(
  env: Env,
  st: State,
  exprs: List(glance.Expression),
) -> Result(#(List(ty.Type), State), Error) {
  use #(rev, st) <- result.try(
    list.try_fold(exprs, #([], st), fn(acc, e) {
      let #(types_, st) = acc
      use #(t, st) <- result.try(infer_expr(env, st, e))
      Ok(#([t, ..types_], st))
    }),
  )
  Ok(#(list.reverse(rev), st))
}

fn infer_fn(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
) -> Result(#(ty.Type, State), Error) {
  let #(names, _ids, st) = annotation_var_names(st, params, return_annotation)
  // No expected type: each parameter starts as a fresh variable.
  let #(seeds, st) = fresh_n(st, list.length(params))
  infer_lambda(env, st, params, return_annotation, body, seeds, None, names)
}

// Map each type-variable name written in a lambda's annotations to ONE fresh
// variable, shared across every parameter and the return. A name like `a` in
// `fn(msg: Message(a, b)) -> Next(_, Message(a, b))` denotes a single type
// within the signature; without this, each annotation hydrates its own `a` and
// the two stay distinct whenever the body does not tie them (an actor handler
// whose returned message type is otherwise free). The lambda itself stays
// monomorphic — only the names are shared, not generalized.
//
// Shared by every path that walks a lambda, seeded or not: the names a lambda
// writes mean the same thing whether or not the type it will be called at is
// already known, as they do in the compiler, which hydrates a lambda's
// annotations in one scope either way.
//
// The ids are returned alongside because a `let`-bound lambda is generalized
// over exactly these variables; every other caller ignores them.
fn annotation_var_names(
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
) -> #(Dict(String, ty.Type), List(Int), State) {
  list.fold(
    list.unique(fn_annotation_var_names(params, return_annotation)),
    #(dict.new(), [], st),
    fn(acc, nm) {
      let #(names, ids, st) = acc
      let #(id, st) = fresh_id(st)
      #(dict.insert(names, nm, ty.Var(id)), [id, ..ids], st)
    },
  )
}

// Infer a lambda whose parameters are seeded from the type it will be called
// at, and record its span — which `infer_expr`'s wrapper does for a lambda
// reached the ordinary way, and which every seeding caller bypasses.
fn infer_seeded_lambda(
  env: Env,
  st: State,
  span: glance.Span,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
  seeds: List(ty.Type),
  expected_return: Option(ty.Type),
) -> Result(#(ty.Type, State), Error) {
  let #(names, _ids, st) = annotation_var_names(st, params, return_annotation)
  use #(fn_type, st) <- result.try(infer_lambda(
    env,
    st,
    params,
    return_annotation,
    body,
    seeds,
    expected_return,
    names,
  ))
  Ok(#(fn_type, record(st, span, fn_type)))
}

// Infer a lambda whose parameters are seeded with `seed_params` (the expected
// argument types when known, otherwise fresh variables) and whose body is
// optionally checked against `expected_return`.
fn infer_lambda(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
  seed_params: List(ty.Type),
  expected_return: Option(ty.Type),
  // Pre-seeded type-variable names (name -> Var). When a `let`-bound function is
  // generalized over its explicit annotation variables, those share these ids
  // across every annotation in the lambda; otherwise this is empty.
  names: Dict(String, ty.Type),
) -> Result(#(ty.Type, State), Error) {
  use #(rev_param_types, body_env, st) <- result.try(
    list.try_fold(list.zip(params, seed_params), #([], env, st), fn(acc, pair) {
      let #(types_, env, st) = acc
      let #(param, seed) = pair
      use #(t, st) <- result.try(case param.type_ {
        Some(ann) -> {
          let #(annotated, st) = hydrate_in(env, names, st, ann)
          use st <- result.try(unify(st, annotated, seed))
          Ok(#(seed, st))
        }
        None -> Ok(#(seed, st))
      })
      let env = case param.name {
        glance.Named(name) -> bind_local(env, name, ty.Scheme([], t))
        glance.Discarded(_) -> env
      }
      Ok(#([t, ..types_], env, st))
    }),
  )
  let param_types = list.reverse(rev_param_types)
  use #(body_type, st) <- result.try(infer_statements(body_env, st, body))
  use st <- result.try(case return_annotation {
    Some(ann) -> {
      let #(t, st) = hydrate_in(env, names, st, ann)
      unify(st, body_type, t)
    }
    None -> Ok(st)
  })
  use st <- result.try(case expected_return {
    Some(expected) -> unify(st, body_type, expected)
    None -> Ok(st)
  })
  Ok(#(ty.Fn(param_types, body_type), st))
}

// Infer the callee of a call, returning its type and its field map when one
// is known. A `name.label` callee resolves exactly as a projection does,
// through `infer_field_access`, and its field map follows the branch that
// won: a module export's own map, or none at all for a record field — the
// compiler's `RecordAccess` has no field map, so a call on a field accepts no
// labelled arguments even when a same-named module exports a labelled
// function under that label. A bare name takes the map registered for it.
fn infer_callee(
  env: Env,
  st: State,
  function: glance.Expression,
) -> Result(#(ty.Type, Option(FieldMap), State), Error) {
  case function {
    // Resolved here rather than through `infer_expr`, which would drop the
    // branch; the callee's span is recorded once, as `infer_expr` would.
    glance.FieldAccess(access_span, container, label) -> {
      use #(type_, access, st) <- result.try(infer_field_access(
        env,
        st,
        access_span,
        container,
        label,
      ))
      let labels = case access {
        Export(variant) -> field_map(variant)
        Field(_) | Deferred -> None
      }
      Ok(#(type_, labels, record(st, span(function), type_)))
    }
    // A bare name, resolved here for the same reason: `infer_expr` would
    // instantiate the scheme and drop the entry it came from, and the entry is
    // what says which member this call resolved to and what labels it may use.
    // Reading it once is also what makes an unbound name one answer — the
    // error — rather than an answer here and an error there. All three of the
    // reference's spans are the variable's.
    glance.Variable(name_span, name) ->
      case dict.get(env.values, name) {
        Error(_) -> Error(UnboundVariable(name))
        Ok(entry) -> {
          let #(type_, st) = instantiate_in(env, st, name, entry.scheme)
          let st = record(st, name_span, type_)
          let spans = Spans(name_span, name_span, name_span)
          Ok(#(
            type_,
            field_map(entry.variant),
            reference(st, spans, ResolvedValue(entry.variant)),
          ))
        }
      }
    // A lambda, another call's result: neither a name nor a reference, and no
    // labels to call it with.
    _ -> {
      use #(type_, st) <- result.try(infer_expr(env, st, function))
      Ok(#(type_, None, st))
    }
  }
}

fn infer_call(
  env: Env,
  st: State,
  span: glance.Span,
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> Result(#(ty.Type, State), Error) {
  // A lambda in callee position has no signature its parameter types can be
  // read from, so they are learned from the call's own arguments — the
  // compiler's `infer_fn_with_call_context`. Only at matching arity, which is
  // its guard too: at any other arity the call is an error, and pairing the
  // arguments off against the parameters would be pairing the wrong ones.
  use #(fn_type, labels, st) <- result.try(case function {
    glance.Fn(fn_span, params, return_annotation, body) ->
      case list.length(params) == list.length(arguments) {
        True ->
          infer_applied_lambda(
            env,
            st,
            fn_span,
            params,
            return_annotation,
            body,
            arguments,
          )
        False -> infer_callee(env, st, function)
      }
    _ -> infer_callee(env, st, function)
  })
  use #(return, st) <- result.try(
    place_arguments(
      st,
      fn_type,
      labels,
      arguments,
      fn(expression) { expression },
      fn(st, argument, hole) { check(env, st, argument, hole) },
    ),
  )
  Ok(#(return, record(st, span, return)))
}

// Place a call's arguments against the callee's parameters and check each one:
// reorder the slots through the callee's field map, fix the callee's function
// shape *before* any slot is walked, then check each slot against the parameter
// the reorder placed it at. Returns the call's result hole.
//
// Fixing the shape first is what lets an argument's body see the types it will
// be called with — a lambda argument's parameters in `list.map(rows, fn(row) {
// row.field })`, and every seeded position this module has. Walking the slots
// in declared order is the other half: types flowing from an earlier argument
// constrain a later one, and an argument declared after another is inferred
// after it however the two were written.
//
// The three call shapes — a call, a capture and a `use` — differ only in what a
// slot holds and in what checking one does, so each says how to `wrap` a bare
// expression as one of its own slots and how to `check_slot` one. Wrapping is
// all a shorthand field needs: `label:` is the in-scope `label` in every shape,
// so that rule is written here rather than three times.
fn place_arguments(
  st: State,
  fn_type: ty.Type,
  labels: Option(FieldMap),
  slots: List(glance.Field(slot)),
  wrap: fn(glance.Expression) -> slot,
  check_slot: fn(State, slot, ty.Type) -> Result(State, Error),
) -> Result(#(ty.Type, State), Error) {
  use ordered <- result.try(
    order_fields(labels, slots, fn(label, location) {
      wrap(glance.Variable(location, label))
    }),
  )
  let #(holes, st) = fresh_n(st, list.length(ordered))
  let #(result, st) = fresh(st)
  use st <- result.try(unify(st, fn_type, ty.Fn(holes, result)))
  use st <- result.try(
    list.try_fold(list.zip(ordered, holes), st, fn(st, pair) {
      check_slot(st, pair.0, pair.1)
    }),
  )
  // The call's value is the callee's own return type, not the hole unified
  // against it: the two are the same type, but only the callee's carries the
  // variant a constructor's return was built with.
  Ok(#(call_return(st, fn_type, result), st))
}

// Seed a called lambda's parameters from the call's own arguments, then walk
// its body — the callee half of `infer_call` for that one shape, answering
// what `infer_callee` answers for every other. A lambda has no field map, so
// the call accepts no labelled argument, exactly as it does today.
//
// `infer_call` goes on to infer the arguments again, for real, against the
// parameters this seeded. That is the compiler's order as well as girard's:
// the speculative pass exists only to learn the types.
fn infer_applied_lambda(
  env: Env,
  st: State,
  span: glance.Span,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
  arguments: List(glance.Field(glance.Expression)),
) -> Result(#(ty.Type, Option(FieldMap), State), Error) {
  let #(seeds, st) = speculate(env, st, list.map(arguments, field_item))
  use #(fn_type, st) <- result.try(infer_seeded_lambda(
    env,
    st,
    span,
    params,
    return_annotation,
    body,
    seeds,
    None,
  ))
  Ok(#(fn_type, None, st))
}

// Infer each argument only to learn its type, keeping what unification learned
// and putting back everything the pass *reported*. The compiler does the same
// in `infer_fn_with_call_context`, where the restore is of the diagnostics the
// speculative pass recorded rather than of the substitution: a binding this
// pass makes to a variable already in the environment is one the real pass
// would make too. `next_id` is kept for the mirror-image reason — reissuing an
// id this pass spent would hand two different variables one name.
//
// Restoring the three lists is what keeps the pass invisible: no span is
// annotated twice, no reference recorded twice, and no deferral is left behind
// holding a result variable nothing will ever read.
//
// An argument this pass cannot type is left as a fresh variable rather than
// failing the call. The real pass infers it again and reports it there, so
// speculating never decides whether a program is accepted. That path rewinds
// the id counter along with everything else, which is safe for the reason
// keeping it is necessary above: nothing from a failed pass survives, so its
// ids name no variable anything can still reach.
fn speculate(
  env: Env,
  st: State,
  arguments: List(glance.Expression),
) -> #(List(ty.Type), State) {
  case infer_each(env, st, arguments) {
    Error(_) -> fresh_n(st, list.length(arguments))
    Ok(#(types_, spent)) -> #(
      types_,
      State(
        ..spent,
        annotations: st.annotations,
        references: st.references,
        pending: st.pending,
      ),
    )
  }
}

// A call's result: the callee's own return where the callee is known to be a
// function, else the hole the call was unified against.
fn call_return(st: State, callee: ty.Type, hole: ty.Type) -> ty.Type {
  case resolve(st, callee) {
    ty.Fn(_, return) -> return
    _ -> hole
  }
}

fn fresh_n(st: State, n: Int) -> #(List(ty.Type), State) {
  use <- bool.guard(when: n <= 0, return: #([], st))
  let #(t, st) = fresh(st)
  let #(rest, st) = fresh_n(st, n - 1)
  #([t, ..rest], st)
}

fn field_item(field: glance.Field(glance.Expression)) -> glance.Expression {
  case field {
    glance.UnlabelledField(item) -> item
    glance.LabelledField(_, _, item) -> item
    glance.ShorthandField(label, location) -> glance.Variable(location, label)
  }
}

// Re-wrap a field's item, keeping the label the reorder places it by. A
// shorthand field carries no item to wrap and is left as one, for
// `order_fields`' materializer to resolve to the in-scope name.
fn map_field(field: glance.Field(a), wrap: fn(a) -> b) -> glance.Field(b) {
  case field {
    glance.UnlabelledField(item) -> glance.UnlabelledField(wrap(item))
    glance.LabelledField(label, location, item) ->
      glance.LabelledField(label, location, wrap(item))
    glance.ShorthandField(label, location) ->
      glance.ShorthandField(label, location)
  }
}

// Reorder labelled/shorthand call or pattern arguments into positional order
// using the callee's field map. If every argument is positional we don't need
// the field map (this also covers calls to anonymous functions).
fn order_fields(
  labels: Option(FieldMap),
  fields: List(glance.Field(t)),
  shorthand: fn(String, glance.Span) -> t,
) -> Result(List(t), Error) {
  // All-unlabelled is the fast path: keep the fields in order.
  use <- bool.lazy_guard(when: list.all(fields, is_unlabelled), return: fn() {
    Ok(
      list.filter_map(fields, fn(field) {
        case field {
          glance.UnlabelledField(item) -> Ok(item)
          _ -> Error(Nil)
        }
      }),
    )
  })
  case labels {
    Some(labels) -> reorder(fields, labels, shorthand)
    None -> Error(AmbiguousCall)
  }
}

fn label_indices(labels: FieldMap) -> Dict(String, Int) {
  list.index_fold(labels, dict.new(), fn(acc, label, index) {
    case label {
      Some(name) -> dict.insert(acc, name, index)
      None -> acc
    }
  })
}

fn is_unlabelled(field: glance.Field(t)) -> Bool {
  case field {
    glance.UnlabelledField(..) -> True
    _ -> False
  }
}

fn reorder(
  fields: List(glance.Field(t)),
  labels: FieldMap,
  shorthand: fn(String, glance.Span) -> t,
) -> Result(List(t), Error) {
  let index_of = label_indices(labels)
  // Labelled and shorthand arguments are placed at their declared index;
  // positional arguments then fill the remaining positions in order.
  use labelled <- result.try(
    list.try_fold(fields, dict.new(), fn(placed, field) {
      case field {
        glance.UnlabelledField(..) -> Ok(placed)
        glance.LabelledField(label, _, item) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, item))
        }
        glance.ShorthandField(label, location) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, shorthand(label, location)))
        }
      }
    }),
  )
  let positional =
    list.filter_map(fields, fn(field) {
      case field {
        glance.UnlabelledField(item) -> Ok(item)
        _ -> Error(Nil)
      }
    })
  let free =
    list.filter(indices(list.length(labels)), fn(i) {
      !dict.has_key(labelled, i)
    })
  let placed =
    list.fold(list.zip(free, positional), labelled, fn(placed, pair) {
      dict.insert(placed, pair.0, pair.1)
    })
  list.try_map(indices(list.length(labels)), fn(index) {
    case dict.get(placed, index) {
      Ok(item) -> Ok(item)
      Error(_) -> Error(MissingArgument)
    }
  })
}

fn label_index(
  index_of: Dict(String, Int),
  label: String,
) -> Result(Int, Error) {
  case dict.get(index_of, label) {
    Ok(index) -> Ok(index)
    Error(_) -> Error(UnknownLabel(label))
  }
}

fn infer_capture(
  env: Env,
  st: State,
  span: glance.Span,
  label: Option(String),
  function: glance.Expression,
  before: List(glance.Field(glance.Expression)),
  after: List(glance.Field(glance.Expression)),
) -> Result(#(ty.Type, State), Error) {
  // `f(a, _, b)` becomes `fn(x) { f(a, x, b) }`. The slots are built in source
  // order — the hole under its own label where it has one, `value: _` — and
  // `order_fields` is the one thing that moves them, so the hole and every
  // argument are aligned into declared order by the same reorder a direct call
  // would do. Source order in, declared order out.
  use #(fn_type, labels, st) <- result.try(infer_callee(env, st, function))
  // `hole` is the capture's own parameter type. The marker in the slots says
  // only *where* among the arguments the hole goes; unifying `hole` with the
  // parameter the reorder placed it against is all that is left.
  let #(hole, st) = fresh(st)
  let hole_field = case label {
    Some(name) -> glance.LabelledField(name, span, Implicit)
    None -> glance.UnlabelledField(Implicit)
  }
  let slots =
    list.flatten([
      list.map(before, map_field(_, Argument)),
      [hole_field],
      list.map(after, map_field(_, Argument)),
    ])
  use #(return, st) <- result.try(
    place_arguments(
      st,
      fn_type,
      labels,
      slots,
      Argument,
      fn(st, slot, slot_type) {
        case slot {
          Argument(expression) -> check(env, st, expression, slot_type)
          Implicit -> unify(st, hole, slot_type)
        }
      },
    ),
  )
  // A capture is a lambda whose body is the call, so its return is the
  // callee's own — `Loud(_)` returns a value known to be `Loud`.
  let captured = ty.Fn([hole], return)
  Ok(#(captured, record(st, span, captured)))
}

fn infer_binop(
  env: Env,
  st: State,
  span: glance.Span,
  op: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(ty.Type, State), Error) {
  case op {
    glance.Pipe -> infer_pipe(env, st, span, left, right)

    glance.And | glance.Or -> {
      use st <- result.try(check(env, st, left, prelude_bool()))
      use st <- result.try(check(env, st, right, prelude_bool()))
      Ok(#(prelude_bool(), st))
    }

    glance.Eq | glance.NotEq -> {
      use #(lt, st) <- result.try(infer_expr(env, st, left))
      use #(rt, st) <- result.try(infer_expr(env, st, right))
      use st <- result.try(unify(st, lt, rt))
      Ok(#(prelude_bool(), st))
    }

    glance.Concatenate -> {
      use st <- result.try(check(env, st, left, prelude_string()))
      use st <- result.try(check(env, st, right, prelude_string()))
      Ok(#(prelude_string(), st))
    }

    glance.AddInt
    | glance.SubInt
    | glance.MultInt
    | glance.DivInt
    | glance.RemainderInt -> {
      use st <- result.try(check(env, st, left, prelude_int()))
      use st <- result.try(check(env, st, right, prelude_int()))
      Ok(#(prelude_int(), st))
    }

    glance.AddFloat | glance.SubFloat | glance.MultFloat | glance.DivFloat -> {
      use st <- result.try(check(env, st, left, prelude_float()))
      use st <- result.try(check(env, st, right, prelude_float()))
      Ok(#(prelude_float(), st))
    }

    glance.LtInt | glance.LtEqInt | glance.GtInt | glance.GtEqInt -> {
      use st <- result.try(check(env, st, left, prelude_int()))
      use st <- result.try(check(env, st, right, prelude_int()))
      Ok(#(prelude_bool(), st))
    }

    glance.LtFloat | glance.LtEqFloat | glance.GtFloat | glance.GtEqFloat -> {
      use st <- result.try(check(env, st, left, prelude_float()))
      use st <- result.try(check(env, st, right, prelude_float()))
      Ok(#(prelude_bool(), st))
    }
  }
}

fn infer_pipe(
  env: Env,
  st: State,
  span: glance.Span,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(ty.Type, State), Error) {
  case right {
    glance.Call(call_span, function, arguments) -> {
      // `left |> f(args)` is `f(left, args)` when `f` takes one more argument
      // than is supplied. But if `f(args)` is already a saturated call that
      // returns a function, the pipe applies `left` to that result:
      // `f(args)(left)`. Distinguish on the callee's arity.
      //
      // The probe's state is thrown away and `st` carries on: `infer_call`
      // infers the callee again, properly, and keeping the probe's work would
      // annotate and resolve the callee's span twice over — the second time
      // with the instantiation the call actually constrained. An ill-typed
      // callee still fails here, as it did before.
      use #(ft, probe) <- result.try(infer_expr(env, st, function))
      let saturated = case resolve(probe, ft) {
        ty.Fn(params, _) -> list.length(params) == list.length(arguments)
        _ -> False
      }
      case saturated {
        True -> {
          use #(call_type, st) <- result.try(infer_call(
            env,
            st,
            call_span,
            function,
            arguments,
          ))
          use #(lt, st) <- result.try(infer_expr(env, st, left))
          let #(result, st) = fresh(st)
          use st <- result.try(unify(st, call_type, ty.Fn([lt], result)))
          let return = call_return(st, call_type, result)
          Ok(#(return, record(st, span, return)))
        }
        False ->
          infer_call(env, st, call_span, function, [
            glance.UnlabelledField(left),
            ..arguments
          ])
      }
    }
    // `left |> f` becomes `f(left)`, so the target is applied to the piped
    // value's type whatever it is. How it is walked is what differs: a lambda
    // is checked against that application, and anything else resolves as a
    // callee.
    _ -> {
      use #(lt, st) <- result.try(infer_expr(env, st, left))
      let #(result, st) = fresh(st)
      let piped = ty.Fn([lt], result)
      use st <- result.try(case right {
        // A lambda target is the one shape whose body can use what it is piped:
        // `check` seeds its parameter from the piped value's type before the
        // body is inferred, so a field access on that parameter resolves at the
        // access. The compiler reaches the same place by rewriting the pipe
        // into a call of the lambda on the piped value.
        //
        // A lambda of the wrong arity is not a `Fn` of this shape, so `check`
        // falls back to infer-then-unify and fails exactly where it does today.
        glance.Fn(..) -> check(env, st, right, piped)
        // Any other target is a callee, so it resolves through `infer_callee`
        // — which is `infer_expr` plus a field-map lookup this shape has no
        // arguments to use, so the type is unchanged, but which is also what
        // records a bare name's reference.
        _ -> {
          use #(ft, _labels, st) <- result.try(infer_callee(env, st, right))
          unify(st, ft, piped)
        }
      })
      Ok(#(result, record(st, span, result)))
    }
  }
}

// Infer an expression and unify it against an expected type. A lambda is
// checked against the expected type so its parameters are seeded from the
// expected argument types before its body is inferred.
fn check(
  env: Env,
  st: State,
  expr: glance.Expression,
  expected: ty.Type,
) -> Result(State, Error) {
  let seeded = case expr {
    glance.Fn(_, params, _, _) -> expected_fn(st, expected, list.length(params))
    _ -> Error(Nil)
  }
  case expr, seeded {
    glance.Fn(span, params, return_annotation, body), Ok(#(seeds, ret)) -> {
      use #(fn_type, st) <- result.try(infer_seeded_lambda(
        env,
        st,
        span,
        params,
        return_annotation,
        body,
        seeds,
        Some(ret),
      ))
      unify(st, fn_type, expected)
    }
    _, _ -> {
      use #(t, st) <- result.try(infer_expr(env, st, expr))
      unify(st, t, expected)
    }
  }
}

// Statements
//
// Infer a block's statements in sequence, threading the environment, and
// desugar `use` into the trailing-callback call it stands for.

fn infer_statements(
  env: Env,
  st: State,
  statements: List(glance.Statement),
) -> Result(#(ty.Type, State), Error) {
  case statements {
    [] -> Ok(#(prelude_nil(), st))
    // `use pats <- rhs` turns the remaining statements into a trailing callback.
    [glance.Use(_, patterns, function), ..rest] ->
      infer_use(env, st, patterns, function, rest)
    [last] -> {
      use #(t, _env, st) <- result.try(infer_statement(env, st, last))
      Ok(#(t, st))
    }
    [first, ..rest] -> {
      use #(_t, env, st) <- result.try(infer_statement(env, st, first))
      infer_statements(env, st, rest)
    }
  }
}

// A slot in a call girard assembles rather than reads: the arguments a capture
// or a `use` writes out, plus the one argument that is implied rather than
// written — a capture's hole, a `use`'s callback. Neither is a
// `glance.Expression` (the hole is the capture's own parameter; the callback's
// parameters are patterns and its body is the rest of the block), so the
// implied one travels through the reorder as a marker and each shape says what
// checking it means. The field map may place it anywhere among the others,
// which is the whole reason it goes through the reorder at all.
type CallSlot {
  Argument(expression: glance.Expression)
  Implicit
}

// Desugar `use a, b <- rhs(args)` followed by `rest` into
// `rhs(args, fn(a, b) { rest })` and infer the resulting call.
//
// The callee comes first, as it does for every other call, so the callback's
// parameter types are known before the rest of the block is walked: a field
// access on a `use` binding then resolves at the access instead of waiting for
// unification to fix the receiver. The callback is pushed *unlabelled* and the
// complete argument list is reordered through the callee's field map, so a
// labelled explicit argument can leave the callback an earlier slot than the
// last — and the slots are then walked in declared order, so an explicit
// argument declared after the callback is inferred after it.
fn infer_use(
  env: Env,
  st: State,
  use_patterns: List(glance.UsePattern),
  function: glance.Expression,
  rest: List(glance.Statement),
) -> Result(#(ty.Type, State), Error) {
  let #(callee, arguments) = case function {
    glance.Call(_, callee, arguments) -> #(callee, arguments)
    // A `use` callee with no argument list is still a callee: the callback is
    // its only argument.
    other -> #(other, [])
  }
  use #(callee_type, labels, st) <- result.try(infer_callee(env, st, callee))
  let slots =
    list.append(list.map(arguments, map_field(_, Argument)), [
      glance.UnlabelledField(Implicit),
    ])
  place_arguments(st, callee_type, labels, slots, Argument, fn(st, slot, hole) {
    case slot {
      Argument(expression) -> check(env, st, expression, hole)
      Implicit -> check_callback(env, st, use_patterns, rest, hole)
    }
  })
}

// Check a `use` callback against the parameter type its slot was given, the way
// `check` checks a lambda against a known function type. A callback is not a
// `glance.Fn` — its parameters are patterns and its body is the rest of the
// block — so it cannot go through `check` itself, but the seeding rule is the
// same: where the expected type is a function of the patterns' arity, each
// pattern is inferred against its expected parameter type, so a field access on
// a `use` binding sees the type it was bound at.
fn check_callback(
  env: Env,
  st: State,
  use_patterns: List(glance.UsePattern),
  rest: List(glance.Statement),
  expected: ty.Type,
) -> Result(State, Error) {
  let #(seeds, st) = case expected_fn(st, expected, list.length(use_patterns)) {
    Ok(#(params, _return)) -> #(params, st)
    Error(_) -> fresh_n(st, list.length(use_patterns))
  }
  use #(callback_env, st) <- result.try(
    list.try_fold(list.zip(use_patterns, seeds), #(env, st), fn(acc, pair) {
      let #(env, st) = acc
      let #(use_pattern, seed) = pair
      use st <- result.try(case use_pattern.annotation {
        Some(ann) -> {
          let #(annotated, st) = hydrate(env, st, ann)
          unify(st, annotated, seed)
        }
        None -> Ok(st)
      })
      use #(env, _, st) <- result.try(infer_pattern(
        env,
        st,
        use_pattern.pattern,
        seed,
        None,
      ))
      Ok(#(env, st))
    }),
  )
  // The patterns bind at the seeds themselves, so the callback's parameter
  // types are the seeds — nothing the fold above can change.
  use #(body_type, st) <- result.try(infer_statements(callback_env, st, rest))
  unify(st, ty.Fn(seeds, body_type), expected)
}

// When a lambda of `arity` parameters may be seeded from `expected`: its
// parameter types and its return, where the expected type is already known to
// be a function of that arity. This is the rule the whole seeding mechanism
// turns on, so `check` and `check_callback` read it from one place.
fn expected_fn(
  st: State,
  expected: ty.Type,
  arity: Int,
) -> Result(#(List(ty.Type), ty.Type), Nil) {
  case resolve(st, expected) {
    ty.Fn(params, return) ->
      case list.length(params) == arity {
        True -> Ok(#(params, return))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// Infer one statement, returning its type and the (possibly extended)
// environment to thread to following statements.
fn infer_statement(
  env: Env,
  st: State,
  statement: glance.Statement,
) -> Result(#(ty.Type, Env, State), Error) {
  case statement {
    glance.Expression(expr) -> {
      use #(t, st) <- result.try(infer_expr(env, st, expr))
      Ok(#(t, env, st))
    }

    // `let name = fn(...)` whose annotations name type variables is generalized
    // over exactly those variables — Gleam makes such a local binding
    // polymorphic (`let id = fn(x: a) -> a { x }` may then be used at several
    // types), unlike an unannotated `let id = fn(x) { x }`, which stays
    // monomorphic.
    glance.Assignment(
      _,
      _kind,
      glance.PatternVariable(_, name) as pattern,
      None,
      glance.Fn(fspan, fparams, freturn, fbody) as value,
    ) ->
      case fn_annotation_var_names(fparams, freturn) {
        [] -> infer_expr_assignment(env, st, pattern, None, value)
        _ -> {
          let #(names, ann_ids, st) = annotation_var_names(st, fparams, freturn)
          let #(seeds, st) = fresh_n(st, list.length(fparams))
          use #(value_type, st) <- result.try(infer_lambda(
            env,
            st,
            fparams,
            freturn,
            fbody,
            seeds,
            None,
            names,
          ))
          let st = record(st, fspan, value_type)
          let scheme = generalize_over(st, env, value_type, ann_ids)
          Ok(#(value_type, bind_local(env, name, scheme), st))
        }
      }

    glance.Assignment(_, _kind, pattern, annotation, value) ->
      infer_expr_assignment(env, st, pattern, annotation, value)

    glance.Assert(_, expression, _message) -> {
      use st <- result.try(check(env, st, expression, prelude_bool()))
      Ok(#(prelude_nil(), env, st))
    }

    // `use` is handled by infer_statements before reaching here.
    glance.Use(..) -> Error(Unsupported("use in non-tail position"))
  }
}

// The general `let pattern = value` case: infer the value, optionally check it
// against the binding's annotation, then bind the pattern monomorphically.
fn infer_expr_assignment(
  env: Env,
  st: State,
  pattern: glance.Pattern,
  annotation: Option(glance.Type),
  value: glance.Expression,
) -> Result(#(ty.Type, Env, State), Error) {
  use #(value_type, st) <- result.try(infer_expr(env, st, value))
  use st <- result.try(case annotation {
    Some(ann) -> {
      let #(t, st) = hydrate(env, st, ann)
      unify(st, value_type, t)
    }
    None -> Ok(st)
  })
  // `let assert Ctor(..) = x` narrows `x` itself, for the rest of the block.
  use #(env, _, st) <- result.try(infer_pattern(
    env,
    st,
    pattern,
    value_type,
    subject_variable(value, reference.pattern_names(pattern)),
  ))
  Ok(#(value_type, env, st))
}

// Case expressions
//
// Infer a `case`: unify every clause's patterns against the subjects and
// every clause body against a shared result type, narrowing a matched
// subject variable to its variant.

fn infer_case(
  env: Env,
  st: State,
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
) -> Result(#(ty.Type, State), Error) {
  use #(subject_types, st) <- result.try(infer_each(env, st, subjects))
  let #(result, st) = fresh(st)
  use st <- result.try(
    list.try_fold(clauses, st, fn(st, clause) {
      infer_clause(env, st, clause, subjects, subject_types, result)
    }),
  )
  Ok(#(result, st))
}

fn infer_clause(
  env: Env,
  st: State,
  clause: glance.Clause,
  subjects: List(glance.Expression),
  subject_types: List(ty.Type),
  result: ty.Type,
) -> Result(State, Error) {
  // Each clause may have several alternative pattern lists (`a | b ->`); each
  // binds the same variables and is checked against the subject types. Every
  // alternative is bound first, so the narrowings they disagree on can be
  // dropped before the guard and body are checked under each of them.
  use #(rev_envs, st) <- result.try(
    list.try_fold(clause.patterns, #([], st), fn(acc, patterns) {
      let #(envs, st) = acc
      use #(clause_env, st) <- result.try(bind_alternative(
        env,
        st,
        patterns,
        subjects,
        subject_types,
      ))
      Ok(#([clause_env, ..envs], st))
    }),
  )
  // One alternative agrees with itself, so the names it binds need not even be
  // collected — which is every clause that does not spell `|`.
  let envs = case rev_envs {
    [_] | [] -> list.reverse(rev_envs)
    _ -> {
      let bound = case clause.patterns {
        [first, ..] -> list.flat_map(first, reference.pattern_names)
        [] -> []
      }
      let subjects =
        option.values(list.map(subjects, subject_variable(_, bound)))
      let envs = agree_subjects(st, list.reverse(rev_envs), subjects)
      agree_bindings(st, envs, bound)
    }
  }
  list.try_fold(envs, st, fn(st, clause_env) {
    use st <- result.try(case clause.guard {
      Some(guard) -> check(clause_env, st, guard, prelude_bool())
      None -> Ok(st)
    })
    use #(body_type, st) <- result.try(infer_expr(clause_env, st, clause.body))
    unify(st, body_type, result)
  })
}

// Bind one alternative's patterns against the subjects, narrowing any bare
// subject variable a variant pattern matches.
fn bind_alternative(
  env: Env,
  st: State,
  patterns: List(glance.Pattern),
  subjects: List(glance.Expression),
  subject_types: List(ty.Type),
) -> Result(#(Env, State), Error) {
  // Which names the alternative binds is a property of the whole multi-pattern,
  // not of the column a subject sits in: `case left, io { io, Loud(..) -> .. }`
  // binds `io` in one column and would narrow it in the other.
  let bound = list.flat_map(patterns, reference.pattern_names)
  list.try_fold(
    list.zip(patterns, list.zip(subjects, subject_types)),
    #(env, st),
    fn(acc, pair) {
      let #(env, st) = acc
      let #(pattern, #(subject, subject_type)) = pair
      use #(env, _, st) <- result.map(infer_pattern(
        env,
        st,
        pattern,
        subject_type,
        subject_variable(subject, bound),
      ))
      #(env, st)
    },
  )
}

// A subject variable's variant across alternatives, the compiler's
// `set_subject_variable_variant` in alternative mode: the **first** alternative
// is the only one that may set it, and a later alternative can only take it
// away, by naming a different variant. One that names none returns early and
// leaves it alone.
//
// So the rule is order-sensitive, and measured to be: `Loud(..) | _` keeps the
// narrowing and reads the field, while `_ | Loud(..)` is rejected — the first
// alternative narrows nothing, and the second is not allowed to. The envs are
// then made to agree at that answer rather than merely stripped, because the
// body is checked under each of them and only the first binds the subject at
// the variant the compiler ends up with.
fn agree_subjects(
  st: State,
  envs: List(Env),
  names: List(String),
) -> List(Env) {
  list.fold(names, envs, fn(envs, name) {
    let variants = list.map(envs, bound_variant(st, _, name))
    let agreed = case variants {
      // A later alternative erases only by naming a *different* variant; `None`
      // from one is silence, not disagreement.
      [first, ..rest] ->
        case list.any(rest, fn(v) { v != None && v != first }) {
          True -> None
          False -> first
        }
      [] -> None
    }
    list.map(envs, fn(env) {
      case agreed {
        Some(index) -> narrow(env, st, name, index)
        None -> erase_binding(st, env, name)
      }
    })
  })
}

// A name the patterns *bind* is a different rule, and not the one above: the
// compiler unifies the alternatives' bindings through
// `unify_constructor_variants`, which keeps a variant only where every
// alternative gives it the same one. Measured: `Loud(..) as io | _ as io` is
// rejected, where the subject form `Loud(..) | _` is accepted, so the two
// classes genuinely disagree and cannot share a pass. Equal and unstamped is
// agreement too.
fn agree_bindings(
  st: State,
  envs: List(Env),
  names: List(String),
) -> List(Env) {
  list.fold(names, envs, fn(envs, name) {
    case list.unique(list.map(envs, bound_variant(st, _, name))) {
      [_] | [] -> envs
      _ -> list.map(envs, erase_binding(st, _, name))
    }
  })
}

// The variant a name is bound at in `env`, if it is bound at all. A name bound
// by only some alternatives is a compile error in Gleam, so an absent binding
// needs no answer of its own.
fn bound_variant(st: State, env: Env, name: String) -> Option(Int) {
  case lookup(env, name) {
    Ok(scheme) -> variant_of(resolve(st, scheme.type_))
    Error(_) -> None
  }
}

// Rebind `name` to its own type with the variant forgotten: the same binding,
// less what the alternatives disagreed on.
fn erase_binding(st: State, env: Env, name: String) -> Env {
  case dict.get(env.values, name) {
    Ok(ValueConstructor(ty.Scheme(vars, type_), variant)) ->
      install(
        env,
        name,
        ty.Scheme(vars, erase_variant(resolve(st, type_))),
        variant,
      )
    Error(_) -> env
  }
}

// Patterns
//
// Infer a pattern against its expected type, binding the variables it
// introduces — constructor, list, tuple, string-prefix and bit-array
// patterns included, and narrowing the bare variable the pattern is matched
// against when there is one.

// The bare variable a pattern is matched against, if the pattern is matched
// against one. A constructor names a record rather than a local variable, and
// `echo` is transparent, so `case echo io { .. }` narrows `io`.
fn subject_of(expr: glance.Expression) -> Option(String) {
  case expr {
    glance.Variable(_, name) ->
      case is_upper(name) {
        True -> None
        False -> Some(name)
      }
    glance.Echo(_, Some(inner), _) -> subject_of(inner)
    _ -> None
  }
}

// The subject a pattern may narrow: the bare variable it is matched against,
// unless the pattern binds that name itself. A pattern's own binding is a
// different value, and it wins over the narrowing whichever order the two are
// registered in, so the compiler skips the narrowing outright.
fn subject_variable(
  subject: glance.Expression,
  bound: List(String),
) -> Option(String) {
  case subject_of(subject) {
    Some(name) ->
      case list.contains(bound, name) {
        True -> None
        False -> Some(name)
      }
    None -> None
  }
}

// Rebind `name` to its type narrowed to `variant`. The compiler sets the
// variant on a link-collapsed copy so the outer scope keeps its type; here the
// rebinding is the copy, and it lives only as long as the environment it is
// made in.
//
// The scheme's quantifiers are kept rather than instantiated away. A module
// constant is generalized like a function, so `const box = Empty` is bound at
// `Box(a)`, and monomorphizing it here would reject a clause that uses it at
// two instantiations — which the compiler accepts. Stamping under the
// quantifier narrows every instantiation instead, and `substitute` carries the
// variant through. Only a record is narrowed: a name whose type is a function
// or a tuple stamps to itself and is left alone, which is what excludes a
// top-level function used as a subject.
fn narrow(env: Env, st: State, name: String, variant: Int) -> Env {
  case dict.get(env.values, name) {
    Ok(ValueConstructor(ty.Scheme(vars, type_), value)) ->
      case stamp(st, type_, variant) {
        ty.Named(..) as stamped ->
          install(env, name, ty.Scheme(vars, stamped), value)
        _ -> env
      }
    Error(_) -> env
  }
}

// Infer a pattern, returning the environment it extends, **its own type**, and
// the state. The type is the compiler's `Pattern::type_()` rather than the
// expected type it was matched against: the two differ exactly where a pattern
// is more specific than what it matched, which is what an enclosing `as` has to
// bind at. A constructor pattern's own type carries the variant it matched, and
// a tuple pattern's is rebuilt from its elements' own types, so
// `#(Loud(..), _) as pair` binds `pair` at `#(Logger[Loud], Int)` and
// `pair.0.println` is in reach.
//
// Measured against 1.18.0: the rebuild is recursive (a tuple in a tuple keeps
// the stamp) and it stops at a constructor's arguments — `Box(Loud(..)) as b`
// leaves `b.value` un-narrowed, because a constructor pattern's type is its
// return, whose arguments were erased when the type variable was bound.
fn infer_pattern(
  env: Env,
  st: State,
  pattern: glance.Pattern,
  expected: ty.Type,
  subject: Option(String),
) -> Result(#(Env, ty.Type, State), Error) {
  case pattern {
    glance.PatternInt(..) ->
      typed(env, prelude_int(), unify(st, expected, prelude_int()))
    glance.PatternFloat(..) ->
      typed(env, prelude_float(), unify(st, expected, prelude_float()))
    glance.PatternString(..) ->
      typed(env, prelude_string(), unify(st, expected, prelude_string()))
    glance.PatternDiscard(..) -> Ok(#(env, expected, st))

    glance.PatternVariable(_, name) ->
      Ok(#(bind_local(env, name, ty.Scheme([], expected)), expected, st))

    glance.PatternTuple(_, elements) -> {
      // Destructure a tuple the expected type already is, element by element,
      // rather than through fresh element variables: a variable binding erases
      // what the element was built with, and the compiler destructures. The
      // tuple's own type is then rebuilt from what the elements matched, which
      // is where an element's variant survives to an enclosing `as`.
      use #(elem_types, st) <- result.try(tuple_elements(
        st,
        expected,
        list.length(elements),
      ))
      use #(env, rev_types, st) <- result.try(
        list.try_fold(
          list.zip(elements, elem_types),
          #(env, [], st),
          fn(acc, pair) {
            let #(env, types_, st) = acc
            let #(pattern, t) = pair
            use #(env, t, st) <- result.map(infer_pattern(
              env,
              st,
              pattern,
              t,
              None,
            ))
            #(env, [t, ..types_], st)
          },
        ),
      )
      Ok(#(env, ty.Tuple(list.reverse(rev_types)), st))
    }

    glance.PatternList(_, elements, tail) -> {
      let #(elem, st) = fresh(st)
      use st <- result.try(unify(st, expected, prelude_list(elem)))
      use #(env, st) <- result.try(
        list.try_fold(elements, #(env, st), fn(acc, p) {
          let #(env, st) = acc
          use #(env, _, st) <- result.map(infer_pattern(env, st, p, elem, None))
          #(env, st)
        }),
      )
      use #(env, st) <- result.try(case tail {
        Some(t) -> {
          use #(env, _, st) <- result.map(infer_pattern(
            env,
            st,
            t,
            prelude_list(elem),
            None,
          ))
          #(env, st)
        }
        None -> Ok(#(env, st))
      })
      Ok(#(env, prelude_list(elem), st))
    }

    // `Ctor(..) as name` hands the subject on to the pattern inside it, which
    // narrows the subject as it would on its own; the `as` name then takes the
    // pattern's own type, and so is itself that pattern's type. The pattern is
    // inferred first so its narrowing cannot overwrite this binding.
    glance.PatternAssignment(_, pattern, name) -> {
      use #(env, type_, st) <- result.try(infer_pattern(
        env,
        st,
        pattern,
        expected,
        subject,
      ))
      Ok(#(bind_local(env, name, ty.Scheme([], type_)), type_, st))
    }

    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) -> {
      use st <- result.try(unify(st, expected, prelude_string()))
      // Both the matched prefix (`"a" as c <> rest`) and the remainder bind to
      // String. The prefix binding is optional (`<> rest` with no `as`).
      let bind_name = fn(env, name) {
        case name {
          glance.Named(n) -> bind_local(env, n, ty.Scheme([], prelude_string()))
          glance.Discarded(_) -> env
        }
      }
      let env = case prefix_name {
        Some(name) -> bind_name(env, name)
        None -> env
      }
      Ok(#(bind_name(env, rest_name), prelude_string(), st))
    }

    glance.PatternVariant(_, module, constructor, arguments, _spread) -> {
      use entry <- result.try(constructor_entry(env, module, constructor))
      let #(ctor_type, st) = instantiate(st, entry.scheme)
      // A constructor with fields is a function; one without is the value.
      let #(field_types, ret) = case ctor_type {
        ty.Fn(args, ret) -> #(args, ret)
        other -> #([], other)
      }
      use st <- result.try(unify(st, expected, ret))
      // Matching a bare subject variable against this constructor narrows that
      // variable to it, in this scope only: `env` is a value, so the scope the
      // pattern opens carries the rebinding and the caller's does not.
      let env = case subject, variant_of(ret) {
        Some(name), Some(index) -> narrow(env, st, name, index)
        _, _ -> env
      }
      use arg_patterns <- result.try(order_pattern_args(
        positional_labels(entry.variant),
        arguments,
        list.length(field_types),
      ))
      use #(env, st) <- result.try(
        list.try_fold(
          list.zip(arg_patterns, field_types),
          #(env, st),
          fn(acc, pair) {
            let #(env, st) = acc
            let #(pattern, t) = pair
            use #(env, _, st) <- result.map(infer_pattern(
              env,
              st,
              pattern,
              t,
              None,
            ))
            #(env, st)
          },
        ),
      )
      // The constructor's own return, stamped: the arguments matched above do
      // not re-stamp it, which is the compiler's shape.
      Ok(#(env, ret, st))
    }

    glance.PatternBitString(_, segments) -> {
      use st <- result.try(unify(st, expected, prelude_bit_array()))
      use #(env, st) <- result.try(
        list.try_fold(segments, #(env, st), fn(acc, segment) {
          let #(env, st) = acc
          infer_bit_pattern_segment(env, st, segment)
        }),
      )
      Ok(#(env, prelude_bit_array(), st))
    }
  }
}

// A pattern arm's result where the pattern's own type is already known: the
// `with_env` of the three-place return.
fn typed(
  env: Env,
  type_: ty.Type,
  st: Result(State, Error),
) -> Result(#(Env, ty.Type, State), Error) {
  result.map(st, fn(st) { #(env, type_, st) })
}

// A tuple pattern's element types: the expected type's own elements where it
// already is a tuple of the right width, else fresh variables unified against
// it. Destructuring is what keeps an element's variant, which binding it to a
// fresh variable would erase; the fresh-variable path is also where an arity
// mismatch is still reported.
fn tuple_elements(
  st: State,
  expected: ty.Type,
  arity: Int,
) -> Result(#(List(ty.Type), State), Error) {
  let destructured = case resolve(st, expected) {
    ty.Tuple(elements) ->
      case list.length(elements) == arity {
        True -> Ok(elements)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case destructured {
    Ok(elements) -> Ok(#(elements, st))
    Error(_) -> {
      let #(elem_types, st) = fresh_n(st, arity)
      use st <- result.try(unify(st, expected, ty.Tuple(elem_types)))
      Ok(#(elem_types, st))
    }
  }
}

// Check one bit-array *pattern* segment: bind the segment pattern and check
// its size option, threading the environment for any bound variables.
fn infer_bit_pattern_segment(
  env: Env,
  st: State,
  segment: #(
    glance.Pattern,
    List(glance.BitStringSegmentOption(glance.BitArraySize)),
  ),
) -> Result(#(Env, State), Error) {
  let #(pattern, options) = segment
  let default = case pattern {
    glance.PatternString(..) -> prelude_string()
    glance.PatternFloat(..) -> prelude_float()
    _ -> prelude_int()
  }
  use #(env, _, st) <- result.try(infer_pattern(
    env,
    st,
    pattern,
    segment_value_type(options, default),
    None,
  ))
  list.try_fold(options, #(env, st), fn(acc, option) {
    let #(env, st) = acc
    case option {
      glance.SizeValueOption(size) ->
        with_env(env, check_bit_array_size(env, st, size))
      _ -> Ok(#(env, st))
    }
  })
}

// Check a bit-array *pattern* segment size (glance 7.0+): a restricted
// arithmetic expression over already-bound variables, every part of which is
// an `Int`. Unlike a value size it binds nothing — a variable is a reference
// that must already be in scope and is unified with `Int`; literals, binary
// operators, and parenthesized blocks recurse.
fn check_bit_array_size(
  env: Env,
  st: State,
  size: glance.BitArraySize,
) -> Result(State, Error) {
  case size {
    glance.BitArraySizeInt(..) -> Ok(st)
    glance.BitArraySizeVariable(_, name) ->
      case lookup(env, name) {
        Ok(scheme) -> {
          let #(t, st) = instantiate(st, scheme)
          unify(st, t, prelude_int())
        }
        Error(_) -> Error(UnboundVariable(name))
      }
    glance.BitArraySizeBinaryOperator(_, _, left, right) -> {
      use st <- result.try(check_bit_array_size(env, st, left))
      check_bit_array_size(env, st, right)
    }
    glance.BitArraySizeBlock(_, inner) -> check_bit_array_size(env, st, inner)
  }
}

// Pair a (possibly failed) new state with an unchanged environment.
fn with_env(
  env: Env,
  st: Result(State, Error),
) -> Result(#(Env, State), Error) {
  result.map(st, fn(st) { #(env, st) })
}

// Resolve a constructor name (optionally module-qualified) to its scope entry.
// The whole entry, because every caller wants the scheme *and* the labels, and
// resolving the name once is what keeps the two answers about the same
// constructor: a second lookup for the labels would have to re-decide which
// module the name came from, and could only disagree.
fn constructor_entry(
  env: Env,
  module: Option(String),
  constructor: String,
) -> Result(ValueConstructor, Error) {
  case module {
    Some(alias) ->
      case dict.get(env.modules, alias) {
        Ok(interface) ->
          dict.get(interface.values, constructor)
          |> result.replace_error(NoSuchExport(alias, constructor))
        Error(_) -> Error(UnknownModule(alias))
      }
    None ->
      dict.get(env.values, constructor)
      |> result.replace_error(UnknownConstructor(constructor))
  }
}

// The value type of a bit-array segment given its options and the default to
// use when no type option is present (`Int` for numeric segments, `String`
// for string-literal segments, etc.).
fn segment_value_type(
  options: List(glance.BitStringSegmentOption(t)),
  default: ty.Type,
) -> ty.Type {
  list.fold(options, default, fn(acc, option) {
    case option {
      glance.FloatOption -> prelude_float()
      glance.Utf8Option | glance.Utf16Option | glance.Utf32Option ->
        prelude_string()
      glance.Utf8CodepointOption
      | glance.Utf16CodepointOption
      | glance.Utf32CodepointOption -> prelude_utf_codepoint()
      glance.BytesOption | glance.BitsOption -> prelude_bit_array()
      glance.IntOption -> prelude_int()
      _ -> acc
    }
  })
}

// Place constructor-pattern arguments into positional order, reordering by the
// constructor's field map and filling positions omitted via `..` with discards.
fn order_pattern_args(
  labels: FieldMap,
  arguments: List(glance.Field(glance.Pattern)),
  arity: Int,
) -> Result(List(glance.Pattern), Error) {
  let index_of = label_indices(labels)
  use labelled <- result.try(
    list.try_fold(arguments, dict.new(), fn(placed, field) {
      case field {
        glance.UnlabelledField(..) -> Ok(placed)
        glance.LabelledField(label, _, item) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, item))
        }
        glance.ShorthandField(label, location) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, glance.PatternVariable(location, label)))
        }
      }
    }),
  )
  let positional =
    list.filter_map(arguments, fn(field) {
      case field {
        glance.UnlabelledField(item) -> Ok(item)
        _ -> Error(Nil)
      }
    })
  let free = list.filter(indices(arity), fn(i) { !dict.has_key(labelled, i) })
  let placed =
    list.fold(list.zip(free, positional), labelled, fn(placed, pair) {
      dict.insert(placed, pair.0, pair.1)
    })
  Ok(
    list.map(indices(arity), fn(index) {
      case dict.get(placed, index) {
        Ok(pattern) -> pattern
        // Omitted via `..`: bind nothing.
        Error(_) -> glance.PatternDiscard(glance.Span(0, 0), "_")
      }
    }),
  )
}

// `[0, 1, ..., n - 1]`.
fn indices(n: Int) -> List(Int) {
  indices_loop(n - 1, [])
}

fn indices_loop(i: Int, acc: List(Int)) -> List(Int) {
  use <- bool.guard(when: i < 0, return: acc)
  indices_loop(i - 1, [i, ..acc])
}

// Type annotation hydration
//
// Convert a written type annotation into an internal `Type`, expanding aliases
// and attributing named types to their origin module. Hydration never fails:
// unknown type variables become fresh variables. An unresolved unqualified
// name is attributed to the prelude; an unresolved qualified name keeps its
// written module alias.
fn hydrate(env: Env, st: State, ast: glance.Type) -> #(ty.Type, State) {
  hydrate_with(env, dict.new(), st, ast).0
}

// Resolve a (possibly qualified) type name applied to `arg_types` to a concrete
// `Type`, expanding aliases (local, unqualified-imported, or qualified) and
// attributing a named type to its origin module.
fn resolve_named_type(
  env: Env,
  st: State,
  module: Option(String),
  name: String,
  arg_types: List(ty.Type),
) -> #(ty.Type, State) {
  case module {
    None -> resolve_unqualified_type(env, st, name, arg_types)
    Some(alias) -> resolve_qualified_type(env, st, alias, name, arg_types)
  }
}

fn resolve_unqualified_type(
  env: Env,
  st: State,
  name: String,
  arg_types: List(ty.Type),
) -> #(ty.Type, State) {
  case dict.get(env.aliases, name) {
    // A local alias: expand its AST in this environment.
    Ok(#(params, aliased)) -> {
      let alias_names = dict.from_list(list.zip(params, arg_types))
      let #(#(t, st), _) = hydrate_with(env, alias_names, st, aliased)
      #(t, st)
    }
    Error(_) -> #(resolve_named_origin(env, name, arg_types), st)
  }
}

// A non-local-alias unqualified name: an unqualified imported alias (already
// resolved), else a named type at its origin module, else the prelude.
fn resolve_named_origin(
  env: Env,
  name: String,
  arg_types: List(ty.Type),
) -> ty.Type {
  case dict.get(env.imported_aliases, name) {
    Ok(#(params, body)) -> instantiate_alias(params, body, arg_types)
    Error(_) ->
      case dict.get(env.local_types, name) {
        Ok(#(origin, origin_name, _arity)) ->
          ty.Named(origin, origin_name, arg_types, None)
        Error(_) -> ty.Named(prelude_module, name, arg_types, None)
      }
  }
}

// A qualified type name `alias.Name`: resolve via the imported module's alias
// or type, falling back to the alias as the module name.
fn resolve_qualified_type(
  env: Env,
  st: State,
  alias: String,
  name: String,
  arg_types: List(ty.Type),
) -> #(ty.Type, State) {
  case dict.get(env.modules, alias) {
    Error(_) -> #(ty.Named(alias, name, arg_types, None), st)
    Ok(interface) ->
      case dict.get(interface.aliases, name) {
        Ok(#(params, body)) -> #(instantiate_alias(params, body, arg_types), st)
        Error(_) -> {
          let origin = case dict.get(interface.types, name) {
            Ok(#(origin, _origin_name, _arity)) -> origin
            Error(_) -> alias
          }
          #(ty.Named(origin, name, arg_types, None), st)
        }
      }
  }
}

fn hydrate_with(
  env: Env,
  names: Dict(String, ty.Type),
  st: State,
  ast: glance.Type,
) -> #(#(ty.Type, State), Dict(String, ty.Type)) {
  case ast {
    glance.NamedType(_, name, module, parameters) -> {
      let #(arg_types, st, names) =
        list.fold(parameters, #([], st, names), fn(acc, p) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, p)
          #([t, ..types_], st, names)
        })
      let arg_types = list.reverse(arg_types)
      let #(t, st) = resolve_named_type(env, st, module, name, arg_types)
      #(#(t, st), names)
    }

    glance.TupleType(_, elements) -> {
      let #(elem_types, st, names) =
        list.fold(elements, #([], st, names), fn(acc, e) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, e)
          #([t, ..types_], st, names)
        })
      #(#(ty.Tuple(list.reverse(elem_types)), st), names)
    }

    glance.FunctionType(_, parameters, return) -> {
      let #(param_types, st, names) =
        list.fold(parameters, #([], st, names), fn(acc, p) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, p)
          #([t, ..types_], st, names)
        })
      let #(#(ret, st), names) = hydrate_with(env, names, st, return)
      #(#(ty.Fn(list.reverse(param_types), ret), st), names)
    }

    glance.VariableType(_, name) ->
      case dict.get(names, name) {
        Ok(t) -> #(#(t, st), names)
        Error(_) -> {
          let #(t, st) = fresh(st)
          #(#(t, st), dict.insert(names, name, t))
        }
      }

    glance.HoleType(..) -> {
      let #(t, st) = fresh(st)
      #(#(t, st), names)
    }
  }
}

// Hydrate using (and threading) a fixed type-variable name map.
fn hydrate_in(
  env: Env,
  names: Dict(String, ty.Type),
  st: State,
  ast: glance.Type,
) -> #(ty.Type, State) {
  hydrate_with(env, names, st, ast).0
}

// Hydrate while threading the type-variable name map so repeated names within
// one signature resolve to the same variable.
fn hydrate_threaded(
  env: Env,
  names: Dict(String, ty.Type),
  st: State,
  ast: glance.Type,
) -> #(ty.Type, State, Dict(String, ty.Type)) {
  let #(#(t, st), names) = hydrate_with(env, names, st, ast)
  #(t, st, names)
}

// Building the annotated module
//
// Assemble the final `AnnotatedModule` from the inferred environment and
// state: each definition's generalized scheme and every recorded expression
// type, zonked and sorted by span. This section is the only place an
// inference-side type becomes a public one, whether in a result or in an
// `Error` that carries a type.

// `Inferred.functions` and `Inferred.constants` are the definitions inference
// walked, so a definition dropped for the other target is not looked up here
// at all. Rendering the caller's unfiltered module — as this used to —
// publishes a target sibling twice, since both names find the surviving
// definition's scheme, and publishes a dropped definition under the scheme of
// a same-named unqualified import.
fn render(inferred: Inferred) -> AnnotatedModule {
  let Inferred(functions:, constants:, env:, st:, skipped:, dropped:, ..) =
    inferred
  let declined = set.from_list(list.map(skipped, fn(entry) { entry.0 }))

  // `st.annotations` is in reverse discovery order. Restore discovery order
  // before the stable span sort, so annotations sharing a span retain the order
  // in which inference recorded them.
  let expressions =
    list.map(list.reverse(st.annotations), fn(entry) {
      let #(span, type_) = entry
      Annotation(span, to_public(zonk(st, type_)))
    })

  AnnotatedModule(
    functions: collect_schemes(functions, env, declined),
    constants: collect_schemes(constants, env, declined),
    expressions: sort_by_span(expressions),
    resolutions: publish_references(st),
    dropped:,
  )
}

// Publish the references recorded during inference: keep one per span, zonk
// each accessed record through the final substitution and convert it, then sort by
// span as annotations are sorted.
fn publish_references(st: State) -> List(ResolvedReference) {
  st.references
  |> one_per_span
  |> list.map(publish_reference(st, _))
  |> sort_references
}

// `AnnotatedModule.resolutions` promises one entry per span, so this is where
// that promise is kept, whoever produces a duplicate. No path does today
// — `infer_pipe`'s arity probe used to, and now runs on a state it throws away
// — but the guarantee is the API's, not one walk's, so it is enforced rather
// than assumed. The survivor is the **last recorded**: `st.references` is in
// reverse discovery order, where the last recorded is the first met.
//
// Two *different* references never share a whole span: a bare callee's is its
// variable, and a field access's includes its container.
fn one_per_span(references: List(Reference)) -> List(Reference) {
  list.fold(references, #([], set.new()), fn(acc, reference) {
    let #(kept, seen) = acc
    case set.contains(seen, reference.spans.span) {
      True -> acc
      False -> #([reference, ..kept], set.insert(seen, reference.spans.span))
    }
  }).0
}

fn publish_reference(st: State, reference: Reference) -> ResolvedReference {
  ResolvedReference(
    span: reference.spans.span,
    label_span: reference.spans.label,
    container_span: reference.spans.container,
    resolution: publish_resolution(st, reference.resolved),
  )
}

fn publish_resolution(st: State, resolved: Resolved) -> Resolution {
  case resolved {
    ResolvedField(receiver, label) ->
      RecordField(to_public(zonk(st, receiver)), label)
    // The declaring module's canonical path and the name the value has
    // *there*, never the alias it was read under: an
    // `import kinds.{Near as Close}` publishes `Constructor("kinds", "Near")`.
    ResolvedValue(FunctionValue(module:, name:, ..)) -> ModuleFn(module, name)
    ResolvedValue(ConstantValue(module:, name:)) -> ModuleConstant(module, name)
    ResolvedValue(ConstructorValue(module:, name:, ..)) ->
      Constructor(module, name)
    ResolvedValue(LocalValue(name:)) -> LocalVariable(name)
    ResolvedDeferred -> Unresolved(RecordAccessUnknownType)
  }
}

fn sort_references(
  references: List(ResolvedReference),
) -> List(ResolvedReference) {
  list.sort(references, fn(a, b) { compare_spans(a.span, b.span) })
}

// Called from `for_target`, which is where a dropped definition is found, but
// defined here beside the other sorts so every published ordering is decided
// in one place.
fn sort_dropped(dropped: List(Dropped)) -> List(Dropped) {
  list.sort(dropped, fn(a, b) { compare_spans(a.span, b.span) })
}

// The inferred (generalized) scheme of each definition, in source order.
// glance accumulates a module's definitions newest-first, so the span sort is
// what puts them in the order the fields promise rather than its reverse.
//
// Best-effort inference leaves a skipped definition unbound, so a lookup is
// usually enough to omit it — but its name is only unbound if nothing *else*
// binds it. One that shadows a same-named unqualified import falls back to
// the import's entry, so it would be published under the import's scheme,
// which is the same mistake `render` avoids for a dropped definition. The
// names inference declined are therefore dropped by name.
fn collect_schemes(
  defs: List(Def),
  env: Env,
  declined: Set(String),
) -> List(#(String, Scheme)) {
  defs
  |> list.sort(fn(a, b) { compare_spans(def_span(a), def_span(b)) })
  |> list.filter_map(fn(def) {
    let name = def_name(def)
    case set.contains(declined, name) {
      True -> Error(Nil)
      False ->
        case lookup(env, name) {
          Ok(scheme) -> Ok(#(name, scheme_to_public(scheme)))
          Error(_) -> Error(Nil)
        }
    }
  })
}

// Publish an inference-side type as the public `Type`. The variant a value
// was narrowed to is inference state, not part of the type consumers see.
fn to_public(type_: ty.Type) -> Type {
  case type_ {
    ty.Named(module, name, args, _) ->
      Named(module, name, list.map(args, to_public))
    ty.Fn(args, ret) -> Fn(list.map(args, to_public), to_public(ret))
    ty.Var(id) -> Var(id)
    ty.Tuple(elements) -> Tuple(list.map(elements, to_public))
  }
}

fn scheme_to_public(scheme: ty.Scheme) -> Scheme {
  Scheme(scheme.vars, to_public(scheme.type_))
}

// The two errors that carry a type, published from their inference-side
// operands.
fn type_mismatch(left: ty.Type, right: ty.Type) -> Error {
  TypeMismatch(to_public(left), to_public(right))
}

fn recursive_type(id: Int, type_: ty.Type) -> Error {
  RecursiveType(id, to_public(type_))
}

fn sort_by_span(annotations: List(Annotation)) -> List(Annotation) {
  list.sort(annotations, fn(a, b) { compare_spans(a.span, b.span) })
}

// The order every published list carries: by where a span starts, then by
// where it ends. One comparator, so "sorted by span" cannot come to mean two
// things.
fn compare_spans(a: glance.Span, b: glance.Span) -> order.Order {
  int.compare(a.start, b.start)
  |> order.break_tie(int.compare(a.end, b.end))
}

// Small helpers
//
// Record an expression's type by span, recover an expression's span, and
// index into a list.

fn record(st: State, span: glance.Span, type_: ty.Type) -> State {
  State(..st, annotations: [#(span, type_), ..st.annotations])
}

// Record which member a reference resolved to.
fn reference(st: State, spans: Spans, resolved: Resolved) -> State {
  State(..st, references: [Reference(spans, resolved), ..st.references])
}

fn span(expr: glance.Expression) -> glance.Span {
  case expr {
    glance.Int(s, _) -> s
    glance.Float(s, _) -> s
    glance.String(s, _) -> s
    glance.Variable(s, _) -> s
    glance.NegateInt(s, _) -> s
    glance.NegateBool(s, _) -> s
    glance.Block(s, _) -> s
    glance.Panic(s, _) -> s
    glance.Todo(s, _) -> s
    glance.Tuple(s, _) -> s
    glance.List(s, _, _) -> s
    glance.Fn(s, _, _, _) -> s
    glance.RecordUpdate(s, _, _, _, _) -> s
    glance.FieldAccess(s, _, _) -> s
    glance.Call(s, _, _) -> s
    glance.TupleIndex(s, _, _) -> s
    glance.FnCapture(s, _, _, _, _) -> s
    glance.BitString(s, _) -> s
    glance.Case(s, _, _) -> s
    glance.BinaryOperator(s, _, _, _) -> s
    glance.Echo(s, _, _) -> s
  }
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

// Prelude type constructors
//
// Constructors for the built-in prelude types, all in the `gleam` module.

// The prelude module name shared by all built-in types.
const prelude_module = "gleam"

fn prelude_bit_array() -> ty.Type {
  ty.Named(prelude_module, "BitArray", [], None)
}

fn prelude_bool() -> ty.Type {
  ty.Named(prelude_module, "Bool", [], None)
}

fn prelude_float() -> ty.Type {
  ty.Named(prelude_module, "Float", [], None)
}

fn prelude_int() -> ty.Type {
  ty.Named(prelude_module, "Int", [], None)
}

fn prelude_list(element: ty.Type) -> ty.Type {
  ty.Named(prelude_module, "List", [element], None)
}

fn prelude_nil() -> ty.Type {
  ty.Named(prelude_module, "Nil", [], None)
}

fn prelude_result(ok: ty.Type, error: ty.Type) -> ty.Type {
  ty.Named(prelude_module, "Result", [ok, error], None)
}

fn prelude_string() -> ty.Type {
  ty.Named(prelude_module, "String", [], None)
}

fn prelude_utf_codepoint() -> ty.Type {
  ty.Named(prelude_module, "UtfCodepoint", [], None)
}

// Type printer
//
// Render a `Type` to Gleam syntax, naming type variables `a, b, c, …` and
// skipping reserved words, with a naming context so names stay stable across
// several related types.

type Names {
  Names(map: Dict(Int, String), next: Int)
}

fn new_names() -> Names {
  Names(map: dict.new(), next: 0)
}

// Print a type within a naming context, returning the updated context so a
// caller can keep variable names stable across several related types.
fn print(names: Names, type_: Type) -> #(String, Names) {
  case type_ {
    Named(_module, name, []) -> #(name, names)

    Named(_module, name, args) -> {
      let #(rendered, names) = print_list(names, args)
      #(name <> "(" <> rendered <> ")", names)
    }

    Fn(args, ret) -> {
      let #(rendered_args, names) = print_list(names, args)
      let #(rendered_ret, names) = print(names, ret)
      #("fn(" <> rendered_args <> ") -> " <> rendered_ret, names)
    }

    Tuple(elements) -> {
      let #(rendered, names) = print_list(names, elements)
      #("#(" <> rendered <> ")", names)
    }

    Var(id) -> var_name(names, id)
  }
}

// Convenience wrapper for a single, standalone type.
fn to_string(type_: Type) -> String {
  print(new_names(), type_).0
}

fn print_list(names: Names, types_: List(Type)) -> #(String, Names) {
  let #(rev, names) =
    list.fold(types_, #([], names), fn(acc, t) {
      let #(rendered, names) = acc
      let #(s, names) = print(names, t)
      #([s, ..rendered], names)
    })
  #(string.join(list.reverse(rev), ", "), names)
}

fn var_name(names: Names, id: Int) -> #(String, Names) {
  case dict.get(names.map, id) {
    Ok(name) -> #(name, names)
    Error(_) -> {
      let #(name, next) = next_name(names.next)
      #(name, Names(map: dict.insert(names.map, id, name), next: next))
    }
  }
}

// The next type-variable name, skipping Gleam reserved words (so a variable is
// never spelled like a keyword, e.g. `fn`), matching the compiler.
fn next_name(n: Int) -> #(String, Int) {
  let name = letters(n)
  case is_reserved(name) {
    True -> next_name(n + 1)
    False -> #(name, n + 1)
  }
}

fn is_reserved(name: String) -> Bool {
  case name {
    "as"
    | "assert"
    | "case"
    | "const"
    | "echo"
    | "fn"
    | "if"
    | "import"
    | "let"
    | "opaque"
    | "panic"
    | "pub"
    | "todo"
    | "type"
    | "use" -> True
    _ -> False
  }
}

// 0 -> "a", 25 -> "z", 26 -> "aa", 27 -> "ab", ...
fn letters(n: Int) -> String {
  let letter = string.utf_codepoint(97 + n % 26)
  let prefix = case n / 26 {
    0 -> ""
    higher -> letters(higher - 1)
  }
  case letter {
    Ok(codepoint) -> prefix <> string.from_utf_codepoints([codepoint])
    Error(_) -> "t" <> int.to_string(n)
  }
}

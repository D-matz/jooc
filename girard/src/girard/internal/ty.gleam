//// The types inference works on.
////
//// `girard.Type` is the vocabulary consumers pattern-match on, and it is
//// frozen: adding a field to it would break every exhaustive match against
//// it. Inference needs one more thing than consumers do — the variant a
//// value has been narrowed to, as the compiler carries on its own named
//// types — so it works on the `Type` defined here and converts to the public
//// one where a result is published. A constructor's return type carries the
//// variant it builds, and a pattern that matches a bare subject variable
//// rebinds that variable, in its own scope, to a copy carrying the variant it
//// matched. Binding a type variable to a type erases it, and so does
//// generalizing a top-level definition, so it never survives a generic
//// function or a module boundary except on a constructor.

import gleam/option.{type Option}

/// The type inference works on. It has the same shape as the public
/// `girard.Type` consumers see, plus `variant` on `Named`: the constructor a
/// value is known to have been built with. Results are converted to the
/// public type when they are published.
pub type Type {
  /// A named, nominal type. `variant` is the source-order index of the
  /// constructor a value is known to have been built with, when it is known.
  Named(
    module: String,
    name: String,
    arguments: List(Type),
    variant: Option(Int),
  )
  /// A function type `fn(a, b) -> c`.
  Fn(arguments: List(Type), return: Type)
  /// A type variable. The substitution in the inference state may bind it.
  Var(id: Int)
  /// A tuple type `#(a, b, c)`.
  Tuple(elements: List(Type))
}

/// A polymorphic type scheme `forall vars. type_` over the `Type` above; the
/// inference-side counterpart of the public `girard.Scheme`.
pub type Scheme {
  Scheme(vars: List(Int), type_: Type)
}

module type T0 = sig
  type t
end

module type Type_with_delete = sig
  type t

  val delete : t -> unit
end

module type Vector = sig
  type elt

  include Type_with_delete

  val typ : t Ctypes.typ

  val create_without_finaliser : unit -> t

  val emplace_back : t -> elt -> unit

  val length : t -> int

  val get_without_finaliser : t -> int -> elt
end

module type Vector_with_gc = sig
  include Vector

  val get : t -> int -> elt

  val create : unit -> t
end

module type Triple = sig
  type elt

  type t

  val f0 : t -> elt

  val f1 : t -> elt

  val f2 : t -> elt
end

module type Pair = sig
  type elt

  include Type_with_delete

  module Vector : Vector with type elt = t

  val make_without_finaliser : elt -> elt -> t

  val f0 : t -> elt

  val f1 : t -> elt
end
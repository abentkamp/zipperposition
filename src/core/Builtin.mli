
(* This file is free software, part of Logtk. See file "license" for more details. *)

(** {1 Builtin Objects}

  Covers numbers, connectives, and builtin types

  @since NEXT_RELEASE *)

type t =
  | Not
  | And
  | Or
  | Imply
  | Equiv
  | Xor
  | Eq
  | Neq
  | HasType
  | LiftType (** @since 0.8 *)
  | True
  | False
  | Exists
  | Forall
  | ForallTy
  | Lambda
  | Arrow
  | Wildcard
  | Multiset  (* type of multisets *)
  | TType (* type of types *)
  | Int of Z.t
  | Rat of Q.t

include Interfaces.HASH with type t := t
include Interfaces.ORD with type t := t
include Interfaces.PRINT with type t := t

val is_prefix : t -> bool
(** [is_infix s] returns [true] if the way the symbol is printed should
    be used in a prefix way if applied to 1 argument *)

val is_infix : t -> bool
(** [is_infix s] returns [true] if the way the symbol is printed should
    be used in an infix way if applied to two arguments *)

val ty : t -> [ `Int | `Rat | `Other ]

val mk_int : Z.t -> t
val of_int : int -> t
val int_of_string : string -> t
val mk_rat : Q.t -> t
val of_rat : int -> int -> t
val rat_of_string : string -> t

val is_int : t -> bool
val is_rat : t -> bool
val is_numeric : t -> bool
val is_not_numeric : t -> bool

module Base : sig
  val true_ : t
  val false_ : t
  val eq : t
  val neq : t
  val exists : t
  val forall : t
  val imply : t
  val equiv : t
  val xor : t
  val lambda : t

  val not_ : t
  val and_ : t
  val or_ : t

  val forall_ty : t
  val arrow : t
  val tType : t
  val has_type : t
  val lift_type : t

  val wildcard : t    (** $_ for type inference *)
  val multiset : t    (** type of multisets *)

  val fresh_var : unit -> t (** New, unique symbol (cycles after 2^63 calls...) *)
end

include Interfaces.HASH with type t := t
include Interfaces.ORD with type t := t
include Interfaces.PRINT with type t := t

module Map : Sequence.Map.S with type key = t
module Set : Sequence.Set.S with type elt = t
module Tbl : Hashtbl.S with type key = t

(** {2 TPTP Interface}
Creates symbol and give them properties. *)

module TPTP : sig
  val connectives : Set.t
  val is_connective : t -> bool

  include Interfaces.PRINT with type t := t
  (** printer for TPTP *)
end

(** The module {!ArithOp} deals only with numeric constants, i.e., all symbols
    must verify {!is_numeric} (and most of the time, have the same type).
    The semantics of operations follows
    {{: http://www.cs.miami.edu/~tptp/TPTP/TR/TPTPTR.shtml#Arithmetic} TPTP}.
  *)

module ArithOp : sig
  exception TypeMismatch of string
  (** This exception is raised when Arith functions are called
      on non-numeric values *)

  type arith_view =
    [ `Int of Z.t
    | `Rat of Q.t
    | `Other of t
    ]

  val view : t -> arith_view
  (** Arith centered view of symbols *)

  val parse_num : string -> t

  val sign : t -> int   (* -1, 0 or 1 *)

  val one_i : t
  val zero_i : t
  val one_rat : t
  val zero_rat : t

  val zero_of_ty : [<`Int | `Rat ] -> t
  val one_of_ty : [<`Int | `Rat ] -> t

  val is_zero : t -> bool
  val is_one : t -> bool
  val is_minus_one : t -> bool

  val floor : t -> t
  val ceiling : t -> t
  val truncate : t -> t
  val round : t -> t

  val prec : t -> t
  val succ : t -> t

  val sum : t -> t -> t
  val difference : t -> t -> t
  val uminus : t -> t
  val product : t -> t -> t
  val quotient : t -> t -> t

  val quotient_e : t -> t -> t
  val quotient_t : t -> t -> t
  val quotient_f : t -> t -> t
  val remainder_e : t -> t -> t
  val remainder_t : t -> t -> t
  val remainder_f : t -> t -> t

  val to_int : t -> t
  val to_rat : t -> t

  val abs : t -> t (* absolute value *)
  val divides : t -> t -> bool (* [divides a b] returns true if [a] divides [b] *)
  val gcd : t -> t -> t  (* gcd of two ints, 1 for other types *)
  val lcm : t -> t -> t   (* lcm of two ints, 1 for other types *)

  val less : t -> t -> bool
  val lesseq : t -> t -> bool
  val greater : t -> t -> bool
  val greatereq : t -> t -> bool

  val divisors : Z.t -> Z.t list
    (** List of non-trivial strict divisors of the int.
        @return [] if int <= 1, the list of divisors otherwise. Empty list
          for prime numbers, obviously. *)
end


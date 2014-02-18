
(*
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 Unification and Matching} *)

module T = ScopedTerm

exception Fail
  (** Raised when a unification/matching attempt fails *)

type scope = Substs.scope
type subst = Substs.t

let prof_unification = Util.mk_profiler "unification"
let prof_matching = Util.mk_profiler "matching"
let prof_variant = Util.mk_profiler "alpha-equiv"
let prof_ac_matching = Util.mk_profiler "ac-matching"

(** {2 Signature} *)

module type S = sig
  type term

  val unification : ?subst:subst -> term -> scope -> term -> scope -> subst
    (** Unify terms, returns a subst or
        @raise Fail if the terms are not unifiable *)

  val matching : ?subst:subst -> pattern:term -> scope -> term -> scope -> subst
    (** [matching ~pattern scope_p b scope_b] returns
        [sigma] such that [sigma pattern = b], or
        @raise Fail if the terms do not match.
        Only variables from the scope of [pattern] can  be bound in the subst. *)

  val variant : ?subst:subst -> term -> scope -> term -> scope -> subst
    (** Succeeds iff the first term is a variant of the second, ie
        if they are alpha-equivalent *)

  val are_unifiable : term -> term -> bool

  val matches : pattern:term -> term -> bool

  val are_variant : term -> term -> bool
end

(** {2 Base (scoped terms)} *)

type term = T.t

(* Does [v] appear in [t] if we apply the substitution? *)
let occurs_check subst v sc_v t sc_t =
  let rec check v sc_v t sc_t =
    match T.ty t with
    | _ when T.ground t -> false
    | T.NoType -> false
    | T.HasType ty ->
      (* check type and subterms *)
      check v sc_t ty sc_t ||
      match T.view t with
      | T.Var _ when T.eq v t && sc_v = sc_t -> true
      | T.Var _ ->
          (* if [t] is a var bound by [subst], check in its image *)
          begin try
            let t', sc_t' = Substs.lookup subst t sc_t in
            check v sc_v t' sc_t'
          with Not_found -> false
          end
      | T.Const _ | T.BVar _ -> false
      | T.Bind (_, varty, t') -> check v sc_v varty sc_t || check v sc_v t' sc_t
      | T.Record l -> List.exists (fun (_,t') -> check v sc_v t' sc_t) l
      | T.App (hd, l) ->
        check v sc_v hd sc_t ||
        List.exists (fun t' -> check v sc_v t' sc_t) l  (* TODO: unroll *)
  in
  check v sc_v t sc_t

let unification ?(subst=Substs.empty) a sc_a b sc_b =
  Util.enter_prof prof_unification;
  (* recursive unification *)
  let rec unif subst s sc_s t sc_t =
    let s, sc_s = Substs.get_var subst s sc_s
    and t, sc_t = Substs.get_var subst t sc_t in
    (* first, unify types *)
    let subst = match T.ty s, T.ty t with
      | T.NoType, T.NoType -> subst
      | T.NoType, _
      | _, T.NoType -> raise Fail
      | T.HasType ty1, T.HasType ty2 ->
        unif subst ty1 sc_s ty2 sc_t
    in
    match T.view s, T.view t with
    | _ when T.eq s t && (T.ground s || sc_s = sc_t) ->
      subst (* the terms are equal under any substitution *)
    | _ when T.ground s && T.ground t ->
      raise Fail (* terms are not equal, and ground. failure. *)
    | T.Var _, _ ->
      if occurs_check subst s sc_s t sc_t
        then raise Fail (* occur check *)
        else Substs.bind subst s sc_s t sc_t (* bind s *)
    | _, T.Var _ ->
      if occurs_check subst t sc_t s sc_s
        then raise Fail (* occur check *)
        else Substs.bind subst t sc_t s sc_s (* bind s *)
    | T.Bind (s1, varty1, t1'), T.Bind (s2, varty2, t2') when Symbol.eq s1 s2 ->
      let subst = unif subst varty1 sc_s varty2 sc_t in
      unif subst t1' sc_s t2' sc_t
    | T.BVar i, T.BVar j -> if i = j then subst else raise Fail
    | T.Const f, T.Const g when Symbol.eq f g -> subst
    | T.Record l1, T.Record l2 when List.length l1 = List.length l2 ->
      List.fold_left2
        (fun subst (s1,t1) (s2,t2) ->
          if s1 = s2
            then unif subst t1 sc_s t2 sc_t
            else raise Fail)
        subst l1 l2
    | T.App (hd1, l1), T.App (hd2, l2) when List.length l1 = List.length l2 ->
      let subst = unif subst hd1 sc_s hd2 sc_t in
      List.fold_left2
        (fun subst t1' t2' -> unif subst t1' sc_s t2' sc_t)
        subst l1 l2
    | _, _ -> raise Fail
  in
  (* try unification, and return solution/exception (with profiler handling) *)
  try
    let subst = unif subst a sc_a b sc_b in
    Util.exit_prof prof_unification;
    subst
  with Fail as e ->
    Util.exit_prof prof_unification;
    raise e

let matching ?(subst=Substs.empty) ~pattern sc_a b sc_b =
  Util.enter_prof prof_matching;
  (* recursive matching *)
  let rec unif ~keep subst s sc_s t sc_t =
    let s, sc_s = Substs.get_var subst s sc_s in
    let subst = match T.ty s, T.ty t with
      | T.NoType, T.NoType -> subst
      | T.NoType, _
      | _, T.NoType -> raise Fail
      | T.HasType ty1, T.HasType ty2 ->
        unif ~keep subst ty1 sc_s ty2 sc_t
    in
    match T.view s, T.view t with
    | _ when T.eq s t && (T.ground s || sc_s = sc_t) ->
      subst (* the terms are equal under any substitution *)
    | _ when T.ground s && T.ground t ->
      raise Fail (* terms are not equal, and ground. failure. *)
    | T.Var _, _ ->
      if occurs_check subst s sc_s t sc_t || (sc_s = sc_t && T.Set.mem s keep)
        then raise Fail
          (* occur check, or [s] is in the same scope
             as [t] and belongs to the variables that need to be preserved *)
        else Substs.bind subst s sc_s t sc_t (* bind s *)
    | T.Bind (s1, varty1, t1'), T.Bind (s2, varty2, t2') when Symbol.eq s1 s2 ->
      let subst = unif ~keep subst varty1 sc_s varty2 sc_t in
      unif ~keep subst t1' sc_s t2' sc_t
    | T.BVar i, T.BVar j when i = j -> subst
    | T.Const f, T.Const g when Symbol.eq f g -> subst
    | T.Record l1, T.Record l2 when List.length l1 = List.length l2 ->
      List.fold_left2
        (fun subst (s1,t1) (s2,t2) ->
          if s1 = s2
            then unif ~keep subst t1 sc_s t2 sc_t
            else raise Fail)
        subst l1 l2
    | T.App (f1, l1), T.App (f2, l2) when List.length l1 = List.length l2 ->
      let subst = unif ~keep subst f1 sc_s f2 sc_t in
      List.fold_left2
        (fun subst t1' t2' -> unif ~keep subst t1' sc_s t2' sc_t)
        subst l1 l2
    | _, _ -> raise Fail
  in
  (* try matching, and return solution/exception (with profiler handling) *)
  try
    (* variables we need to preserve *)
    let keep = T.Seq.vars b |> T.Seq.add_set T.Set.empty in
    let subst = unif ~keep subst pattern sc_a b sc_b in
    Util.exit_prof prof_matching;
    subst
  with Fail as e ->
    Util.exit_prof prof_matching;
    raise e

let variant ?(subst=Substs.empty) a sc_a b sc_b =
  Util.enter_prof prof_variant;
  (* recursive variant checking *)
  let rec unif subst s sc_s t sc_t =
    let s, sc_s = Substs.get_var subst s sc_s in
    let t, sc_t = Substs.get_var subst t sc_t in
    let subst = match T.ty s, T.ty t with
      | T.NoType, T.NoType -> subst
      | T.NoType, _
      | _, T.NoType -> raise Fail
      | T.HasType ty1, T.HasType ty2 ->
        unif subst ty1 sc_s ty2 sc_t
    in
    match T.view s, T.view t with
    | _ when s == t && (T.ground s || sc_s = sc_t) ->
      subst (* the terms are equal under any substitution *)
    | _ when T.ground s && T.ground t ->
      raise Fail (* terms are not equal, and ground. failure. *)
    | T.Var i, T.Var j when i <> j && sc_s = sc_t -> raise Fail
    | T.Var _, T.Var _ -> Substs.bind subst s sc_s t sc_t (* bind s *)
    | T.Bind (s1, varty1, t1'), T.Bind (s2, varty2, t2') when Symbol.eq s1 s2 ->
      let subst = unif subst varty1 sc_s varty2 sc_t in
      unif subst t1' sc_s t2' sc_t
    | T.BVar i, T.BVar j when i = j -> subst
    | T.Const f, T.Const g when Symbol.eq f g -> subst
    | T.Record l1, T.Record l2 when List.length l1 = List.length l2 ->
      List.fold_left2
        (fun subst (s1,t1) (s2,t2) ->
          if s1 = s2
            then unif subst t1 sc_s t2 sc_t
            else raise Fail)
        subst l1 l2
    | T.App (t1, l1), T.App (t2, l2) when List.length l1 = List.length l2 ->
      let subst = unif subst t1 sc_s t2 sc_t in
      List.fold_left2
        (fun subst t1' t2' -> unif subst t1' sc_s t2' sc_t)
        subst (t1 :: l1) (t2 :: l2)
    | _, _ -> raise Fail
  in
  try
    let subst =
      if sc_a = sc_b
      then
        if T.eq a b then subst else raise Fail
      else unif subst a sc_a b sc_b
    in
    Util.exit_prof prof_variant;
    subst
  with Fail as e ->
    Util.exit_prof prof_variant;
    raise e

let are_variant t1 t2 =
  try
    let _ = variant t1 0 t2 1 in
    true
  with Fail ->
    false

let matches ~pattern t =
  try
    let _ = matching ~pattern 0 t 1 in
    true
  with Fail ->
    false

let are_unifiable t1 t2 =
  try
    let _ = unification t1 0 t2 1 in
    true
  with Fail ->
    false

(** {2 Specializations} *)

module Ty = struct
  type term = Type.t

  let unification =
    (unification :> ?subst:subst -> term -> scope -> term -> scope -> subst)

  let matching =
    (matching :> ?subst:subst -> pattern:term -> scope -> term -> scope -> subst)

  let variant =
    (variant :> ?subst:subst -> term -> scope -> term -> scope -> subst)

  let are_unifiable =
    (are_unifiable :> term -> term -> bool)

  let matches =
    (matches :> pattern:term -> term -> bool)

  let are_variant =
    (are_variant :> term -> term -> bool)
end

module FO = struct
  type term = FOTerm.t

  let unification =
    (unification :> ?subst:subst -> term -> scope -> term -> scope -> subst)

  let matching =
    (matching :> ?subst:subst -> pattern:term -> scope -> term -> scope -> subst)

  let variant =
    (variant :> ?subst:subst -> term -> scope -> term -> scope -> subst)

  let are_unifiable =
    (are_unifiable :> term -> term -> bool)

  let matches =
    (matches :> pattern:term -> term -> bool)

  let are_variant =
    (are_variant :> term -> term -> bool)
end

module HO = struct
  type term = HOTerm.t

  let unification =
    (unification :> ?subst:subst -> term -> scope -> term -> scope -> subst)

  let matching =
    (matching :> ?subst:subst -> pattern:term -> scope -> term -> scope -> subst)

  let variant =
    (variant :> ?subst:subst -> term -> scope -> term -> scope -> subst)

  let are_unifiable =
    (are_unifiable :> term -> term -> bool)

  let matches =
    (matches :> pattern:term -> term -> bool)

  let are_variant =
    (are_variant :> term -> term -> bool)
end

module Form = struct
  module F = Formula.FO

  let variant ?(subst=Substs.empty) f1 sc_1 f2 sc_2 =
    (* CPS, with [k] the continuation that is given the answer
      substitutions *)
    let rec unif subst f1 f2 k = match F.view f1, F.view f2 with
      | _ when F.eq f1 f2 -> k subst
      | F.Atom p1, F.Atom p2 ->
        begin try
          let subst = FO.variant ~subst p1 sc_1 p2 sc_2 in
          k subst
        with Fail -> ()
        end
      | F.Eq (t11, t12), F.Eq (t21, t22)
      | F.Neq (t11, t12), F.Neq (t21, t22) ->
        begin try
          let subst = FO.variant ~subst t11 sc_1 t21 sc_2 in
          let subst = FO.variant ~subst t12 sc_1 t22 sc_2 in
          k subst
        with Fail -> ()
        end;
        begin try
          let subst = FO.variant ~subst t11 sc_1 t22 sc_2 in
          let subst = FO.variant ~subst t12 sc_1 t21 sc_2 in
          k subst
        with Fail -> ()
        end;
      | F.Not f1', F.Not f2' -> unif subst f1' f2' k
      | F.Imply (f11, f12), F.Imply (f21, f22)
      | F.Xor (f11, f12), F.Xor (f21, f22)
      | F.Equiv(f11, f12), F.Imply (f21, f22) ->
        unif subst f11 f21 (fun subst -> unif subst f21 f22 k)
      | F.And l1, F.And l2
      | F.Or l1, F.Or l2 ->
        if List.length l1 = List.length l2
          then unif_ac subst l1 [] l2 k
          else ()  (* not. *)
      | F.Exists (ty1,f1'), F.Exists (ty2,f2')
      | F.Forall (ty1,f1'), F.Forall (ty2,f2') ->
        begin try
          let subst = Ty.variant ~subst ty1 sc_1 ty2 sc_2 in
          unif subst f1' f2' k
        with Fail -> ()
        end
      | F.True, F.True
      | F.False, F.False -> k subst  (* yep :) *)
      | _ -> ()  (* failure :( *)
    (* invariant: [l1] and [left @ right] always have the same length *)
    and unif_ac subst l1 left right k = match l1, left, right with
      | [], [], [] -> k subst  (* success! *)
      | f1::l1', left, f2::right' ->
        (* f1 = f2 ? *)
        unif subst f1 f2
          (fun subst -> unif_ac subst l1' [] (left @ right') k);
        (* f1 against right', keep f2 for later *)
        unif_ac subst l1 (f2::left) right' k;
        ()
      | _::_, left, [] -> ()
      | _ -> assert false
    in
    (* flattening (for and/or) *)
    let f1 = F.flatten f1 in
    let f2 = F.flatten f2 in
    (* bottom continuation *)
    let seq k = unif subst f1 f2 k in
    Sequence.from_iter seq

  let are_variant f1 f2 =
    let seq = variant f1 0 f2 1 in
    not (Sequence.is_empty seq)
end

(** {2 AC} *)

module type AC_SPEC = sig
  val is_ac : Symbol.t -> bool
  val is_comm : Symbol.t -> bool
end

module AC(S : AC_SPEC) = struct
  let matching_ac ?offset ?(subst=Substs.empty) ~pattern sc_a b sc_b =
    assert false
    (*
    (* function to get fresh variables *)
    let offset = match offset with
      | Some o -> o
      | None -> ref (max (T.max_var (T.vars a) + sc_a + 1)
                         (T.max_var (T.vars b) + sc_b + 1)) in
    (* avoid index collisions *)
    let fresh_var ~ty =
      let v = T.mk_var ~ty !offset in
      incr offset;
      v
    in
    (* recursive matching. [k] is called with solutions *)
    let rec unif subst s sc_s t sc_t k =
      try
        let s, sc_s = S.get_var subst s sc_s in
        (* first match types *)
        let subst = TypeUnif.match_ho ~subst s.T.ty sc_s t.T.ty sc_t in
        match s.term, t.term with
        | Var _, Var _ when s == t && sc_s = sc_t -> k subst (* trivial success *)
        | Var _, _ ->
          if occurs_check subst s sc_s t sc_t || sc_s = sc_t
            then Util.debug 5 "occur check of %a[%d] in %a[%d]" T.pp s sc_s T.pp t sc_t
              (* occur check, or [s] is not in the initial
                 context [sc_a] in which variables can be bound. *)
            else k (S.bind subst s sc_s t sc_t) (* bind s and continue *)
        | Lambda t1', Lambda t2' ->
          unif subst t1' sc_s t2' sc_t k
        | BoundVar i, BoundVar j -> if i = j then k subst
        | At ({T.term=T.Const f} as head, tyargs1, l1), At ({T.term=T.Const g}, tyargs2, l2)
          when Symbol.eq f g && is_ac f ->
          let subst = unif_types subst tyargs1 sc_s tyargs2 sc_t in
          (* flatten into a list of terms that do not have [f] as head symbol *)
          let l1 = T.flatten_ac f l1
          and l2 = T.flatten_ac f l2 in 
          Util.debug 5 "ac_match for %a: [%a] and [%a]" Symbol.pp f
            (Util.pp_list T.pp) l1 (Util.pp_list T.pp) l2;
          (* eliminate terms that are common to l1 and l2 *)
          let l1, l2 = eliminate_common l1 l2 in
          (* permutative matching *)
          unif_ac ~tyargs:tyargs1 subst head l1 sc_s [] l2 sc_t k
        | At ({T.term=T.Const f}, tyargs1, [x1;y1]), At ({T.term=T.Const g}, tyargs2, [x2;y2])
          when Symbol.eq f g && is_com f ->
          Util.debug 5 "com_match for %a: [%a] and [%a]" Symbol.pp f
            (Util.pp_list T.pp) [x1;y1] (Util.pp_list T.pp) [x2;y2];
          let subst = unif_types subst tyargs1 sc_s tyargs2 sc_t in
          unif_com subst x1 y1 sc_s x2 y2 sc_t k
        | At (t1, tyargs1, l1), At (t2, tyargs2, l2) ->
          (* regular decomposition, but from the left *)
          let subst = unif_types subst tyargs1 sc_s tyargs2 sc_t in
          unif_list subst (t1::l1) sc_s (t2::l2) sc_t k
        | Const f, Const g when Symbol.eq f g -> k subst
        | _, _ -> ()  (* failure, close branch *)
      with TypeUnif.Error _ -> ()
    and unif_types subst l1 sc_1 l2 sc_2 = match l1, l2 with
    | [], [] -> subst
    | [], _ | _, [] -> raise Fail
    | ty1::l1', ty2::l2' ->
      let subst = TypeUnif.match_ho ~subst ty1 sc_1 ty2 sc_2 in
      unif_types subst l1' sc_1 l2' sc_2
    (* unify lists *)
    and unif_list subst l1 sc_1 l2 sc_2 k = match l1, l2 with
    | [], [] -> k subst
    | x::l1', y::l2' ->
      unif subst x sc_1 y sc_2
        (fun subst' -> unif_list subst' l1' sc_1 l2' sc_2 k)
    | _ -> ()
    (* unify terms under a commutative symbol (try both sides) *)
    and unif_com subst x1 y1 sc_1 x2 y2 sc_2 k =
      unif subst x1 sc_1 x2 sc_2 (fun subst -> unif subst y1 sc_1 y2 sc_2 k);
      unif subst x1 sc_1 y2 sc_2 (fun subst -> unif subst y1 sc_1 x2 sc_2 k);
      ()
    (* try all permutations of [left@right] against [l1]. [left,right] is a
       zipper over terms to be matched against [l1]. *)
    and unif_ac ~tyargs subst f l1 sc_1 left right sc_2 k =
      match l1, left, right with
      | [], [], [] -> k subst  (* success *)
      | _ when List.length l1 > List.length left + List.length right ->
        ()  (* failure, too many patterns *)
      | x1::l1', left, x2::right' ->
        (* try one-to-one of x1 against x2 *)
        unif subst x1 sc_1 x2 sc_2
          (fun subst ->
            (* continue without x1 and x2 *)
            unif_ac ~tyargs subst f l1' sc_1 [] (left @ right') sc_2 k);
        (* try x1 against right', keeping x2 on the side *)
        unif_ac ~tyargs subst f l1 sc_1 (x2::left) right' sc_2 k;
        (* try to bind x1 to [x2+z] where [z] is fresh,
           if len(l1) < len(left+right) *)
        if T.is_var x1 && List.length l1 < List.length left + List.length right then
          let z = fresh_var ~ty:(T.ty x1) in
          (* offset trick: we need [z] in both contexts sc_1 and sc_2, so we
             bind it so that (z,sc_2) -> (z,sc_1), and use (z,sc_1) to continue
             the matching *)
          let subst' = S.bind subst z sc_2 z sc_1 in
          let x2' = T.mk_at ~tyargs f [x2; z] in
          let subst' = S.bind subst' x1 sc_1 x2' sc_2 in
          unif_ac ~tyargs subst' f (z::l1') sc_1 left right' sc_2 k
      | x1::l1', left, [] -> ()
      | [], _, _ -> ()  (* failure, some terms are not matched *)
    (* eliminate common occurrences of terms in [l1] and [l2] *)
    and eliminate_common l1 l2 = l1, l2 (* TODO *)
    in
    (* sequence of solutions. Substitutions are restricted to the variables
       of [a]. *)
    let seq k =
      Util.enter_prof prof_ac_matching;
      unif subst a sc_a b sc_b k;
      Util.exit_prof prof_ac_matching
    in
    Sequence.from_iter seq
  *)
end

(*
    ||M||  This file is part of HELM, an Hypertextual, Electronic        
    ||A||  Library of Mathematics, developed at the Computer Science     
    ||T||  Department, University of Bologna, Italy.                     
    ||I||                                                                
    ||T||  HELM is free software; you can redistribute it and/or         
    ||A||  modify it under the terms of the GNU General Public License   
    \   /  version 2 or (at your option) any later version.      
     \ /   This software is distributed as is, NO WARRANTY.     
      V_______________________________________________________________ *)

open Types
open Hashcons

module T = Terms
module C = Clauses
module Unif = FoUnif
module Utils = FoUtils

(* an order on clauses+positions *)
module ClauseOT =
  struct 
    type t = hclause * position * foterm

    let compare (c1, p1, t1) (c2, p2, t2) = 
      let c = Pervasives.compare p1 p2 in
      if c <> 0 then c else
      let c = C.compare_hclause c1 c2 in
      if c <> 0 then c else
      (assert (T.eq_foterm t1 t2); 0)
  end

(* a set of (hashconsed clause, position in clause). A position is a
 * list, that, once reversed, is [lit index, 1|2 (left or right), ...]
 * where ... is the path in the term *)
module ClauseSet : Set.S with 
  type elt = hclause * position * foterm
  = Set.Make(ClauseOT)

open Discrimination_tree

module FotermIndexable = struct
  type input = foterm
  type constant_name = Signature.symbol

  (* convert into a path string *)
  let path_string_of t =
    let rec aux arity t = match t.node.term with
      | Leaf a -> [Constant (a, arity)]
      | Var i -> (* assert (arity = 0); *) [Variable]
      | Node ([] | [ _ ] )
      (* FIXME : should this be allowed or not ? *)
      | Node ({node={term=Var _}}::_)
      | Node ({node={term=Node _}}::_) -> assert false
      | Node (hd::tl) ->
          aux (List.length tl) hd @ List.flatten (List.map (aux 0) tl) 
    in 
      aux 0 t

  (* compare two path string elements *)
  let compare e1 e2 = 
    match e1,e2 with 
    | Constant (a1,ar1), Constant (a2,ar2) ->
        let c = Signature.compare a1 a2 in
        if c <> 0 then c else Pervasives.compare ar1 ar2
    | Variable, Variable -> 0
    | Constant _, Variable -> ~-1
    | Variable, Constant _ -> 1
    | Proposition, _ | _, Proposition
    | Datatype, _ | _, Datatype
    | Dead, _ | _, Dead
    | Bound _, _ | _, Bound _ -> assert false

  (* print path into string *)
  let string_of_path l =
    let str_of_elem = function
    | Variable -> "*"
    | Constant (a, ar) -> Utils.on_buffer Signature.pp_symbol a
    | _ -> "?"
    in String.concat "." (List.map str_of_elem l)
end

(* the discrimination trees used for indexing *)
module DT : DiscriminationTree with
  type constant_name = Signature.symbol and 
  type input = foterm and 
  type data = ClauseSet.elt and 
  type dataset = ClauseSet.t
= Make(FotermIndexable)(ClauseSet)

type input = DT.input
type data = DT.data
type dataset = DT.dataset

(* the main index type. It contains two trees, that are
 * used to index all subterms of a clause, and terms
 * that occur directly under an equation. *)
type t = {
  root_index : DT.t;
  unit_root_index : DT.t;
  subterm_index : DT.t;
}

let empty = { root_index=DT.empty;
              unit_root_index=DT.empty;
              subterm_index=DT.empty }

(** process the literal (only its maximal side(s)) *)
let process_lit op c tree (lit, pos) =
  match lit with
  | Equation (l,_,_,Gt) -> 
      op tree l (c, [C.left_pos; pos])
  | Equation (_,r,_,Lt) -> 
      op tree r (c, [C.right_pos; pos])
  | Equation (l,r,_,Incomparable) ->
      let tmp_tree = op tree l (c, [C.left_pos; pos]) in
      op tmp_tree r (c, [C.right_pos; pos])
  | Equation (l,r,_,Invertible) ->
      op tree l (c, [C.left_pos; pos])
  | Equation (_,r,_,Eq) -> assert false

(** apply op to some of the literals of the clause, and only to
    the maximal side(s) of the literals. *)
let process_clause op tree ({node={clits=lits}} as c) =
  let lits_pos = Utils.list_pos lits in
  let new_tree = List.fold_left (process_lit op c) tree lits_pos in
  new_tree

(** apply (op tree) to all subterms, folding the resulting tree *)
let rec fold_subterms op tree t (c, path) = match t.node.term with
  | Var _ -> tree  (* variables are not indexed *)
  | Leaf _ -> op tree t (c, List.rev path, t) (* reverse path now *)
  | Node (_::l) ->
      (* apply the operation on the term itself *)
      let tmp_tree = op tree t (c, List.rev path, t) in
      let _, new_tree = List.fold_left
        (* apply the operation on each i-th subterm with i::path
           as position. i starts at 1 and the function symbol is ignored. *)
        (fun (idx, tree) t -> idx+1, fold_subterms op tree t (c, idx::path))
        (1, tmp_tree) l
      in new_tree
  | _ -> assert false

(** apply (op tree) to the root term, after reversing the path *)
let apply_root_term op tree t (c, path) = op tree t (c, List.rev path, t)

(** add root terms and subterms to respective indexes *)
let index_clause {root_index; unit_root_index; subterm_index} clause =
  let new_subterm_index = process_clause (fold_subterms DT.index) subterm_index clause
  and new_unit_root_index = match clause.node.clits with
      | [(Equation (_,_,true,_)) as lit] ->
          process_lit (apply_root_term DT.index) clause unit_root_index (lit, 0)
      | _ -> unit_root_index
  and new_root_index = process_clause (apply_root_term DT.index) root_index clause
  in {root_index=new_root_index;
      unit_root_index=new_unit_root_index;
      subterm_index=new_subterm_index}

(** remove root terms and subterms from respective indexes *)
let remove_clause {root_index; unit_root_index; subterm_index} clause =
  let new_subterm_index = process_clause (fold_subterms DT.remove_index) subterm_index clause
  and new_unit_root_index = match clause.node.clits with
      | [lit] -> process_lit (apply_root_term DT.remove_index) clause unit_root_index (lit, 0)
      | _ -> unit_root_index
  and new_root_index = process_clause (apply_root_term DT.remove_index) root_index clause
  in {root_index=new_root_index;
      unit_root_index=new_unit_root_index;
      subterm_index=new_subterm_index}

let fold = DT.fold 

let elems index =
  DT.fold index (fun _ dataset acc -> ClauseSet.union dataset acc)
    ClauseSet.empty

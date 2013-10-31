
(*
Zipperposition: a functional superposition prover for prototyping
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

(** {1 Arbitrary instances for Arithmetic} *)

open Logtk
open Logtk_arbitrary
open Libzipperposition

module T = struct
  let t st = assert false

  (*
  let arbitrary_arith ty =
    QCheck.Arbitrary.(lift M.to_term (M.arbitrary_ty ty))
  *)
end

module Lit = struct
  let t st = assert false

(*
  let arbitrary ty =
    let open QCheck.Arbitrary in
    T.arbitrary_arith ty >>= fun t1 ->
    T.arbitrary_arith ty >>= fun t2 ->
    let signature = TypeInference.FO.Quick.(signature
      ~signature:Signature.Arith.signature [WellTyped t1; WellTyped t2]) in
    let ord = Ordering.default signature in
    among
      [ mk_less t1 t2
      ; mk_lesseq t1 t2
      ; mk_eq ~ord t1 t2
      ; mk_neq ~ord t1 t2
      ]
  *)
end

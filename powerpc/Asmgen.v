(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Translation from Mach to PPC. *)

Require Import Coqlib.
Require Import Errors.
Require Import AST.
Require Import Integers.
Require Import Floats.
Require Import Op.
Require Import Locations.
Require Import Mach.
Require Import Asm.

Open Local Scope string_scope.
Open Local Scope error_monad_scope.

(** The code generation functions take advantage of several
  characteristics of the [Mach] code generated by earlier passes of the
  compiler, mostly that argument and result registers are of the correct
  types.  These properties are true by construction, but it's easier to
  recheck them during code generation and fail if they do not hold. *)

(** Extracting integer or float registers. *)

Definition ireg_of (r: mreg) : res ireg :=
  match preg_of r with IR mr => OK mr | _ => Error(msg "Asmgen.ireg_of") end.

Definition freg_of (r: mreg) : res freg :=
  match preg_of r with FR mr => OK mr | _ => Error(msg "Asmgen.freg_of") end.

(** Decomposition of integer constants.  As noted in file [Asm],
  immediate arguments to PowerPC instructions must fit into 16 bits,
  and are interpreted after zero extension, sign extension, or
  left shift by 16 bits, depending on the instruction.  Integer
  constants that do not fit must be synthesized using two
  processor instructions.  The following functions decompose
  arbitrary 32-bit integers into two 16-bit halves (high and low
  halves).  They satisfy the following properties:
- [low_u n] is an unsigned 16-bit integer;
- [low_s n] is a signed 16-bit integer;
- [(high_u n) << 16 | low_u n] equals [n];
- [(high_s n) << 16 + low_s n] equals [n].
*)

Definition low_u (n: int) := Int.and n (Int.repr 65535).
Definition high_u (n: int) := Int.shru n (Int.repr 16).
Definition low_s (n: int) := Int.sign_ext 16 n.
Definition high_s (n: int) := Int.shru (Int.sub n (low_s n)) (Int.repr 16).

(** Smart constructors for arithmetic operations involving
  a 32-bit integer constant.  Depending on whether the
  constant fits in 16 bits or not, one or several instructions
  are generated as required to perform the operation
  and prepended to the given instruction sequence [k]. *)

Definition loadimm (r: ireg) (n: int) (k: code) :=
  if Int.eq (high_s n) Int.zero then
    Paddi r GPR0 (Cint n) :: k
  else if Int.eq (low_s n) Int.zero then
    Paddis r GPR0 (Cint (high_s n)) :: k
  else
    Paddis r GPR0 (Cint (high_u n)) ::
    Pori r r (Cint (low_u n)) :: k.

Definition addimm (r1 r2: ireg) (n: int) (k: code) :=
  if Int.eq (high_s n) Int.zero then
    Paddi r1 r2 (Cint n) :: k
  else if Int.eq (low_s n) Int.zero then
    Paddis r1 r2 (Cint (high_s n)) :: k
  else
    Paddis r1 r2 (Cint (high_s n)) ::
    Paddi r1 r1 (Cint (low_s n)) :: k.

Definition andimm_base (r1 r2: ireg) (n: int) (k: code) :=
  if Int.eq (high_u n) Int.zero then
    Pandi_ r1 r2 (Cint n) :: k
  else if Int.eq (low_u n) Int.zero then
    Pandis_ r1 r2 (Cint (high_u n)) :: k
  else
    loadimm GPR0 n (Pand_ r1 r2 GPR0 :: k).

Definition andimm (r1 r2: ireg) (n: int) (k: code) :=
  if is_rlw_mask n then
    Prlwinm r1 r2 Int.zero n :: k
  else
    andimm_base r1 r2 n k.

Definition orimm (r1 r2: ireg) (n: int) (k: code) :=
  if Int.eq (high_u n) Int.zero then
    Pori r1 r2 (Cint n) :: k
  else if Int.eq (low_u n) Int.zero then
    Poris r1 r2 (Cint (high_u n)) :: k
  else
    Poris r1 r2 (Cint (high_u n)) ::
    Pori r1 r1 (Cint (low_u n)) :: k.

Definition xorimm (r1 r2: ireg) (n: int) (k: code) :=
  if Int.eq (high_u n) Int.zero then
    Pxori r1 r2 (Cint n) :: k
  else if Int.eq (low_u n) Int.zero then
    Pxoris r1 r2 (Cint (high_u n)) :: k
  else
    Pxoris r1 r2 (Cint (high_u n)) ::
    Pxori r1 r1 (Cint (low_u n)) :: k.

Definition rolm (r1 r2: ireg) (amount mask: int) (k: code) :=
  if is_rlw_mask mask then
    Prlwinm r1 r2 amount mask :: k
  else
    Prlwinm r1 r2 amount Int.mone :: andimm_base r1 r1 mask k.

(** Accessing slots in the stack frame.  *)

Definition accessind {A: Type}
       (instr1: A -> constant -> ireg -> instruction)
       (instr2: A -> ireg -> ireg -> instruction)
       (base: ireg) (ofs: int) (r: A) (k: code) :=
  if Int.eq (high_s ofs) Int.zero 
  then instr1 r (Cint ofs) base :: k
  else loadimm GPR0 ofs (instr2 r base GPR0 :: k).

Definition loadind (base: ireg) (ofs: int) (ty: typ) (dst: mreg) (k: code) :=
  match ty, preg_of dst with
  | Tint, IR r => OK(accessind Plwz Plwzx base ofs r k)
  | Tany32, IR r => OK(accessind Plwz_a Plwzx_a base ofs r k)
  | Tsingle, FR r => OK(accessind Plfs Plfsx base ofs r k)
  | Tfloat, FR r => OK(accessind Plfd Plfdx base ofs r k)
  | Tany64, FR r => OK(accessind Plfd_a Plfdx_a base ofs r k)
  | _, _ => Error (msg "Asmgen.loadind")
  end.

Definition storeind (src: mreg) (base: ireg) (ofs: int) (ty: typ) (k: code) :=
  match ty, preg_of src with
  | Tint, IR r => OK(accessind Pstw Pstwx base ofs r k)
  | Tany32, IR r => OK(accessind Pstw_a Pstwx_a base ofs r k)
  | Tsingle, FR r => OK(accessind Pstfs Pstfsx base ofs r k)
  | Tfloat, FR r => OK(accessind Pstfd Pstfdx base ofs r k)
  | Tany64, FR r => OK(accessind Pstfd_a Pstfdx_a base ofs r k)
  | _, _ => Error (msg "Asmgen.storeind")
  end.

(** Constructor for a floating-point comparison.  The PowerPC has
  a single [fcmpu] instruction to compare floats, which sets
  bits 0, 1 and 2 of the condition register to reflect ``less'',
  ``greater'' and ``equal'' conditions, respectively.
  The ``less or equal'' and ``greater or equal'' conditions must be
  synthesized by a [cror] instruction that computes the logical ``or''
  of the corresponding two conditions. *)

Definition floatcomp (cmp: comparison) (r1 r2: freg) (k: code) :=
  Pfcmpu r1 r2 ::
  match cmp with
  | Cle => Pcror CRbit_3 CRbit_2 CRbit_0 :: k
  | Cge => Pcror CRbit_3 CRbit_2 CRbit_1 :: k
  | _ => k
  end.

(** Translation of a condition.  Prepends to [k] the instructions
  that evaluate the condition and leave its boolean result in one of
  the bits of the condition register.  The bit in question is
  determined by the [crbit_for_cond] function. *)

Definition transl_cond
              (cond: condition) (args: list mreg) (k: code) :=
  match cond, args with
  | Ccomp c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; OK (Pcmpw r1 r2 :: k)
  | Ccompu c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; OK (Pcmplw r1 r2 :: k)
  | Ccompimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      if Int.eq (high_s n) Int.zero then
        OK (Pcmpwi r1 (Cint n) :: k)
      else
        OK (loadimm GPR0 n (Pcmpw r1 GPR0 :: k))
  | Ccompuimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      if Int.eq (high_u n) Int.zero then
        OK (Pcmplwi r1 (Cint n) :: k)
      else
        OK (loadimm GPR0 n (Pcmplw r1 GPR0 :: k))
  | Ccompf cmp, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; OK (floatcomp cmp r1 r2 k)
  | Cnotcompf cmp, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; OK (floatcomp cmp r1 r2 k)
  | Cmaskzero n, a1 :: nil =>
      do r1 <- ireg_of a1; OK (andimm_base GPR0 r1 n k)
  | Cmasknotzero n, a1 :: nil =>
      do r1 <- ireg_of a1; OK (andimm_base GPR0 r1 n k)
  | _, _ =>
      Error(msg "Asmgen.transl_cond")
  end.

(*  CRbit_0 = Less
    CRbit_1 = Greater
    CRbit_2 = Equal
    CRbit_3 = Other *)

Definition crbit_for_icmp (cmp: comparison) :=
  match cmp with
  | Ceq => (CRbit_2, true)
  | Cne => (CRbit_2, false)
  | Clt => (CRbit_0, true)
  | Cle => (CRbit_1, false)
  | Cgt => (CRbit_1, true)
  | Cge => (CRbit_0, false)
  end.

Definition crbit_for_fcmp (cmp: comparison) :=
  match cmp with
  | Ceq => (CRbit_2, true)
  | Cne => (CRbit_2, false)
  | Clt => (CRbit_0, true)
  | Cle => (CRbit_3, true)
  | Cgt => (CRbit_1, true)
  | Cge => (CRbit_3, true)
  end.

Definition crbit_for_cond (cond: condition) :=
  match cond with
  | Ccomp cmp => crbit_for_icmp cmp
  | Ccompu cmp => crbit_for_icmp cmp
  | Ccompimm cmp n => crbit_for_icmp cmp
  | Ccompuimm cmp n => crbit_for_icmp cmp
  | Ccompf cmp => crbit_for_fcmp cmp
  | Cnotcompf cmp => let p := crbit_for_fcmp cmp in (fst p, negb (snd p))
  | Cmaskzero n => (CRbit_2, true)
  | Cmasknotzero n => (CRbit_2, false)
  end.

(** Recognition of comparisons [>= 0] and [< 0]. *)

Inductive condition_class: condition -> list mreg -> Type :=
  | condition_eq0:
      forall n r, n = Int.zero -> condition_class (Ccompimm Ceq n) (r :: nil)
  | condition_ne0:
      forall n r, n = Int.zero -> condition_class (Ccompimm Cne n) (r :: nil)
  | condition_ge0:
      forall n r, n = Int.zero -> condition_class (Ccompimm Cge n) (r :: nil)
  | condition_lt0:
      forall n r, n = Int.zero -> condition_class (Ccompimm Clt n) (r :: nil)
  | condition_default:
      forall c rl, condition_class c rl.

Definition classify_condition (c: condition) (args: list mreg): condition_class c args :=
  match c as z1, args as z2 return condition_class z1 z2 with
  | Ccompimm Ceq n, r :: nil =>
      match Int.eq_dec n Int.zero with
      | left EQ => condition_eq0 n r EQ
      | right _ => condition_default (Ccompimm Ceq n) (r :: nil)
      end
  | Ccompimm Cne n, r :: nil =>
      match Int.eq_dec n Int.zero with
      | left EQ => condition_ne0 n r EQ
      | right _ => condition_default (Ccompimm Cne n) (r :: nil)
      end
  | Ccompimm Cge n, r :: nil =>
      match Int.eq_dec n Int.zero with
      | left EQ => condition_ge0 n r EQ
      | right _ => condition_default (Ccompimm Cge n) (r :: nil)
      end
  | Ccompimm Clt n, r :: nil =>
      match Int.eq_dec n Int.zero with
      | left EQ => condition_lt0 n r EQ
      | right _ => condition_default (Ccompimm Clt n) (r :: nil)
      end
  | x, y =>
      condition_default x y
  end.

(** Translation of a condition operator.  The generated code sets
  the [r] target register to 0 or 1 depending on the truth value of the
  condition. *)

Definition transl_cond_op
             (cond: condition) (args: list mreg) (r: mreg) (k: code) :=
  do r' <- ireg_of r;
  match classify_condition cond args with
  | condition_eq0 _ a _ =>
      do a' <- ireg_of a;
      OK (Psubfic GPR0 a' (Cint Int.zero) ::
          Padde r' GPR0 a' :: k)
  | condition_ne0 _ a _ =>
      do a' <- ireg_of a;
      OK (Paddic GPR0 a' (Cint Int.mone) ::
          Psubfe r' GPR0 a' :: k)
  | condition_ge0 _ a _ =>
      do a' <- ireg_of a;
      OK (Prlwinm r' a' Int.one Int.one ::
          Pxori r' r' (Cint Int.one) :: k)
  | condition_lt0 _ a _ =>
      do a' <- ireg_of a;
      OK (Prlwinm r' a' Int.one Int.one :: k)
  | condition_default _ _ =>
      let p := crbit_for_cond cond in
      transl_cond cond args
        (Pmfcrbit r' (fst p) ::
         if snd p
         then k
         else Pxori r' r' (Cint Int.one) :: k)
  end.

(** Translation of the arithmetic operation [r <- op(args)].
  The corresponding instructions are prepended to [k]. *)

Definition csymbol_high (s: ident) (ofs: int) (rel: bool) :=
  if rel then Csymbol_rel_high s ofs else Csymbol_high s ofs.
Definition csymbol_low (s: ident) (ofs: int) (rel: bool) :=
  if rel then Csymbol_rel_low s ofs else Csymbol_low s ofs.

Definition transl_op
              (op: operation) (args: list mreg) (res: mreg) (k: code) :=
  match op, args with
  | Omove, a1 :: nil =>
      match preg_of res, preg_of a1 with
      | IR r, IR a => OK (Pmr r a :: k)
      | FR r, FR a => OK (Pfmr r a :: k)
      |  _   ,  _    => Error(msg "Asmgen.Omove")
      end
  | Ointconst n, nil =>
      do r <- ireg_of res; OK (loadimm r n k)
  | Ofloatconst f, nil =>
      do r <- freg_of res; OK (Plfi r f :: k)
  | Osingleconst f, nil =>
      do r <- freg_of res; OK (Plfis r f :: k)
  | Oaddrsymbol s ofs, nil =>
      do r <- ireg_of res;
      OK (if symbol_is_small_data s ofs then
           Paddi r GPR0 (Csymbol_sda s ofs) :: k
         else
           let rel := symbol_is_rel_data s ofs in
           Paddis r GPR0 (csymbol_high s ofs rel) ::
           Paddi r r (csymbol_low s ofs rel) :: k)
  | Oaddrstack n, nil =>
      do r <- ireg_of res; OK (addimm r GPR1 n k)
  | Ocast8signed, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res; OK (Pextsb r r1 :: k)
  | Ocast16signed, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res; OK (Pextsh r r1 :: k)
  | Oadd, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Padd r r1 r2 :: k)
  | Oaddimm n, a1 :: nil =>
       do r1 <- ireg_of a1; do r <- ireg_of res; OK (addimm r r1 n k)
  | Oaddsymbol s ofs, a1 :: nil =>
       do r1 <- ireg_of a1; do r <- ireg_of res;
       OK (if symbol_is_small_data s ofs then
             Paddi GPR0 GPR0 (Csymbol_sda s ofs) ::
             Padd r r1 GPR0 :: k
           else if symbol_is_rel_data s ofs then
             Paddis GPR0 GPR0 (Csymbol_rel_high s ofs) ::
             Padd r r1 GPR0 ::
             Paddi r r (Csymbol_rel_low s ofs) :: k
           else
             Paddis r r1 (Csymbol_high s ofs) ::
             Paddi r r (Csymbol_low s ofs) :: k)
  | Osub, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Psubfc r r2 r1 :: k)
  | Osubimm n, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (if Int.eq (high_s n) Int.zero then
           Psubfic r r1 (Cint n) :: k
         else
          loadimm GPR0 n (Psubfc r r1 GPR0 :: k))
  | Omul, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pmullw r r1 r2 :: k)
  | Omulimm n, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (if Int.eq (high_s n) Int.zero then
           Pmulli r r1 (Cint n) :: k
         else
           loadimm GPR0 n (Pmullw r r1 GPR0 :: k))
  | Omulhs, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pmulhw r r1 r2 :: k)
  | Omulhu, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pmulhwu r r1 r2 :: k)
  | Odiv, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pdivw r r1 r2 :: k)
  | Odivu, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pdivwu r r1 r2 :: k)
  | Oand, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pand_ r r1 r2 :: k)
  | Oandimm n, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (andimm r r1 n k)
  | Oor, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Por r r1 r2 :: k)
  | Oorimm n, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (orimm r r1 n k)
  | Oxor, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pxor r r1 r2 :: k)
  | Oxorimm n, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (xorimm r r1 n k)
  | Onot, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (Pnor r r1 r1 :: k)
  | Onand, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pnand r r1 r2 :: k)
  | Onor, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pnor r r1 r2 :: k)
  | Onxor, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Peqv r r1 r2 :: k)
  | Oandc, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pandc r r1 r2 :: k)
  | Oorc, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Porc r r1 r2 :: k)
  | Oshl, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Pslw r r1 r2 :: k)
  | Oshr, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Psraw r r1 r2 :: k)
  | Oshrimm n, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (Psrawi r r1 n :: k)
  | Oshrximm n, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (Psrawi r r1 n :: Paddze r r :: k)
  | Oshru, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Psrw r r1 r2 :: k)
  | Orolm amount mask, a1 :: nil =>
      do r1 <- ireg_of a1; do r <- ireg_of res;
      OK (rolm r r1 amount mask k)
  | Oroli amount mask, a1 :: a2 :: nil =>
      assertion (mreg_eq a1 res);
      do r2 <- ireg_of a2; do r <- ireg_of res;
      OK (Prlwimi r r2 amount mask :: k)
  | Onegf, a1 :: nil =>
      do r1 <- freg_of a1; do r <- freg_of res;
      OK (Pfneg r r1 :: k)
  | Oabsf, a1 :: nil =>
      do r1 <- freg_of a1; do r <- freg_of res;
      OK (Pfabs r r1 :: k)
  | Oaddf, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; do r <- freg_of res;
      OK (Pfadd r r1 r2 :: k)
  | Osubf, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; do r <- freg_of res;
      OK (Pfsub r r1 r2 :: k)
  | Omulf, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; do r <- freg_of res;
      OK (Pfmul r r1 r2 :: k)
  | Odivf, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; do r <- freg_of res;
      OK (Pfdiv r r1 r2 :: k)
  | Onegfs, a1 :: nil =>
      do r1 <- freg_of a1; do r <- freg_of res;
      OK (Pfnegs r r1 :: k)
  | Oabsfs, a1 :: nil =>
      do r1 <- freg_of a1; do r <- freg_of res;
      OK (Pfabss r r1 :: k)
  | Oaddfs, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; do r <- freg_of res;
      OK (Pfadds r r1 r2 :: k)
  | Osubfs, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; do r <- freg_of res;
      OK (Pfsubs r r1 r2 :: k)
  | Omulfs, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; do r <- freg_of res;
      OK (Pfmuls r r1 r2 :: k)
  | Odivfs, a1 :: a2 :: nil =>
      do r1 <- freg_of a1; do r2 <- freg_of a2; do r <- freg_of res;
      OK (Pfdivs r r1 r2 :: k)
  | Osingleoffloat, a1 :: nil =>
      do r1 <- freg_of a1; do r <- freg_of res;
      OK (Pfrsp r r1 :: k)
  | Ofloatofsingle, a1 :: nil =>
      do r1 <- freg_of a1; do r <- freg_of res;
      OK (Pfxdp r r1 :: k)
  | Ointoffloat, a1 :: nil =>
      do r1 <- freg_of a1; do r <- ireg_of res;
      OK (Pfcti r r1 :: k)
  | Ofloatofwords, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2; do r <- freg_of res;
      OK (Pfmake r r1 r2 :: k)
  | Ocmp cmp, _ =>
      transl_cond_op cmp args res k
  | _, _ =>
      Error(msg "Asmgen.transl_op")
  end.

(** Translation of memory accesses: loads, and stores. *)

Definition int_temp_for (r: mreg) :=
  if mreg_eq r R12 then GPR11 else GPR12.

Definition transl_memory_access
     (mk1: constant -> ireg -> instruction)
     (mk2: ireg -> ireg -> instruction)
     (addr: addressing) (args: list mreg) 
     (temp: ireg) (k: code) :=
  match addr, args with
  | Aindexed ofs, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (if Int.eq (high_s ofs) Int.zero then
           mk1 (Cint ofs) r1 :: k
         else
           Paddis temp r1 (Cint (high_s ofs)) ::
           mk1 (Cint (low_s ofs)) temp :: k)
  | Aindexed2, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (mk2 r1 r2 :: k)
  | Aglobal symb ofs, nil =>
      OK (if symbol_is_small_data symb ofs then
           mk1 (Csymbol_sda symb ofs) GPR0 :: k
         else
           let rel := symbol_is_rel_data symb ofs in
           Paddis temp GPR0 (csymbol_high symb ofs rel) ::
           mk1 (csymbol_low symb ofs rel) temp :: k)
  | Abased symb ofs, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (if symbol_is_small_data symb ofs then
            Paddi GPR0 GPR0 (Csymbol_sda symb ofs) ::
            mk2 r1 GPR0 :: k
          else if symbol_is_rel_data symb ofs then
            Paddis GPR0 GPR0 (Csymbol_rel_high symb ofs) ::
            Padd temp r1 GPR0 ::
            mk1 (Csymbol_rel_low symb ofs) temp :: k
          else
            Paddis temp r1 (Csymbol_high symb ofs) ::
            mk1 (Csymbol_low symb ofs) temp :: k)
  | Ainstack ofs, nil =>
      OK (if Int.eq (high_s ofs) Int.zero then
           mk1 (Cint ofs) GPR1 :: k
         else
           Paddis temp GPR1 (Cint (high_s ofs)) ::
           mk1 (Cint (low_s ofs)) temp :: k)
  | _, _ =>
      Error(msg "Asmgen.transl_memory_access")
  end.

Definition transl_load (chunk: memory_chunk) (addr: addressing)
                       (args: list mreg) (dst: mreg) (k: code) :=
  match chunk with
  | Mint8signed =>
      do r <- ireg_of dst;
      transl_memory_access (Plbz r) (Plbzx r) addr args GPR12 (Pextsb r r :: k)
  | Mint8unsigned =>
      do r <- ireg_of dst;
      transl_memory_access (Plbz r) (Plbzx r) addr args GPR12 k
  | Mint16signed =>
      do r <- ireg_of dst;
      transl_memory_access (Plha r) (Plhax r) addr args GPR12 k
  | Mint16unsigned =>
      do r <- ireg_of dst;
      transl_memory_access (Plhz r) (Plhzx r) addr args GPR12 k
  | Mint32 =>
      do r <- ireg_of dst;
      transl_memory_access (Plwz r) (Plwzx r) addr args GPR12 k
  | Mfloat32 =>
      do r <- freg_of dst;
      transl_memory_access (Plfs r) (Plfsx r) addr args GPR12 k
  | Mfloat64 =>
      do r <- freg_of dst;
      transl_memory_access (Plfd r) (Plfdx r) addr args GPR12 k
  | _ =>
      Error (msg "Asmgen.transl_load")
  end.

Definition transl_store (chunk: memory_chunk) (addr: addressing)
                        (args: list mreg) (src: mreg) (k: code) :=
  let temp := int_temp_for src in
  match chunk with
  | Mint8signed | Mint8unsigned =>
      do r <- ireg_of src;
      transl_memory_access (Pstb r) (Pstbx r) addr args temp k
  | Mint16signed | Mint16unsigned =>
      do r <- ireg_of src;
      transl_memory_access (Psth r) (Psthx r) addr args temp k
  | Mint32  =>
      do r <- ireg_of src;
      transl_memory_access (Pstw r) (Pstwx r) addr args temp k
  | Mfloat32 =>
      do r <- freg_of src;
      transl_memory_access (Pstfs r) (Pstfsx r) addr args temp k
  | Mfloat64 =>
      do r <- freg_of src;
      transl_memory_access (Pstfd r) (Pstfdx r) addr args temp k
  | _ =>
      Error (msg "Asmgen.transl_store")
  end.

(** Translation of arguments to annotations *)

Definition transl_annot_param (p: Mach.annot_param) : Asm.annot_param :=
  match p with
  | Mach.APreg r => APreg (preg_of r)
  | Mach.APstack chunk ofs => APstack chunk ofs
  end.

(** Translation of a Mach instruction. *)

Definition transl_instr (f: Mach.function) (i: Mach.instruction)
                        (r11_is_parent: bool) (k: code) :=
  match i with
  | Mgetstack ofs ty dst =>
      loadind GPR1 ofs ty dst k
  | Msetstack src ofs ty =>
      storeind src GPR1 ofs ty k
  | Mgetparam ofs ty dst =>
      if r11_is_parent then
        loadind GPR11 ofs ty dst k
      else
        (do k1 <- loadind GPR11 ofs ty dst k;
         loadind GPR1 f.(fn_link_ofs) Tint R11 k1)
  | Mop op args res =>
      transl_op op args res k
  | Mload chunk addr args dst =>
      transl_load chunk addr args dst k
  | Mstore chunk addr args src =>
      transl_store chunk addr args src k
  | Mcall sig (inl r) =>
      do r1 <- ireg_of r; OK (Pmtctr r1 :: Pbctrl sig :: k)
  | Mcall sig (inr symb) =>
      OK (Pbl symb sig :: k)
  | Mtailcall sig (inl r) =>
      do r1 <- ireg_of r;
      OK (Pmtctr r1 ::
          Plwz GPR0 (Cint f.(fn_retaddr_ofs)) GPR1 ::
          Pmtlr GPR0 ::
          Pfreeframe f.(fn_stacksize) f.(fn_link_ofs) :: 
          Pbctr sig :: k)
  | Mtailcall sig (inr symb) =>
      OK (Plwz GPR0 (Cint f.(fn_retaddr_ofs)) GPR1 ::
          Pmtlr GPR0 ::
          Pfreeframe f.(fn_stacksize) f.(fn_link_ofs) :: 
          Pbs symb sig :: k)
  | Mbuiltin ef args res =>
      OK (Pbuiltin ef (map preg_of args) (map preg_of res) :: k)
  | Mannot ef args =>
      OK (Pannot ef (map transl_annot_param args) :: k)
  | Mlabel lbl =>
      OK (Plabel lbl :: k)
  | Mgoto lbl =>
      OK (Pb lbl :: k)
  | Mcond cond args lbl =>
      let p := crbit_for_cond cond in
      transl_cond cond args
        (if (snd p) then Pbt (fst p) lbl :: k else Pbf (fst p) lbl :: k)
  | Mjumptable arg tbl =>
      do r <- ireg_of arg;
      OK (Pbtbl r tbl :: k)
  | Mreturn =>
      OK (Plwz GPR0 (Cint f.(fn_retaddr_ofs)) GPR1 ::
          Pmtlr GPR0 ::
          Pfreeframe f.(fn_stacksize) f.(fn_link_ofs) ::
          Pblr :: k)
  end.

(** Translation of a code sequence *)

Definition it1_is_parent (before: bool) (i: Mach.instruction) : bool :=
  match i with
  | Msetstack src ofs ty => before
  | Mgetparam ofs ty dst => negb (mreg_eq dst R11)
  | Mop Omove args res => before && negb (mreg_eq res R11)
  | _ => false
  end.

(** This is the naive definition that we no longer use because it
  is not tail-recursive.  It is kept as specification. *)

Fixpoint transl_code (f: Mach.function) (il: list Mach.instruction) (it1p: bool) :=
  match il with
  | nil => OK nil
  | i1 :: il' =>
      do k <- transl_code f il' (it1_is_parent it1p i1);
      transl_instr f i1 it1p k
  end.

(** This is an equivalent definition in continuation-passing style
  that runs in constant stack space. *)

Fixpoint transl_code_rec (f: Mach.function) (il: list Mach.instruction)
                         (it1p: bool) (k: code -> res code) :=
  match il with
  | nil => k nil
  | i1 :: il' =>
      transl_code_rec f il' (it1_is_parent it1p i1)
        (fun c1 => do c2 <- transl_instr f i1 it1p c1; k c2)
  end.

Definition transl_code' (f: Mach.function) (il: list Mach.instruction) (it1p: bool) :=
  transl_code_rec f il it1p (fun c => OK c).

(** Translation of a whole function.  Note that we must check
  that the generated code contains less than [2^32] instructions,
  otherwise the offset part of the [PC] code pointer could wrap
  around, leading to incorrect executions. *)

Definition transl_function (f: Mach.function) :=
  do c <- transl_code' f f.(Mach.fn_code) false;
  OK (mkfunction f.(Mach.fn_sig)
       (Pallocframe f.(fn_stacksize) f.(fn_link_ofs) ::
        Pmflr GPR0 ::
        Pstw GPR0 (Cint f.(fn_retaddr_ofs)) GPR1 ::
        Pcfi_rel_offset f.(fn_retaddr_ofs) :: c)).

Definition transf_function (f: Mach.function) : res Asm.function :=
  do tf <- transl_function f;
  if zlt Int.max_unsigned (list_length_z tf.(fn_code))
  then Error (msg "code size exceeded")
  else OK tf.

Definition transf_fundef (f: Mach.fundef) : res Asm.fundef :=
  transf_partial_fundef transf_function f.

Definition transf_program (p: Mach.program) : res Asm.program :=
  transform_partial_program transf_fundef p.


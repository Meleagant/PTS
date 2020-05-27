open Ast
open Reduc
open Printer
open Options


module B = Buffer

let is_sort syst s =
  IdSet.mem s syst.sorts

(** [ident] coresponds to the current indentation in Typing progress printing
 * *)
let ident = ref ""
let add () = ident := "|  "^(!ident)
let sub () = ident := String.(sub !ident 0 (length !ident -3))

let subst x t t' = 
  let res = subst x t t' in
  let _ = if !type_debug then Printf.printf "%s%a{%s ← %a} = %a\n"
    !ident
    pretty_printer t'
    x
    pretty_printer t
    pretty_printer res in
  res

exception Def_found of ident

  (** [type_check syst def env term]  returns a [typ] such that the judgment 
   [def];[env]⊢ [term]:[typ] in [syst] holds *)
let rec type_check syst def env term : term * typing_tree  =
  let _ = add () in
  let _ = if !type_debug then
    let _ = Printf.printf "%strying to type : %a\n" 
      !ident pretty_printer term in
    let _ = Printf.printf "%senv = %a\n" 
      !ident print_typing_env env in
    let _ = Printf.printf "%sdef = %a\n" 
      !ident print_typing_def def 
    in ()
  in
  match term, env with
  (* Axiom Rule *)
  | Var s, [] ->
  begin
    let _ = if not (is_sort syst s) then
      Printf.printf "Error : %s ∉ Γ\n" s in
    let _ = if !type_debug then Printf.printf "%sApply Axiom\n" !ident in
      try 
        let s' = IdMap.find s syst.axioms in
        let j = def, [], Var s, Var s' in
        let _ = sub () in
        Var s', Axiom j
      with Not_found ->
        let err = Printf.sprintf "(%s, _) ∉ 𝒜 " s in
        failwith err
  end
  (* Start Rule *)
  | Var x, (y, typ)::new_env when x = y ->
  begin
    let _ = if !type_debug then Printf.printf "%sApply Start\n" !ident in
    let new_def = IdMap.remove y def in
    let _, tree = type_check syst new_def new_env typ in
    let j = def, env, term, typ in 
    let _ = sub () in
    typ, Start (tree, j)
  end
  (* Weaken Rule *)
  | Var x, env ->
      weaken syst def env term
  | Lam (x, _, _), env
  | Let (x, _, _), env 
  | Prod (x, _, _), env when (List.mem_assoc x env) ->
      weaken syst def env term
  | Lam (x, t1, t2), env ->
      let _ = if !type_debug then 
        Printf.printf "%sApply abstraction\n" !ident in
      let _ = assert (not (is_sort syst x)) in
      let _, tree1 = type_check syst def env t1 in
      let new_env = (x, t1) :: env in
      let typ2, tree2 = type_check syst def new_env t2 in
      let _, tree3 = type_check syst def new_env typ2 in
      let typ_res = Prod (x, t1, typ2) in
      let j = def, env, term, typ_res in
      let _ = sub () in
      find_def syst def env typ_res (Abstraction (tree1, tree2, tree3, j))
  | Let (id, d, t), env ->
      let _ = if !type_debug then 
        Printf.printf "%sApply Let\n" !ident in
      let tyd, tree1 = type_check syst def env d in
      let new_def = IdMap.add id d def in
      let new_env = (id, tyd)::env in
      let typ_res, tree2 = type_check syst new_def new_env t in
      let j = def, env, term, typ_res in
      let _ = sub () in
      typ_res, LetIntro (tree1, tree2, j)
  | Prod (x, t1, t2), env ->
  begin
      let _ = if !type_debug then Printf.printf "%sApply Product\n" !ident in
      let _ = assert (not (is_sort syst x)) in
      let s1, tree1 = type_check syst def env t1 in
      let new_env = (x, t1) :: env in
      let s2, tree2 = type_check syst def new_env t2 in
      match s1, s2 with
      | Var s1, Var s2 when is_sort syst s1 && is_sort syst s2 ->
      begin
          try 
            let s3 = Id2Map.find (s1, s2) syst.rules in
            let typ_res = Var s3 in
            let j = def, env, term, typ_res in
            let _ = sub () in
            typ_res, Product (tree1, tree2, j)
          with
          | Not_found ->
              let err = Printf.sprintf "(%s, %s, _) ∉ ℛ " s1 s2 in
              failwith err
      end
      | _ -> assert false

  end
  | App (t1, t2), env ->
      let _ = if !type_debug then 
        Printf.printf "%sApply Application\n" !ident in
      let ty1, tree1 = type_check syst def env t1 in
      let ty2, tree2 = type_check syst def env t2 in
      match ty1 with
      | Prod (x, ty1', ty_res) ->
          let _ = conversion syst def env ty1' ty2 in
          let typ_res = subst x t2 ty_res in
          let j = def, env, term, typ_res in
          let _ = sub () in
          typ_res, Application (tree1, tree2, j)
      | Var id when IdMap.mem id def ->
      begin
          let ty1 = IdMap.find id def in 
          match ty1 with
          | Prod (x, ty1', ty_res) ->
              let _ = conversion syst def env ty1' ty2 in
              let typ_res = subst x t2 ty_res in
              let j = def, env, term, typ_res in
              let _ = sub () in
              typ_res, Application (tree1, tree2, j)
          | t -> 
              let _ = Printf.eprintf 
                  "%s is defined as %a but a type product was expected"
                  id
                  pretty_printer t
              in exit 1
      end
      | _ -> assert false

and weaken syst def env term: term * typing_tree =
  let y, typ_y = List.hd env in
  let new_env = List.tl env in
  let new_def = IdMap.remove y def in
  let typ , tree1 = type_check syst new_def new_env term in
  let _ , tree2 = type_check syst new_def new_env typ_y in
  let j = def, env, term, typ in
  typ, Weakening (y, tree1, tree2, j)

and find_def syst def env typ tree: term * typing_tree =
  try 
    let _  = IdMap.iter
      (fun id term -> if (alpha_equiv def term typ) then raise (Def_found id))
      def in
    typ, tree
  with
  | Def_found id ->
      let _ = if !type_debug then Printf.printf "%sWe match %a ~α %s\n" !ident
        pretty_printer typ id in
      let new_typ = Var id in
      let def, env, term, typ = get_judgment tree in
      let j = def, env, term, new_typ in
      let _, tree2 = type_check syst def env new_typ in
      new_typ, Conversion (tree, typ, new_typ, tree2, j)


and conversion syst def env t' t =
  let _ = if !type_debug then
    let _ = Printf.printf "%strying to convert : \n%s  %a\n%s  %a\n" 
      !ident 
      !ident pretty_printer t'
      !ident pretty_printer t in
    let _ = Printf.printf "%senv =%a\n" !ident print_typing_env env in
    let _ = Printf.printf "%sApply Conversion\n" !ident in
    let _ = type_check syst def env t' in   ()
  in
  let nf_t = get_nf t in
  let nf_t' = get_nf t' in
  if alpha_equiv def nf_t nf_t' then
    ()
  else 
    let _ = Printf.printf "%a !~α %a\n"
      pretty_printer t'
      pretty_printer t in
    failwith "Failure in conversion rule"

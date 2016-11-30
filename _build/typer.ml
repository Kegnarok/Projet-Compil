open Ast
open Loc
open Typ
open Utils
open Printer

module A = AST
open A
module T = TypedAST

(** General error functions *)

let error msg loc =
  raise (Typing_error (msg, loc))
    

let ensure_record typ loc =
  match typ with
  | Trecord r -> r
  | _ -> error "Only a record can have an access type" loc

let ensure_defined r loc =
  match r with
  | Decl s -> error (Format.sprintf "Record %s has not been defined yet" s) loc
  | Def r -> r

let wrong_type t_exp t_proc loc =
  let print_typ_to_str = print_to_string print_typ in
  error (Format.sprintf
           "This expression has type %s but was expected of type %s"
           (print_typ_to_str t_proc) (print_typ_to_str t_exp)) loc


let ensure_equal t1 t2 loc2 =
  if t1 <> t2 then wrong_type t1 t2 loc2

let ensure_equiv t1 t2 loc2 =
  match (t1, t2) with
  | (Tnull, Taccess _) | (Taccess _, Tnull) -> ()
  | _ -> ensure_equal t1 t2 loc2


let is_access = function
  | Taccess _ -> true
  | _ -> false

(** The environment module *)

module Env : sig
  type t

  val new_env : t

  val get_id_type : t -> ident -> typ
  val get_typ_annot_type : t -> ident -> typ

  val set_id_type : t -> ident_desc -> typ -> t
  val set_typ_annot_type : t -> ident_desc -> typ -> t

  val ensure_all_def : t -> loc -> unit
end = struct
  module Smap = Map.Make(String)

  type map = typ Smap.t (* maps an identifier with its type *)
  type t = map * map



  let add_in (ts, r) = Tproc_func (List.map (fun t -> (t, In)) ts, r)
  let reserved = [("character'val", add_in ([Tint],  Tchar));
                  ("put",           add_in ([Tchar], Tnull));
                  ("new_line",      add_in ([],      Tnull));
                 ]

  let unops    = [("not",           add_in ([Tbool], Tbool))] 
  
  let type_binop = function
    | Beq | Bneq ->                            assert false
    | Blt | Bleq | Bgt | Bgeq ->               ([Tint;  Tint],  Tbool)
    | Bplus | Bminus | Btimes | Bdiv | Brem -> ([Tint;  Tint],  Tint)
    | Band | Band_then | Bor | Bor_else ->     ([Tbool; Tbool], Tbool)
  let binops = List.map (fun b -> (print_to_string print_binop b,
                                   add_in (type_binop b)))
                 [Blt; Bleq; Bgt; Bgeq; Bplus; Bminus; Btimes; Bdiv; Brem;
                  Band; Band_then; Bor; Bor_else]
                 
  let new_env = (Smap.of_list (reserved @ unops @ binops),
                 Smap.of_list [("integer",       Tint);
                               ("character",     Tchar);
                               ("boolean",       Tbool);
                              ])


  let search_map map key name =
    try
      Smap.find key.desc map
    with
    | Not_found -> error (Format.sprintf "Unknown %s: %s" name key.desc) key.deco

  let get_id_type (id_env, _) id =
    search_map id_env id "identifier"

  let get_typ_annot_type (_, typ_env) typ =
    search_map typ_env typ "type"


  let set_id_type (id_env, typ_env) id typ =
    (Smap.add id typ id_env, typ_env)

  let set_typ_annot_type (id_env, typ_env) typ_annot typ =
    (id_env, Smap.add typ_annot typ typ_env)


  let ensure_all_def (_, typ_env) loc = (* how to get loc here? *)
    Smap.iter (fun _ -> function
                | Trecord (Decl s) ->
                  error (Format.sprintf "Type %s has not been defined before the \
                                         next level of declarations" s) loc
                | _ -> ()) typ_env
end


module Sset = Set.Make(String)


(** Typing of expressions *)

let type_ident env id =
  (replace_deco id (Env.get_id_type env id) : T.ident)


let type_typ_annot env (ta : A.typ_annot) =
  (({ typ_ident = replace_deco ta.typ_ident ();
      is_access = ta.is_access } : T.typ_annot),
   Env.get_typ_annot_type env ta.typ_ident)

let type_annotated env (a : A.annotated) =
  let (ta', t) = type_typ_annot env a.ta in
  (({ ident = replace_deco a.ident ();
      ta    = ta' } : T.annotated), t)

let type_const = function
  | Cint  _ -> Tint
  | Cchar _ -> Tchar
  | Cbool _ -> Tbool
  | Cnull   -> Tnull

let type_field env r (f : ident_decl) =
  try
    let a = List.find (fun a -> f.desc = a.ident) r.fields in
    Env.get_typ_annot_type env (decorate a.ta.typ_ident f.deco)
  with
  | Not_found -> error
                   (Format.sprintf "Record %s has no field %s" r.r_ident f.desc)
                   f.deco


let rec lv_ensure_not_modified const = function
  | Lident id -> if Sset.mem id.desc const
    then error (Format.sprintf "%s cannot be modified, it has been \
                                declared In or is a counter variable" id.desc)
           id.deco
  | Lmember (e, _) -> expr_ensure_not_modified const e
and expr_ensure_not_modified const e =
  match e.desc with
  | Eleft_val lv' -> lv_ensure_not_modified const lv'
  | _ -> ()


let rec type_expr env const expr =
  match expr.desc with
  | Econst c -> decorate (T.Econst c) (type_const c)
  | Eleft_val lv -> let (lv', t) = type_left_val env const lv in
    decorate (T.Eleft_val lv') t
  | Enot e ->
    let ([e'], t) = type_proc_func env const
                      (decorate "not" expr.deco) [e] in
    decorate (T.Enot e') t
  | Ebinop (e1, b, e2) ->
    begin
      match b with
      | Beq | Bneq -> let e1' = type_expr env const e1 in
        let e2' = type_expr env const e2 in
        ensure_equiv e1'.deco e2'.deco e2.deco;
        decorate (T.Ebinop (e1', b, e2')) Tbool
      | _ ->  let ([e1'; e2'], t) =
                type_proc_func env const
                  (decorate (print_to_string print_binop b) expr.deco)
                  [e1; e2] in
        decorate (T.Ebinop (e1', b, e2')) t
    end
  | Enew id -> let t = Env.get_typ_annot_type env id in
    let t' = to_access (ensure_record t id.deco) in
    decorate (T.Enew (replace_deco id ())) t'
  | Eapp_func (f, params) -> 
    let (params', t) = type_proc_func env const f params in
    decorate (T.Eapp_func (type_ident env f, params')) t
      

and type_left_val ?(ensure_lv = false) env const lv =
  let not_left_val loc = error "This expression should be a left value" loc in
  match lv with
  | Lident id -> let id' = type_ident env id in
    let t = match id'.deco with
      | Tproc_func ([], t) -> if ensure_lv then not_left_val id.deco else t
      (* TODO? *)
      | t -> t
    in
    (T.Lident (replace_deco id' t), t)
  | Lmember (e, f) ->
    begin
      let e' = type_expr env const e in
      let r = match e'.deco with
        | Trecord r -> r
        | Taccess r -> ensure_record
                         (Env.get_typ_annot_type env (decorate r e.deco)) e.deco
        | _ -> error
                 (Format.sprintf "This expression should be a record or an access")
                 e.deco
      in
      let t = type_field env (ensure_defined r e.deco) f in
      if ensure_lv && not (is_access e'.deco)
      then ignore(ensure_left_val env const e);
      (T.Lmember (e', replace_deco f t), t)
    end

and ensure_left_val env const e =
  match e.desc with
  | Eleft_val lv -> let (lv', t) = type_left_val ~ensure_lv:true env const lv in
    decorate (T.Eleft_val lv') t
  | _ -> error "This expression should be a left value" e.deco
           

and type_proc_func ?(expr = true) env const name params =
  let typ = Env.get_id_type env name in
  match (typ, expr) with
  | (Tproc_func (_, Tnull), true) ->
    error "A procedure cannot be called in an expression" name.deco
  | (Tproc_func (_, t), false) when t <> Tnull ->
    error "A function cannot be applied in a statement" name.deco
  | (Tproc_func (l, r), _) ->
    begin
      try
        let params' = List.map2
                        (fun (t, m) e -> let type_func env e = match m with
                                            | In -> type_expr env const e
                                            | InOut ->
                                              expr_ensure_not_modified const e;
                                              ensure_left_val env const e
                           in
                           let e' = type_func env e in
                           ensure_equiv t e'.deco e.deco;
                           e') l params in
        (params', r)
      with
      | Invalid_argument _ (* "List.map2" *) ->
        error (Format.sprintf "%s expects %d arguments but is given %d here"
                 name.desc (List.length l) (List.length params)) name.deco
    end
  | _ -> let (fp, v) = if expr then ("function", "applied")
           else ("procedure", "called") in
    error (Format.sprintf "%s is not a %s, it cannot be %s" name.desc fp v) name.deco


(** Typing of statements *)
         

let rec desc_type_stmt env return_type const stmt =
  match stmt.desc with
  | Saffect (lv, e) -> lv_ensure_not_modified const lv;
    let (lv', t) = type_left_val ~ensure_lv:true env const lv in
    let e' = type_expr env const e in
    ensure_equiv t e'.deco e.deco;
    T.Saffect (lv', e')
  | Scall_proc (p, params) ->
    let (params', _) = type_proc_func ~expr:false env const p params in
    T.Scall_proc (type_ident env p, params')
  | Sreturn e -> let e' = type_expr env const e in
    let ensure = if return_type = Tnull then ensure_equal else ensure_equiv in
    ensure return_type e'.deco e.deco;
    T.Sreturn e'
  | Sblock l -> T.Sblock (List.map (type_stmt env return_type const) l)
  | Scond (e, s1, s2) -> let e' = type_expr env const e in
    ensure_equal Tbool e'.deco e.deco;
    let s1' = type_stmt env return_type const s1 in
    let s2' = type_stmt env return_type const s2 in
    T.Scond (e', s1', s2')
  | Swhile (e, s) -> let e' = type_expr env const e in
    ensure_equal Tbool e'.deco e.deco;
    let s' = type_stmt env return_type const s in
    T.Swhile (e', s')
  | Sfor (id, rev, lb, ub, s) -> let id' = replace_deco id Tint in
    let lb' = type_expr env const lb in
    let ub' = type_expr env const ub in
    ensure_equal Tint lb'.deco lb.deco;
    ensure_equal Tint ub'.deco ub.deco;
    let const' = Sset.add id.desc const in
    let s' = type_stmt (Env.set_id_type env id.desc id'.deco) return_type const' s in
    T.Sfor (id', rev, lb', ub', s')
    
and type_stmt env return_type const stmt =
  decorate (desc_type_stmt env return_type const stmt) ()


(** Typing of declarations *)

let decl_get_id = function
  | Dtype_decl (id, None) -> (id, false)
  | Dtype_decl (id, Some _) | Drecord_def (id, _) -> (id, true)
  | Dvar_decl (a, _) -> (a.ident, true)
  | Dproc_func pf -> (pf.name, true)


let rec ensure_return name loc stmts =
  match stmts with
  | [] -> error (Format.sprintf "Function %s does not always end with a return"
                   name) loc
  | s :: tl ->
    begin
      match s.desc with
      | Saffect _ | Scall_proc _ | Swhile _ | Sfor _ -> ensure_return name s.deco tl
      | Sreturn _ -> ()
      | Sblock b ->
        begin
          try ensure_return name loc b
          with Typing_error (_, loc') -> ensure_return name loc' tl
        end
      | Scond (_, s1, s2) ->
        begin
          try
            ensure_return name s1.deco [s1];
            ensure_return name s2.deco [s2]
          with Typing_error (_, loc') -> ensure_return name loc' tl
        end
    end


let ensure_well_formed env ta =
  if ta.is_access
  then to_access (ensure_record (Env.get_typ_annot_type env ta.typ_ident)
                    ta.typ_ident.deco)
  else match Env.get_typ_annot_type env ta.typ_ident with
    | Trecord r -> Trecord (Def (ensure_defined r ta.typ_ident.deco))
    | t -> t


let rec type_decl env const = function
  | Dtype_decl (id, None) -> let env' = Env.set_typ_annot_type env id.desc
                                          (Trecord (Decl id.desc)) in
    (T.Dtype_decl (replace_deco id (), None), env')
  | Dtype_decl (id, Some ta) -> (* ta.is_access = true because no aliasing *)
    let t = Env.get_typ_annot_type env ta.typ_ident in (* ensures r is declared *)
    let t' = ensure_record t ta.typ_ident.deco in
    let env' = Env.set_typ_annot_type env id.desc (to_access t') in
    (T.Dtype_decl (replace_deco id (),
                   Some { typ_ident = replace_deco ta.typ_ident ();
                          is_access = true }), env')
  | Drecord_def (id, fields) ->
    let env_with_r = Env.set_typ_annot_type env id.desc (Trecord (Decl id.desc)) in
    let idents = List.map (fun a -> a.ident) fields in
    let () = match List.find_duplicates
                     (fun i i' -> String.compare i.desc i'.desc) idents with
    | None -> ()
    | Some (_, i') -> error (Format.sprintf "Field %s has already been declared"
                               i'.desc) i'.deco
    in
    List.iter (fun a ->
                ignore (ensure_well_formed env_with_r a.ta);)
      fields;
    let fields' = List.map (fun a -> { ident = replace_deco a.ident ();
                                       ta = fst (type_typ_annot env_with_r a.ta) })
                    fields in
    let env' = Env.set_typ_annot_type env id.desc
                 (Trecord (Def { r_ident = id.desc;
                                 fields = List.map strip_deco_a fields' })) in
    (T.Drecord_def (replace_deco id (), fields'), env')
  | Dvar_decl (a, None) -> let typ = ensure_well_formed env a.ta in
    let env' = Env.set_id_type env a.ident.desc typ in
    (T.Dvar_decl (fst (type_annotated env' a), None), env')
  | Dvar_decl (a, Some e) -> let typ = ensure_well_formed env a.ta in
    let e' = type_expr env const e in
    ensure_equiv typ e'.deco e.deco;
    let env' = Env.set_id_type env a.ident.desc typ in
    (T.Dvar_decl (fst (type_annotated env' a), Some e'), env')
  | Dproc_func pf ->
    let idents = List.map (fun (a, _) -> a.ident) pf.params in
    let () = match List.find_duplicates
                     (fun i i' -> String.compare i.desc i'.desc) idents with
    | None -> ()
    | Some (_, i') -> error "Two parameters can't have the same name" i'.deco
    in
    Env.ensure_all_def env pf.name.deco;
    let (return', ret) = match pf.return with
      | None -> (Tnull, None)
      | Some ta -> ensure_return pf.name.desc pf.name.deco [pf.stmt];
        (ensure_well_formed env ta, Some (fst (type_typ_annot env ta))) in
    let params' = List.map (fun (a, m) ->
                             let typ = ensure_well_formed env a.ta in (* needed? *)
                             (type_annotated env a, m))
                    pf.params in
    let env' = Env.set_id_type env pf.name.desc
                 (Tproc_func (List.map
                                (fun ((_, t), m) -> (t, m)) params', return')) in
    let env'' = List.fold_left (fun env ((a, t), _) ->
                                 Env.set_id_type env a.ident.desc t) env' params' in
    let (decls', env'') = type_decls env'' const pf.stmt.deco pf.decls in
    let const = Sset.of_list
                  (List.remove_none
                     (List.map (fun ((a, t), m) -> match m with
                                  | In -> if is_access t then None
                                    else Some a.ident.desc
                                  | InOut -> None) params'))
    in
    let stmt' = type_stmt env'' return' const pf.stmt in
    let pf' = T.{ name = replace_deco pf.name ();
                  params = List.map (fun ((a, _), m) -> (a, m)) params';
                  return = ret;
                  decls = decls'; (* embed environment? *)
                  stmt = stmt' } in
    (T.Dproc_func pf', env')

and type_decls env const loc_after decls =
  (* Ensures all declarations have unique identifiers *)
  let ids = List.map decl_get_id decls in
  match List.find_duplicates (fun (i, b) (i', b') ->
                               let r = String.compare i.desc i'.desc in
                               if r = 0 then compare b b' else r) ids with
  | Some ((_, _), (i2, _)) ->
    error (Format.sprintf "Identifier %s has already been defined or declared \
                           in this level of declaration"
             i2.desc) i2.deco
  | None ->
    begin
      match decls with
      | [] -> Env.ensure_all_def env loc_after; ([], env)
      | d :: ds -> let (d', env') = type_decl env const d in
        let (ds', env'') = type_decls env' const loc_after ds in
        (d' :: ds', env'')
    end


(** Typing of a program *)

let type_ast (a : A.ast) =
  match fst (type_decl Env.new_env Sset.empty (Dproc_func a)) with
  | T.Dproc_func a' -> (a' : T.ast)
  | _ -> assert false
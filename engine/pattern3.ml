open Common open Commonop

(*****************************************************************************)
(* The functor argument  *) 
(*****************************************************************************)

(* info passed recursively in monad in addition to binding *)
type xinfo = { 
  optional_storage_iso : bool;
  optional_qualifier_iso : bool;
  value_format_iso : bool;
}

module XMATCH = struct

  (* ------------------------------------------------------------------------*)
  (* Combinators history *) 
  (* ------------------------------------------------------------------------*)
  (*
   * version0: 
   *   type ('a, 'b) matcher = 'a -> 'b -> bool
   *
   * version1: same but with a global variable holding the current binding
   *  BUT bug
   *   - can have multiple possibilities
   *   - globals sux
   *   - sometimes have to undo, cos if start match, then it binds, 
   *     and if later it does not match, then must undo the first binds.
   *     ex: when match parameters, can  try to match, but then we found far 
   *     later that the last argument of a function does not match
   *      => have to uando the binding !!!
   *      (can handle that too with a global, by saving the 
   *      global, ... but sux)
   *   => better not use global
   * 
   * version2: 
   *    type ('a, 'b) matcher = binding -> 'a -> 'b -> binding list
   *
   * Empty list mean failure (let matchfailure = []).
   * To be able to have pretty code, have to use partial application 
   * powa, and so the type is in fact
   *
   * version3:
   *    type ('a, 'b) matcher =  'a -> 'b -> binding -> binding list
   *
   * Then by defining the correct combinators, can have quite pretty code (that
   * looks like the clean code of version0).
   * 
   * opti: return a lazy list of possible matchs ?
   * 
   * version4: type tin = Lib_engine.metavars_binding
   *)

  (* ------------------------------------------------------------------------*)
  (* Standard type and operators  *) 
  (* ------------------------------------------------------------------------*)

  type tin = { 
    extra: xinfo;
    binding: Lib_engine.metavars_binding;
  }
  (* 'x is a ('a * 'b) but in fact dont care about 'b, we just tag the SP *)
  (* opti? use set instead of list *)
  type 'x tout = ('x * Lib_engine.metavars_binding) list 

  type ('a, 'b) matcher = 'a -> 'b  -> tin -> ('a * 'b) tout

  (* was >&&> *)
  let (>>=) m1 m2 = fun tin ->
    let xs = m1 tin in
    let xxs = xs +> List.map (fun ((a,b), binding) -> 
      m2 a b {extra = tin.extra; binding = binding}
    ) in
    List.flatten xxs

  (* Je compare les bindings retournés par les differentes branches.
   * Si la deuxieme branche amene a des bindings qui sont deja presents
   * dans la premiere branche, alors je ne les accepte pas.
   * 
   * update: still useful now that julia better handle Exp directly via
   * ctl tricks using positions ?
   *)
  let (>|+|>) m1 m2 = fun tin -> 
(* CHOICE
      let xs = m1 tin in
      if null xs
      then m2 tin
      else xs
*)
    let res1 = m1 tin in
    let res2 = m2 tin in
    let list_bindings_already = List.map snd res1 in
    res1 ++ 
      (res2 +> List.filter (fun (x, binding) -> 
        not 
          (list_bindings_already +> List.exists (fun already -> 
            Lib_engine.equal_binding binding already))
      ))

          
     
      
  let (>||>) m1 m2 = fun tin ->
(* CHOICE
      let xs = m1 tin in
      if null xs
      then m2 tin
      else xs
*)
    (* opti? use set instead of list *)
    m1 tin ++ m2 tin


  let return res = fun tin -> 
    [res, tin.binding]

  let fail = fun tin -> 
    []

  let (>&&>) f m = fun tin -> 
    if f tin
    then m tin
    else fail tin


  let mode = Cocci_vs_c_3.PatternMode

  (* ------------------------------------------------------------------------*)
  (* Exp  *) 
  (* ------------------------------------------------------------------------*)
  let cocciExp = fun expf expa node -> fun tin -> 

    let globals = ref [] in
    let bigf = { 
      (* julia's style *)
      Visitor_c.default_visitor_c with 
      Visitor_c.kexpr = (fun (k, bigf) expb ->
	match expf expa expb tin with
	| [] -> (* failed *) k expb
	| xs -> 
            globals := xs @ !globals; 
            if not !Flag_engine.disallow_nested_exps then k expb (* CHOICE *)
      );
      (* pad's style.
       * push2 expr globals;  k expr
       *  ...
       *  !globals +> List.fold_left (fun acc e -> acc >||> match_e_e expr e) 
       * (return false)
       * 
       *)
    }
    in
    Visitor_c.vk_node bigf node;
    !globals +> List.map (fun ((a, _exp), binding) -> 
      (a, node), binding
    )

  let cocciTy = fun expf expa node -> fun tin -> 

    let globals = ref [] in
    let bigf = { 
      Visitor_c.default_visitor_c with 
        Visitor_c.ktype = (fun (k, bigf) expb -> 
	match expf expa expb tin with
	| [] -> (* failed *) k expb
	| xs -> globals := xs @ !globals);

    } 
    in
    Visitor_c.vk_node bigf node;
    !globals +> List.map (fun ((a, _exp), binding) -> 
      (a, node), binding
    )


  (* ------------------------------------------------------------------------*)
  (* Tokens *) 
  (* ------------------------------------------------------------------------*)
  let tag_mck_pos mck posmck =
    match mck with 
    | Ast_cocci.PLUS -> Ast_cocci.PLUS
    | Ast_cocci.CONTEXT (pos, xs) -> 
        assert (pos = Ast_cocci.NoPos || pos = Ast_cocci.DontCarePos);
        Ast_cocci.CONTEXT (posmck, xs)
    | Ast_cocci.MINUS (pos, xs) -> 
        assert (pos = Ast_cocci.NoPos || pos = Ast_cocci.DontCarePos);
        Ast_cocci.MINUS (posmck, xs)
  

  let tag_mck_pos_mcode (x,info, mck) posmck stuff = fun tin -> 
    [((x, info, tag_mck_pos mck posmck),stuff), tin.binding]
    

  let tokenf ia ib = fun tin -> 
    let pos = Ast_c.pos_of_info ib in
    let posmck = Ast_cocci.FixPos (pos, pos) in
    tag_mck_pos_mcode ia posmck ib tin

  let tokenf_mck mck ib = fun tin -> 
    let pos = Ast_c.pos_of_info ib in
    let posmck = Ast_cocci.FixPos (pos, pos) in
    [(tag_mck_pos mck posmck, ib), tin.binding]
    
    

  (* ------------------------------------------------------------------------*)
  (* Distribute mcode *) 
  (* ------------------------------------------------------------------------*)
  let distrf (ii_of_x_f) =
    fun mcode x -> fun tin -> 
    let (max, min) = Lib_parsing_c.max_min_by_pos (ii_of_x_f x)
    in
    let posmck = Ast_cocci.FixPos (min, max) (* subtil: and not max, min !!*) 
    in
    tag_mck_pos_mcode mcode posmck x tin

  let distrf_e    = distrf (Lib_parsing_c.ii_of_expr)
  let distrf_args = distrf (Lib_parsing_c.ii_of_args)
  let distrf_type = distrf (Lib_parsing_c.ii_of_type)
  let distrf_param = distrf (Lib_parsing_c.ii_of_param)
  let distrf_params = distrf (Lib_parsing_c.ii_of_params)
  let distrf_ini   = distrf (Lib_parsing_c.ii_of_ini)
  let distrf_node   = distrf (Lib_parsing_c.ii_of_node)
  let distrf_struct_fields   = distrf (Lib_parsing_c.ii_of_struct_fields)
  let distrf_cst = distrf (Lib_parsing_c.ii_of_cst)
  let distrf_define_params = distrf (Lib_parsing_c.ii_of_define_params)

  (* ------------------------------------------------------------------------*)
  (* Environment *) 
  (* ------------------------------------------------------------------------*)
  (* pre: if have declared a new metavar that hide another one, then
   * must be passed with a binding that deleted this metavar
   * 
   * Here we dont use the keep argument of julia. cf f(X,X), J'ai
   * besoin de garder le X en interne, meme si julia s'en fout elle du
   * X et qu'elle a mis X a DontSaved.
   *)
  let check_add_metavars_binding strip _keep inherited = fun (k, valu) tin ->
    (match Common.optionise (fun () -> tin.binding +> List.assoc k) with
    | Some (valu') ->
        if Cocci_vs_c_3.equal_metavarval valu valu'
        then Some tin.binding
        else None

    | None -> 
        if inherited 
        then None
        else 
          let valu' = 
	    if strip
	    then
              (match valu with
              | Ast_c.MetaIdVal a        -> Ast_c.MetaIdVal a
              | Ast_c.MetaFuncVal a      -> Ast_c.MetaFuncVal a
              | Ast_c.MetaLocalFuncVal a -> Ast_c.MetaLocalFuncVal a (*more?*)
              | Ast_c.MetaExprVal a -> 
                  Ast_c.MetaExprVal (Lib_parsing_c.al_expr a)
              | Ast_c.MetaExprListVal a ->  
                  Ast_c.MetaExprListVal (Lib_parsing_c.al_arguments a)
		    
              | Ast_c.MetaStmtVal a -> 
                  Ast_c.MetaStmtVal (Lib_parsing_c.al_statement a)
              | Ast_c.MetaTypeVal a -> 
                  Ast_c.MetaTypeVal (Lib_parsing_c.al_type a)

              | Ast_c.MetaListlenVal a -> Ast_c.MetaListlenVal a

              | Ast_c.MetaParamVal a -> failwith "not handling MetaParamVal"
              | Ast_c.MetaParamListVal a -> 
                  Ast_c.MetaParamListVal (Lib_parsing_c.al_params a)

              | Ast_c.MetaPosVal (pos1,pos2) -> Ast_c.MetaPosVal (pos1,pos2)
              | Ast_c.MetaPosCodeVal _ -> failwith "not possible")
	    else Ast_c.MetaPosCodeVal valu
          in
          Some (tin.binding +> Common.insert_assoc (k, valu'))
    )

  let envf strip keep inherited = fun (k, valu) f tin -> 
    match check_add_metavars_binding strip keep inherited (k, valu) tin with
    | Some binding -> f () {extra = tin.extra; binding = binding}
    | None -> fail tin
        

  (* ------------------------------------------------------------------------*)
  (* Environment, allbounds *) 
  (* ------------------------------------------------------------------------*)
  (* all referenced inherited variables have to be bound. This would
   * be naturally checked for the minus or context ones in the
   * matching process, but have to check the plus ones as well. The
   * result of get_inherited contains all of these, but the potential
   * redundant checking for the minus and context ones is probably not
   * a big deal. If it's a problem, could fix free_vars to distinguish
   * between + variables and the other ones. *)

  let (all_bound : Ast_cocci.meta_name list -> tin -> bool) = fun l tin ->
    l +> List.for_all (fun inhvar -> 
      match Common.optionise (fun () -> tin.binding +> List.assoc inhvar) with
      | Some _ -> true
      | None -> false
    )

  let optional_storage_flag f = fun tin -> 
    f (tin.extra.optional_storage_iso) tin

  let optional_qualifier_flag f = fun tin -> 
    f (tin.extra.optional_qualifier_iso) tin

  let value_format_flag f = fun tin -> 
    f (tin.extra.value_format_iso) tin


end

(*****************************************************************************)
(* Entry point  *) 
(*****************************************************************************)
module MATCH  = Cocci_vs_c_3.COCCI_VS_C (XMATCH)


let match_re_node2 dropped_isos a b binding = 

  let tin = { 
    XMATCH.extra = {
      optional_storage_iso   = not(List.mem "optional_storage"   dropped_isos);
      optional_qualifier_iso = not(List.mem "optional_qualifier" dropped_isos);
      value_format_iso       = not(List.mem "value_format"       dropped_isos);
    };
    XMATCH.binding = binding;
  } in

  MATCH.rule_elem_node a b tin
  (* take only the tagged-SP, the 'a' *)
  +> List.map (fun ((a,_b), binding) -> a, binding)


let match_re_node a b c d = 
  Common.profile_code "Pattern3.match_re_node" 
    (fun () -> match_re_node2 a b c d)
    


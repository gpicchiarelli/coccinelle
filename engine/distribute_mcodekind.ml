open Common open Commonop

open Ast_c
module F = Control_flow_c

type 'a distributer = 
    (Ast_c.info -> Ast_c.info) * 
    (Ast_c.info -> Ast_c.info) * 
    (Ast_c.info -> Ast_c.info) -> 
    'a -> 'a


(* ------------------------------------------------------------------------- *)
let (minusize_token: Ast_c.info -> Ast_c.info) = fun (s, (mcode,env))  -> 
  let mcode' =
    match mcode with
    | Ast_cocci.CONTEXT (Ast_cocci.NOTHING) -> Ast_cocci.MINUS ([])
    | _ -> failwith "have already minused this token"
  in
  (s, (mcode', env))



let add_left (xxs, binding) = fun (s, (mcode,env))  -> 
  let mcode' = 
    match mcode with
    | Ast_cocci.MINUS ([]) -> Ast_cocci.MINUS (xxs)
    | Ast_cocci.MINUS (x::xs) -> 
        failwith "have already added stuff on this token"

    | Ast_cocci.CONTEXT (Ast_cocci.NOTHING) -> 
        Ast_cocci.CONTEXT (Ast_cocci.BEFORE xxs)
    | Ast_cocci.CONTEXT (Ast_cocci.AFTER yys) -> 
        Ast_cocci.CONTEXT (Ast_cocci.BEFOREAFTER (xxs, yys))
    | _ -> raise Impossible

  in
  s, (mcode', binding)


let add_right (yys, binding) = fun (s,(mcode,env))  -> 
  let mcode' = 
    match mcode with
    | Ast_cocci.MINUS ([]) -> 
        Ast_cocci.MINUS (yys)
    | Ast_cocci.MINUS (_) -> failwith "have already added stuff on this token"


    | Ast_cocci.CONTEXT (Ast_cocci.NOTHING) -> 
        Ast_cocci.CONTEXT (Ast_cocci.AFTER yys)
    | Ast_cocci.CONTEXT (Ast_cocci.BEFORE xxs) -> 
        Ast_cocci.CONTEXT (Ast_cocci.BEFOREAFTER (xxs, yys))
    | _ -> raise Impossible
  in
  s, (mcode', binding)


let no_minusize x = x
let nothing_right x = x
let nothing_left  x = x


(* ------------------------------------------------------------------------- *)

let (distribute_mck: 
   Ast_cocci.mcodekind -> 'a distributer -> 'a -> Ast_c.metavars_binding -> 'a)
 = fun mcodekind distributef expr binding ->
  match mcodekind with
  | Ast_cocci.MINUS (any_xxs) -> 
      distributef 
        (minusize_token, add_left (any_xxs, binding), nothing_right)
        expr
  | Ast_cocci.CONTEXT (any_befaft) -> 
        (match any_befaft with
        | Ast_cocci.NOTHING -> expr

        | Ast_cocci.BEFORE xxs -> 
            distributef
              (no_minusize, add_left (xxs, binding), nothing_right)
              expr
        | Ast_cocci.AFTER xxs ->  
            distributef
              (no_minusize, nothing_left, add_right (xxs, binding))
              expr
        | Ast_cocci.BEFOREAFTER (xxs, yys) -> 
            distributef
              (no_minusize, add_left (xxs, binding) , add_right (xxs, binding))
              expr
        )
  | Ast_cocci.PLUS -> raise Impossible

(* ------------------------------------------------------------------------- *)
(* Could do the minus more easily by extending visitor_c.ml and adding a 
 * function applied to every mcode. But as I also need to do the add_left and 
 * add_right, which requires to do a different thing for each case, I have not
 * defined this not-so-useful visitor.
 * op = minusize operator.
 * lop = stuff to do on the left.
 * rop = stuff to do on the right.
*)

let rec (distribute_mck_e: Ast_c.expression distributer)= fun (op,lop,rop) e ->
 let ((unwrap_e, typ),ii) = e in
 let (e',ii') = 
  match unwrap_e, ii with
  | Ident s, [i1] -> 
      Ident s, 
      [i1 +> op +> lop +> rop] 
  | Constant (String s),        is     -> 
      Constant (String s),
      (match is with
      | [] -> raise Impossible
      | [i] -> [i +> op +> lop +> rop]
      | x::y::xs -> 
          let (head, middle, tail) = head_middle_tail (x::y::xs) in
          [head +> op +> lop] @ List.map op middle @ [tail +> op +> rop]
      )
  (* only a String can have multiple ii *)
  | Constant c,  [i1] -> 
      Constant c, 
      [i1 +> op +> lop +> rop]

  | FunCall (e, xs), [i2;i3] -> 
      FunCall 
        (distribute_mck_e (op, lop, nothing_right) e,
         xs +> List.map (function 
           | (Left e, ii) -> 
               Left (distribute_mck_e (op, nothing_left, nothing_right) e),
               (ii +> List.map op)
           | (Right e, ii) -> failwith "not handling type in funcall"
                        ) 
        ), 
      [i2 +> op; i3 +> op +> rop]

  | CondExpr (e1, e2, e3),    [i1;i2]    -> 
      CondExpr 
        (distribute_mck_e (op, lop, nothing_right) e1,
         map_option (distribute_mck_e (op, nothing_left, nothing_left)) e2,
         distribute_mck_e (op, nothing_left, rop) e3),
      [i1 +> op; i2 +> op]
  | Sequence (e1, e2),          [i]  -> 
      Sequence
        (distribute_mck_e (op, lop, nothing_right) e1,
         distribute_mck_e (op, nothing_left, rop) e2),
      [i +> op]
  | Assignment (e1, opbis, e2),    [i]  -> 
      Assignment
        (distribute_mck_e (op, lop, nothing_right) e1,
         opbis,
         distribute_mck_e (op, nothing_left, rop) e2),
      [i +> op]

  | Postfix  (e, opbis),    [i] -> 
      Postfix (distribute_mck_e (op, lop, nothing_right) e, opbis),
      [i +> op +> rop]
         
  | Infix    (e, opbis),    [i] -> 
      Infix (distribute_mck_e (op, nothing_left, rop) e, opbis),
      [i +> op +> lop]

  | Unary    (e, opbis),    [i] -> 
      Unary (distribute_mck_e (op, nothing_left, rop) e, opbis),
      [i +> op +> lop]
  | Binary   (e1, opbis, e2),    [i] -> 
      Binary
        (distribute_mck_e (op, lop, nothing_right) e1,
         opbis,
         distribute_mck_e (op, nothing_left, rop) e2),
      [i +> op]


  | ArrayAccess    (e1, e2),   [i1;i2] -> 
      ArrayAccess
        (distribute_mck_e (op, lop, nothing_right) e1,
         distribute_mck_e (op, nothing_left, nothing_right) e2),
      [i1 +> op; i2 +> op +> rop]
  | RecordAccess (e, id), [i1;i2] -> 
      RecordAccess (distribute_mck_e (op, lop, nothing_right) e, id), 
      [i1 +> op; i2 +> op +> rop]
  | RecordPtAccess (e, id), [i1;i2] -> 
      RecordPtAccess (distribute_mck_e (op, lop, nothing_right) e, id), 
      [i1 +> op; i2 +> op +> rop]

  | SizeOfExpr  (e),     [i] -> 
      SizeOfExpr (distribute_mck_e (op, nothing_left, rop) e),
      [i +> op +> lop]
  | SizeOfType  (t),     [i1;i2;i3] -> 
      SizeOfType (distribute_mck_type (op, nothing_left, nothing_right) t),
      [i1 +> op +> lop; i2 +> op; i3 +> op +> rop]
  | Cast    (t, e),      [i1;i2] -> 
      Cast 
        (distribute_mck_type (op, nothing_left, nothing_right) t,
         distribute_mck_e (op, nothing_left, rop) e),
      [i1 +> op +> lop; i2 +> op]
      
  | StatementExpr (statxs, [ii1;ii2]),  [i1;i2] -> 
      StatementExpr
        (statxs +> 
         List.map (distribute_mck_stat (op, nothing_left, nothing_right)),
         [ii1 +> op; ii2 +> op]),
      [i1 +> op +> lop; i2 +> op +> rop]

  | Constructor, [] -> failwith "Constructor, what to do ? not enough info"

  | ParenExpr (e), [i1;i2] -> 
      ParenExpr (distribute_mck_e (op, nothing_left, nothing_right) e),
      [i1 +> op +> lop; i2 +> op +> rop]

  | MacroCall  (es),     [i1;i2;i3] -> 
      failwith "MacroCall"

  | MacroCall2  (arg),   [i1;i2;i3] -> 
      failwith "MacroCall2"

  | x -> raise Impossible
 in
 (e', typ), ii'


(* ------------------------------------------------------------------------- *)
and (distribute_mck_decl: Ast_c.declaration distributer) = fun (op,lop,rop) ->
 fun decl ->
  raise Todo

(* ------------------------------------------------------------------------- *)
and (distribute_mck_stat: Ast_c.statement distributer) = fun (op,lop,rop) -> 
 function

  | Labeled (Label (s, st)), [i1;i2] -> 
      Labeled (Label (s, distribute_mck_stat (op, nothing_left, rop) st)),
      [i1 +> op +> lop;i2 +> op]
  | Labeled (Case  (e, st)), [i1;i2] -> 
      Labeled (Case  (distribute_mck_e (op, nothing_left, nothing_right) e,
                      distribute_mck_stat (op, nothing_left, rop) st)),
      [i1 +> op +> lop; i2 +> op] 
  | Labeled (CaseRange  (e, e2, st)), _ -> raise Todo
  | Labeled (Default st), [i1;i2] -> 
      Labeled (Default (distribute_mck_stat (op, nothing_left, rop) st)),
      [i1 +> op +> lop; i2 +> op]

  | Compound statxs, [i1;i2] -> 
      Compound 
        (statxs +> 
         List.map (distribute_mck_stat (op, nothing_left, nothing_right))),
      [i1 +> op +> lop; i2 +> op +> rop]

  | ExprStatement None, [i] -> 
      ExprStatement None, 
      [i +> op +> lop +> rop]
  (* When there is a None ? for instance with the else of a just_ifthen *)
  | ExprStatement None, [] -> 
      ExprStatement None, []
  | ExprStatement (Some e), [i] -> 
      ExprStatement (Some (distribute_mck_e (op, lop, nothing_right) e)),
      [i +> op +> rop]
   (* the last ExprStatement of a for does not have a trailing ';' hence the
      [] for ii.  *)
  | ExprStatement (Some e), [] -> 
      ExprStatement (Some (distribute_mck_e (op, lop, rop) e)),
      []

  | Selection  (If (e, st1, st2)), i1::i2::i3::is -> 
      (match (st2, is) with
      | ((ExprStatement None, []), [])  -> 
          Selection 
            (If
               (distribute_mck_e (op, nothing_left, nothing_right) e,
                distribute_mck_stat (op, nothing_left, rop) st1,
                (ExprStatement None, []))),
          [i1 +> op +> lop; i2 +> op; i3 +> op]
             
          
      | st2, [i4] -> 
          Selection 
            (If
               (distribute_mck_e (op, nothing_left, nothing_right) e,
                distribute_mck_stat (op, nothing_left, nothing_right) st1,
                distribute_mck_stat (op, nothing_left, rop) st2)),
         [i1 +> op +> lop; i2 +> op; i3 +> op;i4 +> op]
        
      | x -> raise Impossible
      )

  | Selection  (Switch (e, st)), [i1;i2;i3] -> 
      Selection 
        (Switch
           (distribute_mck_e (op, nothing_left, nothing_right) e,
            distribute_mck_stat (op, nothing_left, rop) st)),
      [i1 +> op +> lop; i2 +> op; i3 +> op]
  | Iteration  (While (e, st)), [i1;i2;i3] -> 
      Iteration 
        (While
           (distribute_mck_e (op, nothing_left, nothing_right) e,
            distribute_mck_stat (op, nothing_left, rop) st)),
      [i1 +> op +> lop; i2 +> op; i3 +> op]

  | Iteration  (DoWhile (st, e)), [i1;i2;i3;i4;i5] -> 
      Iteration
        (DoWhile
           (distribute_mck_stat (op, nothing_left, nothing_right) st,
            distribute_mck_e (op, nothing_left, nothing_right) e)),
      [i1 +> op +> lop; i2 +> op; i3 +> op; i4 +> op; i5 +> op +> rop]

  | Iteration  (For ((e1opt,il1),(e2opt,il2),(e3opt, il3), st)), [i1;i2;i3] ->
      assert (null il3);
      Iteration
        (For 
           ((map_option (distribute_mck_e (op, nothing_left, nothing_right)) 
               e1opt, il1 +> List.map op),
            (map_option (distribute_mck_e (op, nothing_left, nothing_right)) 
               e2opt, il2 +> List.map op),
            (map_option (distribute_mck_e (op, nothing_left, nothing_right)) 
               e3opt, il3 +> List.map op),
            distribute_mck_stat (op, nothing_left, rop) st)),
      [i1 +> op +> lop; i2 +> op; i3 +> op]
            
  | Jump (Goto s), [i1;i2;i3]               -> 
      Jump (Goto s),
      [i1 +> op +> lop; i2 +> op; i3 +> op +> rop]
  | Jump ((Continue|Break|Return) as x), [i1;i2] -> 
      Jump x,
      [i1 +> op +> lop; i2 +> op +> rop]
  | Jump (ReturnExpr e), [i1;i2] -> 
      Jump 
        (ReturnExpr (distribute_mck_e (op, nothing_left, nothing_right) e)),
      [i1 +> op +> lop; i2 +> op +> rop]

  | Decl decl, [] -> 
      Decl (distribute_mck_decl (op, nothing_left, nothing_right) decl), []
          
  | (Asm, []) -> failwith "Asm, what to do ? not enough info"
  | x -> raise Impossible



(* ------------------------------------------------------------------------- *)
and (distribute_mck_type: Ast_c.fullType distributer) = fun (op, lop, rop) ->
 fun ((qu, iiqu),(ty, iity)) ->
  (* UGLY *)

  (* TODO in fact for pointer, the qualifier is after the type *)
   let (iiqu', lop) = 
     match iiqu with
     | [] when not qu.const && not qu.volatile -> [], lop
     | [i1] when xor qu.const qu.volatile -> 
         [i1 +> op +> lop], nothing_left
     | [i1;i2] when qu.const && qu.volatile -> 
         [i1 +> op +> lop; i2 +> op], nothing_left
     | _ -> raise Impossible
   in
   (qu, iiqu'), 
    (match ty, iity with
    | (ParenType t, _)                           -> 
        failwith "not handling parentype"
    | (Array (eopt, t), [i1;i2])                 -> 
        failwith "not handling array"
    | (FunctionType (returnt, paramst), [i1;i2]) -> 
        failwith "not handling functiontype"
    | (Pointer (_,(Pointer _,_)), [i])                           -> 
        failwith "not handling pointer"

    (* sure that simple pointer, of if complex then catch in recursive call *)
    | (Pointer t, [i])                           -> 
        Pointer (distribute_mck_type (op, lop, nothing_right) t),
        [i +> op +> rop]

    | (StructUnion (sopt, (su, fields)),iis) -> 
        failwith "not handling structunion"

    | (Enum  (sopt, enumt), iis) -> 
        failwith "not handling enum"

    | (BaseType base, iis) -> 
        BaseType base,
        (match iis with
        | [] -> raise Impossible
        | [i] -> [i +> op +> lop +> rop]
        | x::y::xs -> 
            let (head, middle, tail) = head_middle_tail (x::y::xs) in
            [head +> op +> lop] @ List.map op middle @ [tail +> op +> rop]
        )
          
    | (StructUnionName (s, structunion), [i1;i2]) -> 
        StructUnionName (s, structunion), [i1 +> op +> lop; i2 +> op +> rop]
          
    | (EnumName  s, [i1;i2]) -> 
        EnumName s, [i1 +> op +> lop; i2 +> op +> rop]

    | (TypeName (s), [i1]) -> 
        TypeName s, [i1 +> op +> lop +> rop]
      

        

    | _ -> raise Impossible
    )
   
  

(* ------------------------------------------------------------------------- *)
and (distribute_mck_node: Control_flow_c.node2 distributer) = 
 fun (op,lop,rop) -> function
  | F.Enter | F.Exit | F.ErrorExit
  | F.CaseNode _
  | F.TrueNode | F.FalseNode | F.AfterNode | F.FallThroughNode
    -> raise Impossible
  | F.FunHeader _  -> raise Impossible

  | F.EndStatement None -> raise Impossible
  | F.EndStatement (Some i) -> 
      F.EndStatement (Some (i +> op +> lop +> rop))
  | F.Decl decl -> F.Decl (distribute_mck_decl (op, lop, rop) decl) 

  | F.SeqStart (st, level, i1) -> 
      F.SeqStart (st, level, 
                  i1 +> op +> lop +> rop) 
  | F.SeqEnd (level, i2) -> 
      F.SeqEnd (level, 
                i2 +> op +> lop +> rop)


  | F.ExprStatement (st, (None, [i])) -> 
      F.ExprStatement (st, (None, 
                            [i +> op +> lop +> rop]))
  (* when there is a None ? for instance with the else of a just_ifthen *)
  | F.ExprStatement (st, (None, [])) ->  F.ExprStatement (st, (None, []))
  | F.ExprStatement (st, (Some e, [i])) -> 
      F.ExprStatement (st, 
                       (Some (distribute_mck_e (op, lop, nothing_right) e),
                       [i +> op +> rop]))
   (* the last ExprStatement of a for does not have a trailing ';' hence the
      [] for ii.  *)
  | F.ExprStatement (st, (Some e, [])) -> 
      F.ExprStatement (st, (Some (distribute_mck_e (op, lop, rop) e), []))



  | F.IfHeader (st, (e, [i1;i2;i3])) -> 
      F.IfHeader (st,
                  (distribute_mck_e (op, nothing_left, nothing_right) e,
                   [i1 +> op +> lop; i2 +> op; i3 +> op +> rop]))
                 
  | F.Else ii -> F.Else (ii +> op +> lop +> rop)

  | F.WhileHeader (st, (e, [i1;i2;i3])) -> 
      F.WhileHeader (st, 
                     (distribute_mck_e (op, nothing_left, nothing_right) e,
                      [i1 +> op +> lop; i2 +> op; i3 +> op +> rop]))

  | F.DoHeader (st, ii) -> F.DoHeader (st, ii +> op +> lop +> rop)
  | F.DoWhileTail (e, [i1;i2;i3;i4]) -> 
      F.DoWhileTail (distribute_mck_e (op, nothing_left, nothing_right) e,
                     [i1 +> op +> lop; i2 +> op; i3 +> op; i4 +> op +> rop])

  | F.ForHeader (st, (((e1opt,il1),(e2opt,il2),(e3opt, il3)), [i1;i2;i3])) -> 
      assert (null il3);
      F.ForHeader (st, 
          (((map_option (distribute_mck_e (op, nothing_left, nothing_right)) 
               e1opt, il1 +> List.map op),
            (map_option (distribute_mck_e (op, nothing_left, nothing_right)) 
               e2opt, il2 +> List.map op),
            (map_option (distribute_mck_e (op, nothing_left, nothing_right)) 
               e3opt, il3 +> List.map op)),
           [i1 +> op +> lop; i2 +> op; i3 +> op +> rop]))


  | F.SwitchHeader (st, (e, [i1;i2;i3])) -> 
      F.SwitchHeader (st, 
                      (distribute_mck_e (op, nothing_left, nothing_right) e,
                       [i1 +> op +> lop; i2 +> op; i3 +> op +> rop]))

  | F.Return   (st, ((), [i1;i2])) -> 
      F.Return (st, ((), 
                     [i1 +> op +> lop; i2 +> op +> rop]))
  | F.ReturnExpr (st, (e, [i1;i2])) -> 
      F.ReturnExpr (st, 
                    (distribute_mck_e (op, nothing_left, nothing_right) e,
                     [i1 +> op +> lop; i2 +> op +> rop]))

  (* ------------------------ *)
  (* no counter part in cocci *)
  | F.Label (st, (s, [i1;i2])) -> 
      F.Label (st, (s, 
                    [i1 +> op +> lop; i2 +> op +> rop]))
  | F.Case  (st, (e, [i1;i2])) -> 
      F.Case (st, 
              (distribute_mck_e (op, nothing_left, nothing_right) e,
               [i1 +> op +> lop; i2 +> op +> rop]))
  | F.CaseRange (st,  ((e1, e2), ii)) -> raise Todo
  | F.Default (st, ((), [i1; i2])) -> 
      F.Default (st, ((), 
                      [i1 +> op +> lop; i2 +> op +> rop]))

  | F.Goto (st, (s, [i1;i2;i3])) -> 
      F.Goto (st, (s, 
                   [i1 +> op +> lop; i2 +> op; i3 +> op +> rop]))
  | F.Continue (st, ((), [i1;i2])) -> 
      F.Continue (st, ((),
                       [i1 +> op +> lop; i2 +> op +> rop]))

  | F.Break   (st, ((), [i1;i2])) -> 
      F.Break (st, ((),
                       [i1 +> op +> lop; i2 +> op +> rop]))

  | F.Asm -> F.Asm

  | _ -> raise Impossible


(* ------------------------------------------------------------------------- *)
and distribute_mck_arge = fun (op, lop, rop) -> 
  let trans_arg (op, lop, rop) = function
    | Left e -> Left (distribute_mck_e (op, lop, rop) e)
    | Right _ -> raise Todo
  in 
  function
  | [] -> raise Todo (* Impossible ? *)
  | [exp, ii] -> 
      assert (null ii);
      [trans_arg (op, lop, rop) exp, ii]
     
  | x::y::xs -> 
     let ((head,ii1), middle, (tail,ii2)) = head_middle_tail (x::y::xs) in
      assert (null ii1);
      [trans_arg (op, lop, nothing_right) head, ii1]
      @
      List.map (fun (e, ii) -> 
           trans_arg (op, nothing_left, nothing_right) e,
           ii +> List.map op)
       middle
      @
      [trans_arg (op, nothing_left, rop) tail, ii1 +> List.map op]
      



and distribute_mck_params = fun (op, lop, rop) -> 
  let trans_arg (op, lop, rop) = function
    | ((b, s, t), ii_b_s) -> 
        (match b, s, ii_b_s with
        | false, Some s, [i1] -> 
            (* TODO normally could not do stuff on i1 as is
             * we should have a distribute_mck_type_with_ident func 
             *)
            (false, Some s, distribute_mck_type (op, lop, nothing_right) t),
            [i1 +> op +> rop]

        | true, Some s, [i1;i2] -> 
            (true, Some s, 
            distribute_mck_type (op, nothing_left, nothing_right) t),
            [i1 +> op +> lop;  i2 +> op +> rop]
        (* in definition we have name for params, except when f(void) *)
        | _, None, _ -> raise Impossible 
        | _ -> raise Impossible
        )
        
  in 
  function
  | [] -> raise Todo (* Impossible ? *)
  | [exp, ii] -> 
      assert (null ii);
      [trans_arg (op, lop, rop) exp, ii]
     
  | x::y::xs -> 
     let ((head,ii1), middle, (tail,ii2)) = head_middle_tail (x::y::xs) in
     assert (null ii1);
      [trans_arg (op, lop, nothing_right) head, ii1]
      @
      List.map (fun (e, ii) -> 
           trans_arg (op, nothing_left, nothing_right) e,
           ii +> List.map op)
       middle
      @
      [trans_arg (op, nothing_left, rop) tail, ii1 +> List.map op]
      



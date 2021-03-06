open Ast_mapper;;
open Ast_helper;;
open Asttypes;;
open Parsetree;;
open Location;;
open Longident;;

let ocaml_monadic_mapper argv =
  (* We override the expr mapper to catch bind and orzero.  *)
  { default_mapper with
    expr = fun mapper expr ->
      match expr with
      | [%expr [%bind [%e? expr]]] ->
        (* Matches "bind"-annotated expressions. *)
        begin
          match expr.pexp_desc with
          | Pexp_let(Nonrecursive, value_bindings, body) ->
            (* This is a let%bind expression!  It's of the form
                 let%bind $p1 = $e1 and ... and $pn = $en in $e0
               and we want it to take the form
                 bind $e1 (fun $p1 -> ... bind $en (fun $pn -> ...) ...)
            *)
            let rec bind_wrap value_bindings' =
              match value_bindings' with
              | { pvb_pat = bind_pattern
                ; pvb_expr = bind_expr
                ; pvb_attributes = []
                ; pvb_loc = bind_loc
                }::value_bindings'' ->
                (* Recurse and then wrap the resulting body. *)
                let body' = bind_wrap value_bindings'' in
                let cont_function =
                  [%expr fun [%p bind_pattern] -> [%e body']]
                    [@metaloc expr.pexp_loc]
                in
                [%expr
                  bind [%e mapper.expr mapper bind_expr] [%e cont_function]]
                  [@metaloc expr.pexp_loc]
              | _ ->
                (* Nothing left to do.  Just return the body. *)
                mapper.expr mapper body
            in
            bind_wrap value_bindings
          | _ -> expr
        end
      | [%expr [%orzero [%e? expr]]] ->
        (* Matches "orzero"-annotated expressions. *)
        begin
          match expr.pexp_desc with
          | Pexp_let(Nonrecursive, value_bindings, body) ->
            (* This is a let%orzero expression.  It's of the form
                 let%orzero $p1 = $e1 and ... and $pn = $en in $e0
               and we want it to take the form
                 match $e1 with
                 | $p1 -> (match $e2 with
                           | $p2 -> ...
                                    (match $en with
                                     | $pn -> $e0
                                     | _ -> zero ())
                           | _ -> zero ())
                 | _ -> zero ()
            *)
            let rec orzero_wrap value_bindings' =
              match value_bindings' with
              | { pvb_pat = orzero_pattern
                ; pvb_expr = orzero_expr
                ; pvb_attributes = []
                ; pvb_loc = orzero_loc
                }::value_bindings'' ->
                (* Recurse and then wrap the resulting body. *)
                let body' = orzero_wrap value_bindings'' in
                [%expr
                  match [%e mapper.expr mapper orzero_expr] with
                  | [%p orzero_pattern] -> [%e body']
                  | _ -> zero ()
                ]
                  [@metaloc expr.pexp_loc]
              | _ ->
                (* Nothing left to do.  Just return the body. *)
                mapper.expr mapper body
            in
            orzero_wrap value_bindings
          | _ -> expr
        end
      | [%expr [%guard [%e? guard_expr]]; [%e? body_expr]] ->
        (* This is a sequenced expression with a [%guard ...] extension.  It
           takes the form
             [%guard expr']; expr
           and we want it to take the form
             if expr' then expr else zero ()
        *)
        mapper.expr mapper
          [%expr if [%e guard_expr] then [%e body_expr] else zero ()]
          [@metaloc expr.pexp_loc]
      | _ -> default_mapper.expr mapper expr
  }
;;

(*
 * Copyright (c) 2014-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

(** Module for the checks called by Eradicate. *)

(* do not report RETURN_NOT_NULLABLE if the return is annotated @Nonnull *)
let return_nonnull_silent = true

let get_field_annotation tenv fn typ =
  let lookup = Tenv.lookup tenv in
  match Typ.Struct.get_field_type_and_annotation ~lookup fn typ with
  | None ->
      None
  | Some (t, ia) ->
      let ia' =
        (* TODO (t4968422) eliminate not !Config.eradicate check by marking fields as nullified *)
        (* outside of Eradicate in some other way *)
        if not Config.eradicate then AnnotatedSignature.mk_ia AnnotatedSignature.Nullable ia
        else ia
      in
      Some (t, ia')


let report_error tenv = TypeErr.report_error tenv (EradicateCheckers.report_error tenv)

let explain_expr tenv node e =
  match Errdesc.exp_rv_dexp tenv node e with
  | Some de ->
      Some (DecompiledExp.to_string de)
  | None ->
      None


(** Classify a procedure. *)
let classify_procedure proc_attributes =
  let pn = proc_attributes.ProcAttributes.proc_name in
  let unique_id = Typ.Procname.to_unique_id pn in
  let classification =
    if Models.is_modelled_nullable pn then "M" (* modelled *)
    else if Summary.proc_is_library proc_attributes then "L" (* library *)
    else if not proc_attributes.ProcAttributes.is_defined then "S" (* skip *)
    else if String.is_prefix ~prefix:"com.facebook" unique_id then "F" (* FB *)
    else "?"
  in
  classification


let is_virtual = function (p, _, _) :: _ when Mangled.is_this p -> true | _ -> false

(** Check an access (read or write) to a field. *)
let check_field_access tenv find_canonical_duplicate curr_pname node instr_ref exp fname ta loc :
    unit =
  if TypeAnnotation.get_value AnnotatedSignature.Nullable ta then
    let origin_descr = TypeAnnotation.descr_origin ta in
    report_error tenv find_canonical_duplicate
      (TypeErr.Null_field_access (explain_expr tenv node exp, fname, origin_descr, false))
      (Some instr_ref) loc curr_pname


(** Check an access to an array *)
let check_array_access tenv find_canonical_duplicate curr_pname node instr_ref array_exp fname ta
    loc indexed =
  if TypeAnnotation.get_value AnnotatedSignature.Nullable ta then
    let origin_descr = TypeAnnotation.descr_origin ta in
    report_error tenv find_canonical_duplicate
      (TypeErr.Null_field_access (explain_expr tenv node array_exp, fname, origin_descr, indexed))
      (Some instr_ref) loc curr_pname


(** Where the condition is coming from *)
type from_call =
  | From_condition  (** Direct condition *)
  | From_instanceof  (** x instanceof C *)
  | From_is_false_on_null  (** returns false on null *)
  | From_is_true_on_null  (** returns true on null *)
  | From_optional_isPresent  (** x.isPresent *)
  | From_containsKey  (** x.containsKey *)
[@@deriving compare]

let equal_from_call = [%compare.equal: from_call]

(** Check the normalized "is zero" or "is not zero" condition of a prune instruction. *)
let check_condition tenv case_zero find_canonical_duplicate curr_pdesc node e typ ta true_branch
    from_call idenv linereader loc instr_ref : unit =
  let is_fun_nonnull ta =
    match TypeAnnotation.get_origin ta with
    | TypeOrigin.Proc proc_origin ->
        let ia, _ = proc_origin.TypeOrigin.annotated_signature.AnnotatedSignature.ret in
        Annotations.ia_is_nonnull ia
    | _ ->
        false
  in
  let contains_instanceof_throwable pdesc node =
    (* Check if the current procedure has a catch Throwable. *)
    (* That always happens in the bytecode generated by try-with-resources. *)
    let loc = Procdesc.Node.get_loc node in
    let throwable_found = ref false in
    let typ_is_throwable {Typ.desc} =
      match desc with
      | Typ.Tstruct (Typ.JavaClass _ as name) ->
          String.equal (Typ.Name.name name) "java.lang.Throwable"
      | _ ->
          false
    in
    let do_instr = function
      | Sil.Call (_, Exp.Const (Const.Cfun pn), [_; (Exp.Sizeof {typ}, _)], _, _)
        when Typ.Procname.equal pn BuiltinDecl.__instanceof && typ_is_throwable typ ->
          throwable_found := true
      | _ ->
          ()
    in
    let do_node n =
      if Location.equal loc (Procdesc.Node.get_loc n) then
        Instrs.iter ~f:do_instr (Procdesc.Node.get_instrs n)
    in
    Procdesc.iter_nodes do_node pdesc ; !throwable_found
  in
  let from_try_with_resources () : bool =
    (* heuristic to check if the condition is the translation of try-with-resources *)
    match Printer.LineReader.from_loc linereader loc with
    | Some line ->
        (not (String.is_substring ~substring:"==" line || String.is_substring ~substring:"!=" line))
        && String.is_substring ~substring:"}" line
        && contains_instanceof_throwable curr_pdesc node
    | None ->
        false
  in
  let is_temp = Idenv.exp_is_temp idenv e in
  let nonnull = is_fun_nonnull ta in
  let should_report =
    (not (TypeAnnotation.get_value AnnotatedSignature.Nullable ta))
    && (Config.eradicate_condition_redundant || nonnull)
    && true_branch && ((not is_temp) || nonnull) && PatternMatch.type_is_class typ
    && (not (from_try_with_resources ()))
    && equal_from_call from_call From_condition
    && not (TypeAnnotation.origin_is_fun_library ta)
  in
  let is_always_true = not case_zero in
  let nonnull = is_fun_nonnull ta in
  if should_report then
    report_error tenv find_canonical_duplicate
      (TypeErr.Condition_redundant (is_always_true, explain_expr tenv node e, nonnull))
      (Some instr_ref) loc curr_pdesc


(** Check an "is zero" condition. *)
let check_zero tenv find_canonical_duplicate = check_condition tenv true find_canonical_duplicate

(** Check an "is not zero" condition. *)
let check_nonzero tenv find_canonical_duplicate =
  check_condition tenv false find_canonical_duplicate


(** Check an assignment to a field. *)
let check_field_assignment tenv find_canonical_duplicate curr_pdesc node instr_ref typestate
    exp_lhs exp_rhs typ loc fname t_ia_opt typecheck_expr : unit =
  let curr_pname = Procdesc.get_proc_name curr_pdesc in
  let t_lhs, ta_lhs, _ =
    typecheck_expr node instr_ref curr_pdesc typestate exp_lhs
      (typ, TypeAnnotation.const AnnotatedSignature.Nullable false TypeOrigin.ONone, [loc])
      loc
  in
  let _, ta_rhs, _ =
    typecheck_expr node instr_ref curr_pdesc typestate exp_rhs
      (typ, TypeAnnotation.const AnnotatedSignature.Nullable false TypeOrigin.ONone, [loc])
      loc
  in
  let should_report_nullable =
    let field_is_field_injector_readwrite () =
      match t_ia_opt with
      | Some (_, ia) ->
          Annotations.ia_is_field_injector_readwrite ia
      | _ ->
          false
    in
    (not (AndroidFramework.is_destroy_method curr_pname))
    && (not (TypeAnnotation.get_value AnnotatedSignature.Nullable ta_lhs))
    && TypeAnnotation.get_value AnnotatedSignature.Nullable ta_rhs
    && PatternMatch.type_is_class t_lhs
    && (not (Typ.Fieldname.Java.is_outer_instance fname))
    && not (field_is_field_injector_readwrite ())
  in
  let should_report_absent =
    Config.eradicate_optional_present
    && TypeAnnotation.get_value AnnotatedSignature.Present ta_lhs
    && (not (TypeAnnotation.get_value AnnotatedSignature.Present ta_rhs))
    && not (Typ.Fieldname.Java.is_outer_instance fname)
  in
  let should_report_mutable =
    let field_is_mutable () =
      match t_ia_opt with Some (_, ia) -> Annotations.ia_is_mutable ia | _ -> false
    in
    Config.eradicate_field_not_mutable
    && (not (Typ.Procname.is_constructor curr_pname))
    && ( match curr_pname with
       | Typ.Procname.Java java_pname ->
           not (Typ.Procname.Java.is_class_initializer java_pname)
       | _ ->
           true )
    && not (field_is_mutable ())
  in
  ( if should_report_nullable || should_report_absent then
    let ann =
      if should_report_nullable then AnnotatedSignature.Nullable else AnnotatedSignature.Present
    in
    let origin_descr = TypeAnnotation.descr_origin ta_rhs in
    report_error tenv find_canonical_duplicate
      (TypeErr.Field_annotation_inconsistent (ann, fname, origin_descr))
      (Some instr_ref) loc curr_pdesc ) ;
  if should_report_mutable then
    let origin_descr = TypeAnnotation.descr_origin ta_rhs in
    report_error tenv find_canonical_duplicate
      (TypeErr.Field_not_mutable (fname, origin_descr))
      (Some instr_ref) loc curr_pdesc


(** Check that nonnullable fields are initialized in constructors. *)
let check_constructor_initialization tenv find_canonical_duplicate curr_pname curr_pdesc start_node
    final_initializer_typestates final_constructor_typestates loc : unit =
  State.set_node start_node ;
  if Typ.Procname.is_constructor curr_pname then
    match PatternMatch.get_this_type (Procdesc.get_attributes curr_pdesc) with
    | Some {desc= Tptr (({desc= Tstruct name} as ts), _)} -> (
      match Tenv.lookup tenv name with
      | Some {fields} ->
          let do_field (fn, ft, _) =
            let annotated_with f =
              match get_field_annotation tenv fn ts with None -> false | Some (_, ia) -> f ia
            in
            let nullable_annotated = annotated_with Annotations.ia_is_nullable in
            let nonnull_annotated = annotated_with Annotations.ia_is_nonnull in
            let injector_readonly_annotated =
              annotated_with Annotations.ia_is_field_injector_readonly
            in
            let final_type_annotation_with unknown list f =
              let filter_range_opt = function Some (_, ta, _) -> f ta | None -> unknown in
              List.exists
                ~f:(function
                  | pname, typestate ->
                      let pvar =
                        Pvar.mk (Mangled.from_string (Typ.Fieldname.to_string fn)) pname
                      in
                      filter_range_opt (TypeState.lookup_pvar pvar typestate) )
                list
            in
            let may_be_assigned_in_final_typestate =
              let origin_is_initialized = function
                | TypeOrigin.Undef ->
                    false
                | TypeOrigin.Field (TypeOrigin.Formal name, _, _) ->
                    let circular = Mangled.is_this name in
                    not circular
                | _ ->
                    true
              in
              final_type_annotation_with false (Lazy.force final_initializer_typestates) (fun ta ->
                  origin_is_initialized (TypeAnnotation.get_origin ta) )
            in
            let may_be_nullable_in_final_typestate () =
              final_type_annotation_with true (Lazy.force final_constructor_typestates) (fun ta ->
                  TypeAnnotation.get_value AnnotatedSignature.Nullable ta )
            in
            let should_check_field_initialization =
              let in_current_class =
                let fld_cname = Typ.Fieldname.Java.get_class fn in
                String.equal (Typ.Name.name name) fld_cname
              in
              (not injector_readonly_annotated) && PatternMatch.type_is_class ft
              && in_current_class
              && not (Typ.Fieldname.Java.is_outer_instance fn)
            in
            if should_check_field_initialization then (
              (* Check if field is missing annotation. *)
              if
                (not (nullable_annotated || nonnull_annotated))
                && not may_be_assigned_in_final_typestate
              then
                report_error tenv find_canonical_duplicate
                  (TypeErr.Field_not_initialized (fn, curr_pname))
                  None loc curr_pdesc ;
              (* Check if field is over-annotated. *)
              if
                Config.eradicate_field_over_annotated && nullable_annotated
                && not (may_be_nullable_in_final_typestate ())
              then
                report_error tenv find_canonical_duplicate
                  (TypeErr.Field_over_annotated (fn, curr_pname))
                  None loc curr_pdesc )
          in
          List.iter ~f:do_field fields
      | None ->
          () )
    | _ ->
        ()


(** Check the annotations when returning from a method. *)
let check_return_annotation tenv find_canonical_duplicate curr_pdesc ret_range
    (annotated_signature : AnnotatedSignature.t) ret_implicitly_nullable loc : unit =
  let ret_ia, _ = annotated_signature.ret in
  let curr_pname = Procdesc.get_proc_name curr_pdesc in
  let ret_annotated_nullable =
    Annotations.ia_is_nullable ret_ia
    || List.exists
         ~f:(fun (_, ia, _) -> Annotations.ia_is_propagates_nullable ia)
         annotated_signature.params
  in
  let ret_annotated_present = Annotations.ia_is_present ret_ia in
  let ret_annotated_nonnull = Annotations.ia_is_nonnull ret_ia in
  match ret_range with
  (* Disables the warnings since it is not clear how to annotate the return value of lambdas *)
  | Some _
    when match curr_pname with
         | Typ.Procname.Java java_pname ->
             Typ.Procname.Java.is_lambda java_pname
         | _ ->
             false ->
      ()
  | Some (_, final_ta, _) ->
      let final_nullable = TypeAnnotation.get_value AnnotatedSignature.Nullable final_ta in
      let final_present = TypeAnnotation.get_value AnnotatedSignature.Present final_ta in
      let origin_descr = TypeAnnotation.descr_origin final_ta in
      let return_not_nullable =
        final_nullable && (not ret_annotated_nullable) && (not ret_implicitly_nullable)
        && not (return_nonnull_silent && ret_annotated_nonnull)
      in
      let return_value_not_present =
        Config.eradicate_optional_present && (not final_present) && ret_annotated_present
      in
      let return_over_annotated =
        (not final_nullable) && ret_annotated_nullable && Config.eradicate_return_over_annotated
      in
      ( if return_not_nullable || return_value_not_present then
        let ann =
          if return_not_nullable then AnnotatedSignature.Nullable else AnnotatedSignature.Present
        in
        report_error tenv find_canonical_duplicate
          (TypeErr.Return_annotation_inconsistent (ann, curr_pname, origin_descr))
          None loc curr_pdesc ) ;
      if return_over_annotated then
        report_error tenv find_canonical_duplicate (TypeErr.Return_over_annotated curr_pname) None
          loc curr_pdesc
  | None ->
      ()


(** Check the receiver of a virtual call. *)
let check_call_receiver tenv find_canonical_duplicate curr_pdesc node typestate call_params
    callee_pname (instr_ref : TypeErr.InstrRef.t) loc typecheck_expr : unit =
  match call_params with
  | ((original_this_e, this_e), typ) :: _ ->
      let _, this_ta, _ =
        typecheck_expr tenv node instr_ref curr_pdesc typestate this_e
          (typ, TypeAnnotation.const AnnotatedSignature.Nullable false TypeOrigin.ONone, [])
          loc
      in
      let null_method_call = TypeAnnotation.get_value AnnotatedSignature.Nullable this_ta in
      let optional_get_on_absent =
        Config.eradicate_optional_present
        && Models.is_optional_get callee_pname
        && not (TypeAnnotation.get_value AnnotatedSignature.Present this_ta)
      in
      if null_method_call || optional_get_on_absent then
        let ann =
          if null_method_call then AnnotatedSignature.Nullable else AnnotatedSignature.Present
        in
        let descr = explain_expr tenv node original_this_e in
        let origin_descr = TypeAnnotation.descr_origin this_ta in
        report_error tenv find_canonical_duplicate
          (TypeErr.Call_receiver_annotation_inconsistent (ann, descr, callee_pname, origin_descr))
          (Some instr_ref) loc curr_pdesc
  | [] ->
      ()


type resolved_param =
  { num: int
  ; formal: Mangled.t * TypeAnnotation.t * Typ.t
  ; actual: Exp.t * TypeAnnotation.t
  ; propagates_nullable: bool }

(** Check the parameters of a call. *)
let check_call_parameters tenv find_canonical_duplicate curr_pdesc node callee_attributes
    resolved_params loc instr_ref : unit =
  let callee_pname = callee_attributes.ProcAttributes.proc_name in
  let check {num= param_num; formal= s1, ta1, t1; actual= orig_e2, ta2} =
    let report ann =
      let description =
        match explain_expr tenv node orig_e2 with
        | Some descr ->
            descr
        | None ->
            "formal parameter " ^ Mangled.to_string s1
      in
      let origin_descr = TypeAnnotation.descr_origin ta2 in
      let callee_loc = callee_attributes.ProcAttributes.loc in
      report_error tenv find_canonical_duplicate
        (TypeErr.Parameter_annotation_inconsistent
           (ann, description, param_num, callee_pname, callee_loc, origin_descr))
        (Some instr_ref) loc curr_pdesc
    in
    let check_ann ann =
      let b1 = TypeAnnotation.get_value ann ta1 in
      let b2 = TypeAnnotation.get_value ann ta2 in
      match (ann, b1, b2) with
      | AnnotatedSignature.Nullable, false, true ->
          report ann
      | AnnotatedSignature.Present, true, false ->
          report ann
      | _ ->
          ()
    in
    if PatternMatch.type_is_class t1 then (
      check_ann AnnotatedSignature.Nullable ;
      if Config.eradicate_optional_present then check_ann AnnotatedSignature.Present )
  in
  let should_check_parameters =
    match callee_pname with
    | Typ.Procname.Java java_pname ->
        (not (Typ.Procname.Java.is_external java_pname))
        || Models.is_modelled_nullable callee_pname
    | _ ->
        false
  in
  if should_check_parameters then
    (* left to right to avoid guessing the different lengths *)
    List.iter ~f:check resolved_params


(** Checks if the annotations are consistent with the inherited class or with the
    implemented interfaces *)
let check_overridden_annotations find_canonical_duplicate tenv proc_name proc_desc
    annotated_signature =
  let start_node = Procdesc.get_start_node proc_desc in
  let loc = Procdesc.Node.get_loc start_node in
  let check_return overriden_proc_name overriden_signature =
    let ret_is_nullable =
      let ia, _ = annotated_signature.AnnotatedSignature.ret in
      Annotations.ia_is_nullable ia
    and ret_overridden_nullable =
      let overriden_ia, _ = overriden_signature.AnnotatedSignature.ret in
      Annotations.ia_is_nullable overriden_ia
    in
    if ret_is_nullable && not ret_overridden_nullable then
      report_error tenv find_canonical_duplicate
        (TypeErr.Inconsistent_subclass_return_annotation (proc_name, overriden_proc_name))
        None loc proc_desc
  and check_params overriden_proc_name overriden_signature =
    let compare pos current_param overriden_param : int =
      let current_name, current_ia, _ = current_param in
      let _, overriden_ia, _ = overriden_param in
      let () =
        if (not (Annotations.ia_is_nullable current_ia)) && Annotations.ia_is_nullable overriden_ia
        then
          report_error tenv find_canonical_duplicate
            (TypeErr.Inconsistent_subclass_parameter_annotation
               (Mangled.to_string current_name, pos, proc_name, overriden_proc_name))
            None loc proc_desc
      in
      pos + 1
    in
    (* TODO (#5280249): investigate why argument lists can be of different length *)
    let current_params = annotated_signature.AnnotatedSignature.params
    and overridden_params = overriden_signature.AnnotatedSignature.params in
    let initial_pos = if is_virtual current_params then 0 else 1 in
    if Int.equal (List.length current_params) (List.length overridden_params) then
      ignore (List.fold2_exn ~f:compare ~init:initial_pos current_params overridden_params)
  in
  let check overriden_proc_name =
    match PatternMatch.lookup_attributes tenv overriden_proc_name with
    | Some attributes -> (
        let overridden_signature = Models.get_modelled_annotated_signature attributes in
        check_params overriden_proc_name overridden_signature ;
        (* the analysis should not report return type inconsistencies with external code *)
        match overriden_proc_name with
        | Typ.Procname.Java java_pname when not (Typ.Procname.Java.is_external java_pname) ->
            check_return overriden_proc_name overridden_signature
        | _ ->
            () )
    | None ->
        ()
  in
  PatternMatch.override_iter check tenv proc_name

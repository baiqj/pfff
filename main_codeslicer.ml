(*
 * Please imagine a long and boring gnu-style copyright notice 
 * appearing just here.
 *)
open Common

(*****************************************************************************)
(* Purpose *)
(*****************************************************************************)
(* Extract the "core", the essential parts of a codebase, the signal versus
 * the noise!
 * 
 * Using codemap is great to navigate a large codebase and codegraph is
 * great to get a first high level view of its software architecture,
 * but on very very large codebase, it is still very hard to find and
 * understand the "core" of a software. For instance on the Linux kernel,
 * the drivers take more than 50% of the codebase, but none of those
 * drivers are actually essential to understand the "core" of Linux.
 * Once you've seen one driver you got the main ideas and seeing
 * another driver will not improve significantly your comprehension
 * of the whole codebase. In some cases such as www, the whole codebase is so
 * messy that even codegraph has a hard time to convey the software
 * architecture as it's difficult to find a meaningful layering of the code
 * because of the too many backward dependencies.
 * 
 * Fortunately in most codebase a lots of things are actual plugins
 * or extensions of a core (for Linux it is the many device drivers,
 * file systems, internet protocols, etc). The goal of codeslicer is
 * to detect those less important extensions and to offer a view of
 * the codebase where only the essential things have been kept.
 * The resulting codebase will hopefully be far smaller and have
 * better layering properties. One can then use codegraph and codemap
 * on this subset.
 * 
 * Note that the codemap/codegraph slicing feature offers in part
 * the "get a subset of a codebase" functionality described here. But codemap
 * requires the programmer to know where to start slicing from (usually 
 * the main()) and the slice can actually contain many extensions.
 * 
 * A nice side effect of the codeslicer is that because the resulting codebase
 * is far smaller it's also faster to run expensive analysis that are 
 * currently hard to scale to millions LOC (e.g. datalog, but even codegraph
 * and codemap which have troubles to scale to www).
 * 
 * history:
 *  - I had a simple code slicer using graph_code that I used to get
 *    all the code relevant to arc build (on which I could run
 *    codegraph with class analysis ON)
 *  - I was doing lots of manual codeslicing when working on Kernel.tex.nw
 *    by removing many device drivers, internet protocols, file systems
 *  - I was doing even more manual codeslicing when LPizing the whole plan9
 *    by removing support for many architectures, hosts, less important
 *    programs, compatability with other operating systems, less important
 *    or obsolete features. Then came the idea of trying to automate this
 *    codeslicing, especially for www.
 *)

(*****************************************************************************)
(* Flags *)
(*****************************************************************************)

(* In addition to flags that can be tweaked via -xxx options (cf the
 * full list of options in the "the options" section below), this 
 * program also depends on external files ?
 *)

let verbose = ref false

let lang = ref "c"

let output_dir = ref "CODESLICER"

(* action mode *)
let action = ref ""

(*****************************************************************************)
(* Some debugging functions *)
(*****************************************************************************)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(*****************************************************************************)
(* Main action *)
(*****************************************************************************)
let main_action _xs = 
  raise Todo 

(*****************************************************************************)
(* LPizer *)
(*****************************************************************************)
(* In this file because it can't be put in syncweb/ (it uses graph_code_c),
 * and it's a form of code slicing ...
 *)

(* for lpification, to get a list of files and handling the skip list *)
let find_source xs =
  let root = Common2.common_prefix_of_files_or_dirs xs in
  let root = Common.realpath root +> Common2.chop_dirsymbol in
  let files = 
    Find_source.files_of_dir_or_files ~lang:!lang ~verbose:!verbose xs in
  files +> List.iter (fun file ->
    pr (Common.readable root file)
  )

(* syncweb does not like tabs *)
let untabify s =
  Str.global_substitute (Str.regexp "^\\([\t]+\\)") (fun _wholestr ->
    let substr = Str.matched_string s in
    let n = String.length substr in
    Common2.n_space (4 * n)
  ) s

(* todo: could generalize this in graph_code.ml! have a range
 * property there!
 *)
type entity = {
  name: string;
  kind: Entity_code.entity_kind;
  range: int * int;
}

open Ast_cpp
module Ast = Ast_cpp
module E = Entity_code
module PI = Parse_info

let hooks_for_comment = { Comment_code.
    kind = Token_helpers_cpp.token_kind_of_tok;
    tokf = Token_helpers_cpp.info_of_tok;
                        }

let range_of_any_with_comment any toks =
  let ii = Lib_parsing_cpp.ii_of_any any in
  let (min, max) = PI.min_max_ii_by_pos ii in
  match Comment_code.comment_before hooks_for_comment min toks with
  | None -> min, max
  | Some ii -> ii, max
  
type env = {
  current_file: Common.filename;
  cnt: int ref;
  hentities: (Graph_code.node, bool) Hashtbl.t;
}

let uniquify env kind s =
  let sfinal =
    if Hashtbl.mem env.hentities (s, kind) 
    then
      let s2 = spf "%s (%s)" s env.current_file in
      if Hashtbl.mem env.hentities (s2, kind)
      then begin
        incr env.cnt;
        let s3 = spf "%s (%s)%d" s env.current_file !(env.cnt) in
        if Hashtbl.mem env.hentities (s3, kind)
        then failwith "impossible"
        else s3
      end
      else s2
    else s
  in
  Hashtbl.replace env.hentities (sfinal, kind) true;
  sfinal

  

(* todo: could do that in graph_code_c, with a range *)
let extract_entities env xs =
  xs +> Common.map_filter (fun (top, toks) ->
    match top with
    | CppDirectiveDecl decl ->
      (match decl with
      | Define (_, ident, kind_define, _val) ->
        let kind =
          match kind_define with
            | DefineVar -> E.Constant
            | DefineFunc _ -> E.Macro
        in
        let (min, max) = range_of_any_with_comment (Toplevel top) toks in
        Some {
          name = fst ident +> uniquify env kind;
          kind = kind;
          range = (PI.line_of_info min, PI.line_of_info max);
        }
      | _ -> None
      )

    | DeclElem decl ->
      (match decl with
      | Func (FunctionOrMethod def) ->
        let (min, max) = range_of_any_with_comment (Toplevel top) toks in
        Some { 
          name = Ast.string_of_name_tmp def.f_name +> uniquify env E.Function;
          kind = E.Function;
          range = (PI.line_of_info min, PI.line_of_info max);
        }
      | BlockDecl decl ->
        let (min, max) = range_of_any_with_comment (Toplevel top) toks in
          (match decl with
          | DeclList ([x, _], _) ->
              (match x with
              (* prototype, don't care *)
              | { v_namei = Some (_name, None);
                  v_type = (_, (FunctionType _, _)); _
                } -> None

              (* typedef struct X { } X *)
              | { v_namei = _;
                  v_type = (_, (StructDef { c_name = Some name; _}, _)); 
                  v_storage = StoTypedef _; _
                } -> 
                Some { 
                  name = Ast.string_of_name_tmp name +> uniquify env E.Class;
                  kind = E.Class;
                  range = (PI.line_of_info min, PI.line_of_info max);
                }

              (* other typedefs, don't care *)
              | { v_namei = Some (_name, None);
                  v_storage = StoTypedef _; _
                } -> None
              (* global decl, don't care *)
              | { v_namei = Some (_name, None);
                  v_storage = (Sto (Extern, _)); _
                } -> None


              (* global def *)
              | { v_namei = Some (name, _);
                  v_storage = _; _
                } -> 
                Some { 
                  name = Ast.string_of_name_tmp name +> uniquify env E.Global;
                  kind = E.Global;
                  range = (PI.line_of_info min, PI.line_of_info max);
                }
              (* struct def *)
              | { v_namei = _;
                  v_type = (_, (StructDef { c_name = Some name; _}, _)); _
                } -> 
                Some { 
                  name = Ast.string_of_name_tmp name +> uniquify env E.Class;
                  kind = E.Class;
                  range = (PI.line_of_info min, PI.line_of_info max);
                }
              (* enum def *)
              | { v_namei = _;
                  v_type = (_, (EnumDef (_, Some ident, _), _));
                  _
                } -> 
                Some { 
                  name = 
                    Ast.string_of_name_tmp (None, [], IdIdent ident) 
                      +> uniquify env E.Type;
                  kind = E.Type;
                  range = (PI.line_of_info min, PI.line_of_info max);
                }

              (* enum anon *)
              | { v_namei = _;
                  v_type = (_, (EnumDef (_, None, _), _));
                  _
                } -> 
                Some { 
                  name = "_anon_"  +> uniquify env E.Type;
                  kind = E.Type;
                  range = (PI.line_of_info min, PI.line_of_info max);
                }
                

              | _ -> None
              )
          | _ -> None
          )
      | _ -> None
      )
    | _ -> None
  )

let sanity_check _xs =
(*
  let group_by_basename =
    xs +> List.map (fun file -> Filename.basename file, file)
    +> Common.group_assoc_bykey_eff
  in
  group_by_basename +> List.iter (fun (_base, xs) ->
    if List.length xs > 1
    then pr2 (spf "multiple files with same name: %s" 
                     (xs +> Common.join "\n"))
  );
*)
  ()

let string_of_entity_kind kind =
  match kind with
  | E.Function -> "function"
  | E.Global -> "global"
  | E.Type -> "enum"
  | E.Class -> "struct"
  | E.Constant -> "constant"
  | E.Macro -> "function"

  | _ -> failwith (spf "not handled kind: %s" (E.string_of_entity_kind kind))

(* main entry point *)
let lpize xs = 
  Parse_cpp.init_defs !Flag_parsing_cpp.macros_h;
  let root = Sys.getcwd () in
  let local = Filename.concat root "pfff_macros.h" in
  if Sys.file_exists local
  then Parse_cpp.add_defs local;

  sanity_check xs;
  let current_dir = ref "" in

  (* to avoid duped entities *)
  let hentities = Hashtbl.create 101 in

  xs +> List.iter (fun file ->
    let dir = Filename.dirname file in
    if dir <> !current_dir
    then begin
      pr (spf "\\section{[[%s/]]}" dir);
      pr "";
      current_dir := dir;
    end;

    pr (spf "\\subsection*{[[%s]]}" file);
    pr "";

    let (xs, _stat) = Parse_cpp.parse file in
    let env = {
      current_file = file;
      hentities = hentities;
      (* starts at 1 so that first have no int, just the filename
       * e.g.  function foo (foo.h), and then the second one have
       * function foo (foo.h)2
       *)
      cnt = ref 1;
    } in
    let entities = extract_entities env xs in

    let hstart = 
      entities +> List.map (fun e -> fst e.range, e) +> Common.hash_of_list
    in
    let hcovered = 
      entities +> List.map (fun e -> 
        let (lstart, lend) = e.range in
        Common2.enum_safe lstart lend
      ) +> List.flatten +> Common.hashset_of_list
    in
    
    let lines = Common.cat file in
    let arr = Array.of_list lines in

    (* the chunks *)
    entities +> List.iter (fun e ->
        let (lstart, lend) = e.range in
        pr (spf "<<%s %s>>=" (string_of_entity_kind e.kind) e.name);

        Common2.enum_safe lstart lend +> List.iter (fun line ->
          let idx = line - 1 in
          if idx >= Array.length arr || idx < 0
          then failwith (spf "out of range for %s, line %d" file line);
          pr (untabify (arr.(line - 1)))
        );
        pr "@";
        pr "";
    );

    pr "";
    pr "%-------------------------------------------------------------";
    pr "";

    (* we don't use the basename (even though 'make sync' ' used to make
     * this assumption because) because we would have too many dupes.
     *)
    pr (spf "<<%s>>=" file);
    Common.cat file +> Common.index_list_1 +> List.iter (fun (s, idx) ->
      match Common2.hfind_option idx hstart with
      | None -> 
          if Hashtbl.mem hcovered idx
          then ()
          else pr (untabify s)
      | Some e -> 
        pr (spf "<<%s %s>>" (string_of_entity_kind e.kind) e.name);
    );
    pr "@";
    pr "";
    pr "";

    (* for the initial 'make sync' to work *)
    (* Sys.command (spf "rm -f %s" file) +> ignore;   *)
  );
  ()

(*****************************************************************************)
(* Extra Actions *)
(*****************************************************************************)
module GC = Graph_code

let big_parent_branching_factor = 5


let find_big_branching_factor graph_file =
  let g = Graph_code.load graph_file in
  let hierarchy = Graph_code_class_analysis.class_hierarchy g in

  pr2 (spf "step0: number of nodes = %d" (Graph_code.nb_nodes g));

  (* step1: find the big parents and the children candidates to remove *)
  
  let big_parents = 
    hierarchy +> Graph.nodes +> List.filter (fun parent ->
      let children = Graph.succ parent hierarchy in
      (* should modulate by the branching factor of the parent? *)
      List.length children > big_parent_branching_factor
    )
  in

  (* initial set *)
  let hdead_candidates = 
    big_parents 
    (* todo: could keep 1? the biggest one in terms of use? *)
    +> List.map (fun parent -> Graph.succ parent hierarchy)
    +> List.flatten 
    (* transitive closure to also remove the fields, methods of a class *)
    +> List.map (fun node -> node::Graph_code.all_children node g)
    +> List.flatten
    +> Common.hashset_of_list
  in

  pr2 (spf "step1: big parents = %d, initial candidates for removal = %d"
         (List.length big_parents)
         (Hashtbl.length hdead_candidates));

  (* step2: make sure none of the candidate are used by live entities *)
  let live = ref (Graph_code.all_nodes g +> Common.exclude (fun node ->
    Hashtbl.mem hdead_candidates node
  ))
  in

  let make_live node =
    let xs = node::Graph_code.all_children node g in
    xs +> List.iter (fun node ->
      Hashtbl.remove hdead_candidates node;
      Common.push node live
    )
  in

  while !live <> [] do
    let this_round = !live in
    live := [];

    this_round +> List.iter (fun live_node ->
      let uses = Graph_code.succ live_node Graph_code.Use g in
      uses +> List.iter (fun use_of_live_node ->
        if Hashtbl.mem hdead_candidates use_of_live_node then begin
          make_live use_of_live_node
        end
      )
    )
  done;

  pr2 (spf "step2: candidates for removal = %d"
         (Hashtbl.length hdead_candidates));

  (* step3: mark as live parent (in the Has sense) of live entities *)

  (* step4: remove newly dead code (helpers of removed classes) *)

  let users_of_node = Graph_code.mk_eff_use_pred g in

  let dead = ref (Common.hashset_to_list hdead_candidates) in

  let make_dead node =
    let xs = node::Graph_code.all_children node g in
    xs +> List.iter (fun node ->
      Hashtbl.replace hdead_candidates node true;
      Common.push node dead
    )
  in

  while !dead <> [] do
    let this_round = !dead in
    dead := [];

    this_round +> List.iter (fun dead_node ->
      let uses = Graph_code.succ dead_node Graph_code.Use g in
      let live_uses_of_dead_code =
        uses +> Common.exclude (fun node -> Hashtbl.mem hdead_candidates node)
      in

      live_uses_of_dead_code +> List.iter (fun live_use_of_dead_node ->
        let xs = 
          let node = live_use_of_dead_node in
          node::Graph_code.all_children node g 
        in
        let hxs = Common.hashset_of_list xs in

        let users =
          xs +> List.map (fun node -> users_of_node node) +> List.flatten in
        
        (* maybe a newly dead! *)
        if users +> List.for_all (fun node ->
          Hashtbl.mem hdead_candidates node ||
          Hashtbl.mem hxs node
        ) 
        then make_dead live_use_of_dead_node
      )
    )
  done;
  
  pr2 (spf "step4: candidates for removal = %d"
         (Hashtbl.length hdead_candidates));

  ()


(* xs are the set of dirs or files we are interested in; the starting points
 * for the DFS.
 *)
let extract_transitive_deps xs =
  let pwd = Sys.getcwd () in
  let graph_file = Filename.concat pwd Graph_code.default_filename in
  let g = Graph_code.load graph_file in

  let hdone = Hashtbl.create 101 in

  let max_depth = 4 in
  
  let start_nodes = 
    xs +> List.map (fun path ->
      let node =
        if Sys.is_directory path
        then path, E.Dir
        else path, E.File
      in
      if not (GC.has_node node g)
      then failwith (spf "could not find %s" path);
      node
    )
  in
  let rec dfs depth xs =
    match xs with
    | [] -> ()
    (* www specific, do not include the transitive deps of flib_init() *)
    | ("flib_init", E.Function)::xs -> dfs depth xs
    | n::xs ->
        (if Hashtbl.mem hdone n || depth > max_depth
        then ()
        else begin
          Hashtbl.add hdone n true;
          let uses = GC.succ n GC.Use g in
          dfs (depth + 1) uses;
          let children = GC.children n g in
          (* we want all children, especially subdirectories *)
          dfs (depth + 0) children
        end);
        dfs depth xs
      
  in
  dfs 0 start_nodes;
  let files = hdone +> Common.hashset_to_list +> Common.map_filter (fun n ->
    try 
      let file = GC.file_of_node n g in
      Some file
    with Not_found -> None
  ) +> Common.hashset_of_list +> Common.hashset_to_list in
  (*pr2 (spf "%d" (List.length files));*)
  files +> List.iter pr;
  let dir = !output_dir in
  Common.command2 (spf "mkdir -p %s" dir);
  files +> List.iter (fun file ->
    let subdir = Filename.dirname file in
    Common.command2 (spf "mkdir -p %s/%s" dir subdir);
    Common.command2 (spf "cp %s %s/%s" file dir subdir);
  )


(* ---------------------------------------------------------------------- *)
let pfff_extra_actions () = [
  "-extract_transitive_deps", " <files or dirs> (works with -o)",
  Common.mk_action_n_arg extract_transitive_deps;
  "-find_big_branching_factor", " <file>",
  Common.mk_action_1_arg find_big_branching_factor;


  "-find_source", " <dirs>",
  Common.mk_action_n_arg find_source;
  "-lpize", " <files>",
  Common.mk_action_n_arg lpize;

]

(*****************************************************************************)
(* The options *)
(*****************************************************************************)

let all_actions () = 
  pfff_extra_actions() @
  []


let options () = [
  "-verbose", Arg.Set verbose, 
  " ";
  "-o", Arg.Set_string output_dir, 
  " <dir> generate codeslice in dir";
  
  "-lang", Arg.Set_string lang, 
  (spf " <str> choose language (default = %s)" !lang);
  ] @
  Flag_parsing_cpp.cmdline_flags_verbose () @
  Flag_parsing_cpp.cmdline_flags_debugging () @
  Flag_parsing_cpp.cmdline_flags_macrofile () @

  Common.options_of_actions action (all_actions()) @
  Common2.cmdline_flags_devel () @
  Common2.cmdline_flags_other () @
  [
    "-version",   Arg.Unit (fun () -> 
      pr2 (spf "codeslicer version: %s" Config_pfff.version);
      exit 0;
    ), "  guess what";
  ]


(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

let main () = 

  Gc.set {(Gc.get ()) with Gc.stack_limit = 1000 * 1024 * 1024};
  (* Common_extra.set_link(); 
     let argv = Features.Distribution.mpi_adjust_argv Sys.argv in
  *)

  let usage_msg = 
    "Usage: " ^ Common2.basename Sys.argv.(0) ^ 
      " [options] <file or dir> " ^ "\n" ^ "Options are:"
  in
  (* does side effect on many global flags *)
  let args = Common.parse_options (options()) usage_msg Sys.argv in

  (* must be done after Arg.parse, because Common.profile is set by it *)
  Common.profile_code "Main total" (fun () -> 
    
    (match args with
    
    (* --------------------------------------------------------- *)
    (* actions, useful to debug subpart *)
    (* --------------------------------------------------------- *)
    | xs when List.mem !action (Common.action_list (all_actions())) -> 
        Common.do_action !action xs (all_actions())

    | _ when not (Common.null_string !action) -> 
        failwith ("unrecognized action or wrong params: " ^ !action)

    (* --------------------------------------------------------- *)
    (* main entry *)
    (* --------------------------------------------------------- *)
    | x::xs -> 
        main_action (x::xs)
          
    (* --------------------------------------------------------- *)
    (* empty entry *)
    (* --------------------------------------------------------- *)
    | [] -> 
        Common.usage usage_msg (options()); 
        failwith "too few arguments"
    )
  )

(*****************************************************************************)
let _ =
  Common.main_boilerplate (fun () -> 
    main ();
  )

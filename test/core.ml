open Err

let pp_string = Format.pp_print_string
let print_bool value = print_endline (string_of_bool value)
let print_is_error = function Ok _ -> print_bool false | Error _ -> print_bool true

let make_config ?(actions = Action.Set.all) ?(backtrace = Config.Never) ?(max_events = 16) ?(max_frames = 16)
    ?(max_external_bytes = 16) () =
  match Config.make ~actions ~backtrace ~max_events ~max_frames ~max_external_bytes with
  | Ok config -> config
  | Error error -> failwith (Format.asprintf "%a" Config.pp_make_error (Error.kind error))

let with_config = Config.with_config
let get_error = function Error error -> error | Ok _ -> assert false
let action_name event = Format.asprintf "%a" Action.pp (Event.action event)
let action_names error = Error.events error |> Stdlib.List.map action_name |> String.concat ","

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec loop offset =
    if offset + fragment_length > text_length then false
    else if String.sub text offset fragment_length = fragment then true
    else loop (offset + 1)
  in
  fragment_length = 0 || loop 0

let remove_all handles = Stdlib.List.iter (fun handle -> ignore (Monitor.remove handle)) handles

type printer_record = { code : int; detail : string }

let pp_printer_record ppf { code; detail } = Format.fprintf ppf "record %d: %s" code detail

module Printer_shared = struct
  type error = [ `Offline of string | `Timeout of int ]

  let pp_error ppf : [< error ] -> unit = function
    | `Offline service -> Format.fprintf ppf "%s is offline" service
    | `Timeout seconds -> Format.fprintf ppf "timeout after %ds" seconds
end

module Printer_storage = struct
  type error = [ Printer_shared.error | `Missing_item of int ]

  let pp_error ppf : [< error ] -> unit = function
    | #Printer_shared.error as error -> Printer_shared.pp_error ppf error
    | `Missing_item id -> Format.fprintf ppf "storage item %d is missing" id
end

module Printer_service = struct
  type error = [ Printer_shared.error | `Storage_missing of int ]

  let pp_error ppf : [< error ] -> unit = function
    | #Printer_shared.error as error -> Printer_shared.pp_error ppf error
    | `Storage_missing id -> Format.fprintf ppf "service cannot load item %d" id

  let of_storage : Printer_storage.error -> error = function
    | #Printer_shared.error as error -> (error :> error)
    | `Missing_item id -> `Storage_missing id
end

let%expect_test "configuration presets, parsing, and portable bounds" =
  print_bool (Action.Set.mem Action.Detect (Config.actions Config.debug));
  print_bool (not (Action.Set.mem Action.Detect (Config.actions Config.default)));
  print_bool (Config.max_events Config.fast = 0);
  [%expect {|
    true
    true
    true |}];
  let parsed =
    Config.of_strings ~trace:(Some "map,filter,raise") ~backtrace:(Some "events") ~max_events:(Some "7")
      ~max_frames:(Some "8") ~max_external_bytes:(Some "9")
  in
  (match parsed with
  | Error error -> failwith (Format.asprintf "%a" Config.pp_of_strings_error (Error.kind error))
  | Ok parsed ->
      print_bool (Action.Set.mem Action.Map (Config.actions parsed));
      print_bool (not (Action.Set.mem Action.Export (Config.actions parsed)));
      print_bool (Config.backtrace parsed = Config.Events);
      Printf.printf "%d,%d,%d\n" (Config.max_events parsed) (Config.max_frames parsed)
        (Config.max_external_bytes parsed);
      [%expect {|
        true
        true
        true
        7,8,9 |}]);
  print_is_error
    (Config.of_strings ~trace:(Some "wat") ~backtrace:None ~max_events:None ~max_frames:None ~max_external_bytes:None);
  [%expect "true"];
  print_is_error
    (Config.of_strings ~trace:None ~backtrace:(Some "wat") ~max_events:None ~max_frames:None ~max_external_bytes:None);
  [%expect "true"];
  print_is_error
    (Config.of_strings ~trace:None ~backtrace:None ~max_events:(Some "-1") ~max_frames:None ~max_external_bytes:None);
  [%expect "true"];
  print_is_error
    (Config.of_strings ~trace:None ~backtrace:None ~max_events:(Some "1073741824") ~max_frames:None
       ~max_external_bytes:None);
  [%expect "true"];
  print_is_error
    (Config.make ~actions:Action.Set.empty ~backtrace:Config.Never ~max_events:(Int64.to_int 0x40000000L) ~max_frames:0
       ~max_external_bytes:0);
  [%expect "true"]

let%expect_test "configuration errors dog-food Err.t and public data types have printers" =
  let detect_only = make_config ~actions:(Action.Set.of_list [ Action.Detect ]) ~backtrace:Config.Never () in
  with_config detect_only (fun () ->
      let invalid_make : (Config.t, Config.make_error) t =
        Config.make ~actions:Action.Set.empty ~backtrace:Config.Never ~max_events:(-1) ~max_frames:0
          ~max_external_bytes:0
      in
      let make_error = Result.get_error invalid_make in
      print_bool (Error.kind make_error = `Negative_limit (`Max_events, -1));
      print_endline (action_names make_error);
      print_endline (Format.asprintf "%a" (pp Config.pp Config.pp_make_error) invalid_make);
      [%expect
        {|
        true
        detect
        Error (max_events must be non-negative (got -1)
               trace:
                 detected) |}];
      let invalid_strings : (Config.t, Config.of_strings_error) t =
        Config.of_strings ~trace:(Some "map,mystery") ~backtrace:None ~max_events:None ~max_frames:None
          ~max_external_bytes:None
      in
      let strings_error = Result.get_error invalid_strings in
      print_bool (Error.kind strings_error = `Unknown_trace_action "mystery");
      print_endline (Format.asprintf "%a" Config.pp_of_strings_error (Error.kind strings_error));
      [%expect {|
        true
        unknown trace action "mystery" |}]);
  print_endline (Format.asprintf "%a" Source.pp_pos ("printer.ml", 7, 2, 11));
  [%expect "printer.ml:7:2-11"];
  print_endline (Format.asprintf "%a" Action.pp Action.Map);
  [%expect "map"];
  print_endline (Format.asprintf "%a" Action.Set.pp (Action.Set.of_list [ Action.Detect; Action.Export ]));
  [%expect "detect, export"];
  print_endline (Format.asprintf "%a" Config.pp_backtrace Config.Events);
  [%expect "events"];
  print_endline (Format.asprintf "%a" Config.pp_limit `Max_external_bytes);
  [%expect "max_external_bytes"];
  print_endline (Format.asprintf "%a" Config.pp Config.fast);
  [%expect
    {|
    { actions = off; backtrace = off; max_events = 0; max_frames = 0;
      max_external_bytes = 16384 }
    |}];
  let callback _ = () in
  let monitor = Monitor.install callback in
  print_endline (Format.asprintf "%a,%a" Monitor.pp monitor Monitor.pp_callback callback);
  [%expect "installed,<callback>"];
  ignore (Monitor.remove monitor);
  print_endline (Format.asprintf "%a" Monitor.pp monitor);
  [%expect "removed"]

let%expect_test "success paths and ordinary propagation do not add trace data" =
  with_config Config.debug (fun () ->
      let original = get_error (fail "missing") in
      let propagated = get_error (bind (Error original) (fun _ -> assert false)) in
      let mapped = map (fun value -> value + 1) (return 1) in
      let lazy_option = map_none ~error:(fun () -> failwith "must stay lazy") (Some 1) in
      print_bool (original == propagated);
      [%expect "true"];
      print_bool (mapped = Ok 2);
      [%expect "true"];
      print_bool (lazy_option = Ok 1);
      [%expect "true"];
      print_endline (action_names propagated);
      [%expect "detect"])

let%expect_test "mapping is failure-only and retains provenance" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Map ]) () in
  with_config config (fun () ->
      let calls = ref 0 in
      let original = get_error (fail ~pos:("detect.ml", 10, 2, 12) "x") in
      let mapped =
        Error original
        |> map_error (fun value ->
            incr calls;
            value ^ "!")
        |> get_error
      in
      ignore
        (map_error
           (fun _ ->
             incr calls;
             assert false)
           (Ok 1));
      print_int !calls;
      print_newline ();
      [%expect "1"];
      print_bool (Error.origin original == Error.origin mapped);
      [%expect "true"];
      print_endline (Error.kind mapped);
      [%expect "x!"];
      print_endline (action_names mapped);
      [%expect "map"])

let%expect_test "Error.map_kind records its own typed conversion point" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Map ]) () in
  with_config config (fun () ->
      let original = Error.make "41" in
      let mapped = Error.map_kind ~pos:("convert.ml", 12, 4, 19) int_of_string original in
      print_int (Error.kind mapped);
      print_newline ();
      [%expect "41"];
      print_bool (Error.origin original == Error.origin mapped);
      [%expect "true"];
      print_endline (Format.asprintf "%a" Event.pp (Stdlib.List.hd (Error.events mapped)));
      [%expect "mapped at convert.ml:12:4-19"])

let%expect_test "pp_error stays polymorphic across unrelated and composable variant domains" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Detect; Action.Map ]) () in
  with_config config (fun () ->
      let monitor =
        Monitor.install (fun observation ->
            let action = Observation.event observation |> Event.action in
            let rendered = Format.asprintf "%a" Observation.pp observation in
            let first_line = match String.split_on_char '\n' rendered with line :: _ -> line | [] -> assert false in
            Format.printf "%a: %s@." Action.pp action first_line)
      in
      Fun.protect
        ~finally:(fun () -> ignore (Monitor.remove monitor))
        (fun () ->
          (* These two calls use the same optional [pp_error] argument with
             payload types that have no relationship at all. *)
          ignore (fail ~pp_error:Format.pp_print_int 7);
          [%expect "detect: 7"];
          ignore (fail ~pp_error:pp_printer_record { code = 9; detail = "bad input" });
          [%expect "detect: record 9: bad input"];

          (* [Printer_storage.pp_error] and [Printer_service.pp_error] have
             open polymorphic-variant inputs. Both compose the shared printer,
             while retaining their own complete domain printer. *)
          let storage = Error.make ~pp_error:Printer_storage.pp_error (`Missing_item 42 : Printer_storage.error) in
          [%expect "detect: storage item 42 is missing"];
          ignore
            (Error.map_kind ~pos:("service.ml", 8, 2, 24) ~pp_error:Printer_service.pp_error Printer_service.of_storage
               storage);
          [%expect "map: service cannot load item 42"];
          ignore (Error.make ~pp_error:Printer_storage.pp_error (`Offline "storage" : Printer_storage.error));
          [%expect "detect: storage is offline"];
          ignore (Error.make ~pp_error:Printer_service.pp_error (`Timeout 3 : Printer_service.error));
          [%expect "detect: timeout after 3s"]))

let%expect_test "a smaller event bound immediately trims all excess history" =
  let maps bound = make_config ~actions:(Action.Set.of_list [ Action.Map ]) ~max_events:bound () in
  with_config (maps 3) (fun () ->
      let error = fail "x" |> map_error Fun.id |> map_error Fun.id |> map_error Fun.id |> get_error in
      Printf.printf "%d:%d\n" (Stdlib.List.length (Error.events error)) (Error.dropped_events error);
      [%expect "3:0"];
      Config.set (maps 1);
      let error = Error error |> map_error Fun.id |> get_error in
      Printf.printf "%d:%d:%s\n"
        (Stdlib.List.length (Error.events error))
        (Error.dropped_events error) (action_names error);
      [%expect "1:3:map"];
      Config.set (maps 0);
      let error = Error error |> map_error Fun.id |> get_error in
      Printf.printf "%d:%d\n" (Stdlib.List.length (Error.events error)) (Error.dropped_events error);
      [%expect "0:5"])

let%expect_test "guard and protect record only selected failures" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Filter; Action.Catch ]) () in
  with_config config (fun () ->
      print_bool (guard ~error:"bad" true = Ok ());
      [%expect "true"];
      let rejected = guard ~error:"bad" false |> get_error in
      print_endline (action_names rejected);
      [%expect "filter"];
      let selected =
        protect ~catch:(function Failure message -> Some message | _ -> None) (fun () -> failwith "selected")
        |> get_error
      in
      print_endline (Error.kind selected);
      [%expect "selected"];
      print_endline (action_names selected);
      [%expect "catch"];
      print_endline
        (try
           ignore (protect ~catch:(fun _ -> None) (fun () -> invalid_arg "escape"));
           "not raised"
         with Invalid_argument message -> message);
      [%expect "escape"])

let%expect_test "protect uses the configuration captured at the catch point" =
  let never = make_config ~backtrace:Config.Never () in
  with_config never (fun () ->
      let error =
        protect ~pos:("protect.ml", 4, 1, 9)
          ~catch:(fun _ ->
            Config.set Config.debug;
            Some "caught")
          (fun () -> failwith "boom")
        |> get_error
      in
      let origin = Option.get (Error.origin error) in
      print_bool (Origin.source origin <> None);
      [%expect "true"];
      print_bool (Origin.stack origin = None);
      [%expect "true"])

let%expect_test "origin policy captures a stack when fail has no explicit source" =
  let config = make_config ~actions:Action.Set.empty ~backtrace:Config.Origin () in
  with_config config (fun () ->
      let error = fail "automatic origin" |> get_error in
      let origin = Error.origin error |> Option.get in
      print_bool (Origin.source origin = None);
      [%expect "true"];
      print_bool (Origin.stack origin <> None);
      [%expect "true"])

let%expect_test "external and unavailable stacks render bounded diagnostics" =
  let config = make_config ~max_external_bytes:5 () in
  with_config config (fun () ->
      let external_stack = Stack.of_external ~runtime:"JavaScript" ~stack:"abcdefghi" in
      print_bool (Stack.is_available external_stack);
      print_bool (Stack.to_raw_backtrace external_stack = None);
      print_endline (Format.asprintf "%a" Stack.pp external_stack);
      [%expect {|
        true
        true
        JavaScript stack:
        abcde
        [truncated] |}];
      let unavailable = Stack.of_raw_backtrace (Printexc.get_callstack 0) in
      print_bool (not (Stack.is_available unavailable));
      print_bool (Stack.to_raw_backtrace unavailable <> None);
      print_endline (Format.asprintf "%a" Stack.pp unavailable);
      [%expect {|
        true
        true
        stack unavailable |}])

let%expect_test "error and exception printers are structured and composable" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Map; Action.Export; Action.Raise ]) () in
  with_config config (fun () ->
      let error =
        fail ~pos:("detect.ml", 10, 2, 12) "bad" |> map_error ~pos:("load.ml", 20, 4, 30) Fun.id |> get_error
      in
      print_endline (Format.asprintf "%a" (Error.pp pp_string) error);
      [%expect
        {|
        bad
        detected at:
          detect.ml:10:2-12
        trace:
          mapped at load.ml:20:4-30 |}];
      let exn = to_exn ~pos:("api.ml", 30, 6, 25) ~pp_error:pp_string error in
      print_endline (Printexc.to_string exn);
      [%expect
        {|
        bad
        detected at:
          detect.ml:10:2-12
        trace:
          mapped at load.ml:20:4-30
          exported at api.ml:30:6-25 |}];
      let packed = match exn with Exn.E packed -> packed | _ -> assert false in
      print_endline (Format.asprintf "%a" Exn.pp_kind packed);
      [%expect "bad"];
      let buffer = Buffer.create 128 in
      let ppf = Format.formatter_of_buffer buffer in
      Format.pp_set_margin ppf 24;
      Format.fprintf ppf "@[<v>before@,%a@,after@]" Exn.pp packed;
      Format.pp_print_flush ppf ();
      print_endline (Buffer.contents buffer);
      [%expect
        {|
        before
        bad
        detected at:
          detect.ml:10:2-12
        trace:
          mapped at load.ml:20:4-30
          exported at api.ml:30:6-25
        after |}])

let%expect_test "exception export does not raise and raising records only Raise" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Export; Action.Raise ]) () in
  with_config config (fun () ->
      print_bool (export_exn ~pp_error:pp_string (Ok 4) = Ok 4);
      [%expect "true"];
      let exported = export_exn ~pp_error:pp_string (fail "exported") in
      (match exported with
      | Error (Exn.E packed) -> print_endline (Format.asprintf "%a" Exn.pp packed)
      | _ -> assert false);
      [%expect {|
        exported
        trace:
          exported |}];
      print_int (or_raise ~pp_error:pp_string (Ok 7));
      print_newline ();
      [%expect "7"];
      try ignore (or_raise ~pp_error:pp_string (fail "raised"))
      with Exn.E packed ->
        print_endline (Format.asprintf "%a" Exn.pp packed);
        [%expect {|
          raised
          trace:
            raised |}])

let%expect_test "monitor dispatch uses installation-order snapshots" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Map ]) () in
  with_config config (fun () ->
      let calls = ref [] in
      let second = ref None in
      let first =
        Monitor.install (fun _ ->
            calls := "first" :: !calls;
            Option.iter (fun handle -> ignore (Monitor.remove handle)) !second)
      in
      let second_handle = Monitor.install (fun _ -> calls := "second" :: !calls) in
      second := Some second_handle;
      Fun.protect
        ~finally:(fun () -> remove_all [ first; second_handle ])
        (fun () ->
          ignore (mark_error Action.Map (fail "x"));
          ignore (mark_error Action.Map (fail "x"));
          print_endline (String.concat "," (Stdlib.List.rev !calls));
          [%expect "first,second,first"]))

let%expect_test "monitor filters, zero retention, and failure containment" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Detect; Action.Map ]) ~max_events:0 () in
  with_config config (fun () ->
      let map_calls = ref 0 in
      let failures = ref 0 in
      let dropped = ref (-1) in
      let retained = ref (-1) in
      let map_monitor =
        Monitor.install ~actions:(Action.Set.of_list [ Action.Map ]) (fun _ ->
            incr map_calls;
            failwith "monitor")
      in
      let detect_monitor =
        Monitor.install ~actions:(Action.Set.of_list [ Action.Detect ])
          ~on_error:(fun _ stack ->
            assert (stack = None);
            incr failures)
          (fun observation ->
            dropped := Observation.dropped_events observation;
            retained := Stdlib.List.length (Observation.retained_events observation))
      in
      Fun.protect
        ~finally:(fun () -> remove_all [ map_monitor; detect_monitor ])
        (fun () ->
          let result = fail "x" in
          ignore (mark_error Action.Map result);
          ignore (mark_error Action.Map result);
          Printf.printf "%d,%d,%d,%d\n" !map_calls !failures !dropped !retained;
          [%expect "1,0,1,0"]))

let%expect_test "callback failure invokes its own hook and cannot replace result" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Map ]) () in
  with_config config (fun () ->
      let hook_calls = ref 0 in
      let monitor =
        Monitor.install
          ~on_error:(fun exn stack ->
            print_endline (Printexc.to_string exn);
            print_bool (stack = None);
            incr hook_calls;
            failwith "ignored hook failure")
          (fun _ -> failwith "callback failure")
      in
      Fun.protect
        ~finally:(fun () -> ignore (Monitor.remove monitor))
        (fun () ->
          let result = fail "application" |> mark_error Action.Map in
          [%expect {|
            Failure("callback failure")
            true |}];
          ignore (mark_error Action.Map result);
          print_endline (Error.kind (get_error result));
          print_int !hook_calls;
          print_newline ();
          [%expect {|
            application
            1 |}]))

let%expect_test "observations print metadata or the complete typed error" =
  let config = make_config ~actions:(Action.Set.of_list [ Action.Detect; Action.Map; Action.Raise ]) ~max_events:4 () in
  with_config config (fun () ->
      let output = ref [] in
      let monitor =
        Monitor.install (fun observation -> output := Format.asprintf "%a" Observation.pp observation :: !output)
      in
      Fun.protect
        ~finally:(fun () -> ignore (Monitor.remove monitor))
        (fun () ->
          let result =
            fail ~pos:("origin.ml", 1, 0, 5) ~pp_error:pp_string "payload"
            |> map_error ~pos:("map.ml", 2, 1, 6) Fun.id
            |> map_error ~pos:("typed-map.ml", 3, 2, 7) ~pp_error:pp_string Fun.id
          in
          (try ignore (or_raise ~pp_error:pp_string result) with Exn.E _ -> ());
          let print_properties rendered =
            print_bool (contains rendered "payload");
            print_bool (contains rendered "origin.ml");
            print_bool (contains rendered "mapped")
          in
          match Stdlib.List.rev !output with
          | [ detected; untyped_map; typed_map; raised ] ->
              print_properties detected;
              [%expect {|
                true
                true
                false |}];
              print_properties untyped_map;
              [%expect {|
                false
                true
                true |}];
              print_properties typed_map;
              [%expect {|
                true
                true
                true |}];
              print_properties raised;
              [%expect {|
                true
                true
                true |}]
          | _ -> assert false))

let%expect_test "traversals preserve order, stop at failure, and are stack safe" =
  with_config Config.fast (fun () ->
      let visited = ref [] in
      let result =
        List.map
          (fun value ->
            visited := value :: !visited;
            if value = 3 then fail "stop" else return (value * 2))
          [ 1; 2; 3; 4 ]
      in
      print_endline (String.concat "," (Stdlib.List.map string_of_int (Stdlib.List.rev !visited)));
      print_endline (Error.kind (get_error result));
      [%expect {|
        1,2,3
        stop |}];
      let values = Stdlib.List.init 100_000 Fun.id in
      let mapped = List.map (fun value -> return (value + 1)) values in
      let folded = List.fold_left (fun sum value -> return (sum + value)) 0 [ 1; 2; 3 ] in
      Printf.printf "%d,%d\n"
        (match mapped with Ok values -> Stdlib.List.length values | Error _ -> 0)
        (match folded with Ok value -> value | Error _ -> 0);
      [%expect "100000,6"])

module Printer_wide = struct
  type error = [ Printer_storage.error | `Corrupt of string ]

  let pp_error ppf : [< error ] -> unit = function
    | #Printer_storage.error as error -> Printer_storage.pp_error ppf error
    | `Corrupt detail -> Format.fprintf ppf "storage is corrupt: %s" detail
end

(* [Printer_storage] already has [type error] and [pp_error], which is the shape
   this library asks a domain to have, so it satisfies [Err.Domain] unchanged. *)
module Bound = Make (Printer_storage)

let%expect_test "a bound domain fixes the row while raw operations stay open" =
  with_config (make_config ~actions:Action.Set.all ()) (fun () ->
      (* Raw operations keep the payload row open, so a narrow failure unifies
         upward into a domain that merely contains it. *)
      let raw_open id = fail ~pos:__POS__ (`Missing_item id) in
      let widened : (int, Printer_storage.error) Err.t = raw_open 7 in
      print_endline (Format.asprintf "%a" Printer_storage.pp_error (Error.kind (get_error widened)));
      [%expect {| storage item 7 is missing |}];
      (* The bound domain produces exactly [Printer_storage.error]. It is the
         same value the raw call produces: only the printer is pre-supplied. *)
      let bound : (int, Printer_storage.error) Err.t = Bound.fail ~pos:__POS__ (`Missing_item 7) in
      let raw = fail ~pos:__POS__ ~pp_error:Printer_storage.pp_error (`Missing_item 7) in
      print_endline (Format.asprintf "%a" Bound.Error.pp (get_error bound));
      print_endline (Format.asprintf "%a" (Error.pp Printer_storage.pp_error) (get_error raw));
      print_endline (Format.asprintf "%a" Bound.Error.pp_kind (get_error bound));
      [%expect
        {|
        storage item 7 is missing
        detected at:
          test/core.ml:572:71-78
        trace:
          detected at test/core.ml:572:71-78
        storage item 7 is missing
        detected at:
          test/core.ml:573:26-33
        trace:
          detected at test/core.ml:573:26-33
        storage item 7 is missing
        |}];
      (* [Error.t] is covariant, so a bound value still widens by coercion. This
         is the escape valve for the row the functor closed. A value that must
         stay open is built by the raw operations instead: [Bound.fail] used
         where [(int, [ `Missing_item of int ]) Err.t] is expected would not
         typecheck, because it produces the whole [Printer_storage.error]. *)
      let coerced = (bound :> (int, Printer_wide.error) Err.t) in
      print_endline (Format.asprintf "%a" Printer_wide.pp_error (Error.kind (get_error coerced)));
      [%expect {| storage item 7 is missing |}];
      (* The bound domain covers the operations whose printer is mandatory. *)
      print_bool (Bound.or_raise (return 4) = 4);
      (match Bound.export_exn (Bound.fail ~pos:__POS__ (`Offline "storage")) with
      | Ok _ -> print_endline "unexpected"
      | Error exn -> print_endline (Printexc.to_string exn));
      [%expect
        {|
        true
        storage is offline
        detected at:
          test/core.ml:601:47-54
        trace:
          detected at test/core.ml:601:47-54
          exported
        |}])

let%expect_test "accumulation reports every failure with its own origin" =
  with_config (make_config ~actions:Action.Set.all ()) (fun () ->
      let visited = ref [] in
      let check value =
        visited := value :: !visited;
        if value mod 2 = 0 then fail ~pos:__POS__ (`Even value) else return (value * 10)
      in
      let result = Accum.map ~pos:__POS__ check [ 1; 2; 3; 4 ] in
      (* Every element runs, unlike Err.List.map which stops at the first error. *)
      print_endline (String.concat "," (Stdlib.List.map string_of_int (Stdlib.List.rev !visited)));
      let pp_even ppf = function `Even value -> Format.fprintf ppf "%d is even" value in
      print_endline (Format.asprintf "%a" (Accum.pp_errors pp_even) (Error.kind (get_error result)));
      [%expect
        {|
        1,2,3,4
        2 is even
        detected at:
          test/core.ml:620:42-49
        trace:
          detected at test/core.ml:620:42-49
        4 is even
        detected at:
          test/core.ml:620:42-49
        trace:
          detected at test/core.ml:620:42-49
        |}];
      (* Each failure keeps its own origin, so a report can point at each one. *)
      let origins =
        Error.kind (get_error result)
        |> Stdlib.List.map (fun error ->
            match Error.origin error with
            | Some origin -> (
                match Origin.source origin with Some source -> Format.asprintf "%a" Source.pp source | None -> "-")
            | None -> "-")
      in
      print_endline (String.concat " " origins);
      [%expect {| test/core.ml:620:42-49 test/core.ml:620:42-49 |}];
      print_endline
        (match Accum.map ~pos:__POS__ check [ 1; 3 ] with
        | Ok values -> String.concat "," (Stdlib.List.map string_of_int values)
        | Error _ -> "failed");
      [%expect {| 10,30 |}];
      let count = function Ok _ -> 0 | Error error -> Stdlib.List.length (Error.kind error) in
      Printf.printf "%d,%d,%d,%d\n"
        (count (Accum.iter ~pos:__POS__ (fun value -> Err.map (fun _ -> ()) (check value)) [ 2; 4; 6 ]))
        (count (Accum.all ~pos:__POS__ [ check 1; check 2; check 4 ]))
        (count (Accum.both ~pos:__POS__ (check 2) (check 4)))
        (count (Accum.both ~pos:__POS__ (check 1) (check 4)));
      [%expect {| 3,2,2,1 |}];
      (* The outer wrapper is an ordinary Err.t, so it composes. *)
      let described =
        Accum.map ~pos:__POS__ check [ 2 ]
        |> map_error ~pos:__POS__ (fun errors -> `Invalid (Stdlib.List.length errors))
      in
      print_endline
        (match described with
        | Ok _ -> "ok"
        | Error error -> ( match Error.kind error with `Invalid n -> Printf.sprintf "invalid:%d" n));
      [%expect {| invalid:1 |}];
      let values = Stdlib.List.init 100_000 Fun.id in
      let mapped = Accum.map (fun value -> return (value + 1)) values in
      let failures = Accum.map (fun value -> fail (`Even value)) values in
      Printf.printf "%d,%d\n"
        (match mapped with Ok values -> Stdlib.List.length values | Error _ -> 0)
        (count failures);
      [%expect {| 100000,100000 |}])

let%expect_test "escape exits its own frame and cannot cross a nested one" =
  with_config (make_config ~actions:Action.Set.all ()) (fun () ->
      let pp_bad ppf = function `Bad value -> Format.fprintf ppf "bad %d" value in
      let show = function
        | Ok value -> Printf.sprintf "ok:%d" value
        | Error error -> Format.asprintf "%a[%s]" pp_bad (Error.kind error) (action_names error)
      in
      (* An inner frame catches its own throw and the enclosing frame keeps
         going, so the first line below is the inner failure, not the outer. *)
      let outer =
        Escape.with_escape (fun out ->
            let inner = Escape.with_escape (fun inn -> Escape.throw inn ~pos:__POS__ (`Bad 1)) in
            print_endline (show inner);
            (* A throw aimed at the outer token passes through a live inner
               frame to the frame that owns it. *)
            let _ : (int, _) result = Escape.with_escape (fun _ -> Escape.throw out ~pos:__POS__ (`Bad 2)) in
            0)
      in
      print_endline (show outer);
      [%expect {|
        bad 1[detect]
        bad 2[detect]
        |}];
      (* Only the throw records an event; with_escape records none. *)
      print_endline (action_names (get_error outer));
      [%expect {| detect |}];
      (* or_throw bridges an ordinary Err.t-returning call into the walk,
         preserving the wrapper the callee built rather than rebuilding it. *)
      let bridged = Escape.with_escape (fun token -> Escape.or_throw token (fail ~pos:__POS__ (`Bad 3)) + 1) in
      print_endline (show bridged);
      [%expect {| bad 3[detect] |}];
      (* throw_error carries an existing wrapper through unchanged. *)
      let carried = Escape.with_escape (fun token -> Escape.throw_error token (Error.make ~pos:__POS__ (`Bad 4))) in
      print_endline (show carried);
      [%expect {| bad 4[detect] |}];
      (* A foreign exception propagates unchanged. *)
      (try ignore (Escape.with_escape (fun _ -> failwith "foreign")) with Failure message -> print_endline message);
      [%expect {| foreign |}];
      (* A token that outlives its frame fails where it is misused, naming the
         throw site, rather than unwinding past every handler. *)
      let leaked = ref None in
      let _ =
        Escape.with_escape (fun token ->
            leaked := Some token;
            0)
      in
      (match !leaked with
      | None -> print_endline "unreachable"
      | Some token -> (
          print_endline (Format.asprintf "%a" Escape.pp token);
          try ignore (Escape.throw token ~pos:__POS__ (`Bad 5)) with exn -> print_endline (Printexc.to_string exn)));
      [%expect
        {|
        exited
        Err.Escape.throw called after its with_escape call returned (at test/core.ml:732:46-53)
        |}];
      (* Deep recursion is the reason this exists: no result is threaded. *)
      let deep =
        Escape.with_escape (fun token ->
            let rec walk depth = if depth = 0 then Escape.throw token ~pos:__POS__ (`Bad 6) else walk (depth - 1) in
            walk 100_000)
      in
      print_endline (show deep);
      [%expect {| bad 6[detect] |}])

let%expect_test "boundary helpers mark exactly one action" =
  with_config (make_config ~actions:Action.Set.all ()) (fun () ->
      let seen = ref [] in
      let handle =
        Monitor.install (fun observation ->
            seen := Format.asprintf "%a" Action.pp (Event.action (Observation.event observation)) :: !seen)
      in
      let observed () =
        let names = String.concat "," (Stdlib.List.rev !seen) in
        seen := [];
        names
      in
      (* payload is the unmarked unwrap; export is the marked one. *)
      let unwrapped = payload (fail ~pos:__POS__ `Boom) in
      print_endline (match unwrapped with Ok () -> "ok" | Error `Boom -> "boom:" ^ observed ());
      let exported = export ~pos:__POS__ (fail ~pos:__POS__ `Boom) in
      print_endline (match exported with Ok () -> "ok" | Error `Boom -> "boom:" ^ observed ());
      [%expect {|
        boom:detect
        boom:detect,export
        |}];
      (* import lifts a third-party result and records Import, not Detect. *)
      let imported = import ~pos:__POS__ (fun message -> `Decode message) (Stdlib.Error "bad json") in
      let error = get_error imported in
      Printf.printf "%s|%s|%s\n"
        (match Error.kind error with `Decode message -> message)
        (action_names error) (observed ());
      print_endline
        (match Error.origin error with
        | Some origin -> (
            match Origin.source origin with Some source -> Format.asprintf "%a" Source.pp source | None -> "-")
        | None -> "-");
      [%expect {|
        bad json|import|import
        test/core.ml:769:33-40
        |}];
      print_endline
        (match import ~pos:__POS__ (fun message -> `Decode message) (Stdlib.Ok 3) with
        | Ok value -> string_of_int value
        | Error _ -> "failed");
      [%expect {| 3 |}];
      remove_all [ handle ];
      (* Error.pp_kind renders the payload with no provenance, unlike Error.pp. *)
      let pp_boom ppf `Boom = Format.pp_print_string ppf "boom" in
      let error = get_error (fail ~pos:__POS__ `Boom) in
      print_endline (Format.asprintf "%a" (Error.pp_kind pp_boom) error);
      print_bool (not (contains (Format.asprintf "%a" (Error.pp_kind pp_boom) error) "detected at"));
      print_bool (contains (Format.asprintf "%a" (Error.pp pp_boom) error) "detected at");
      [%expect {|
        boom
        true
        true |}])

let%expect_test "configuration vocabulary round-trips through of_strings" =
  let reparse config =
    let trace = Format.asprintf "%a" Action.Set.pp (Config.actions config) in
    let backtrace = Format.asprintf "%a" Config.pp_backtrace (Config.backtrace config) in
    match
      Config.of_strings ~trace:(Some trace) ~backtrace:(Some backtrace)
        ~max_events:(Some (string_of_int (Config.max_events config)))
        ~max_frames:(Some (string_of_int (Config.max_frames config)))
        ~max_external_bytes:(Some (string_of_int (Config.max_external_bytes config)))
    with
    | Ok parsed -> Format.asprintf "%a" Config.pp parsed = Format.asprintf "%a" Config.pp config
    | Error error -> failwith (Format.asprintf "%a" Config.pp_of_strings_error (Error.kind error))
  in
  Stdlib.List.iter
    (fun config -> print_bool (reparse config))
    [ Config.fast; Config.deterministic; Config.default; Config.debug ];
  [%expect {|
    true
    true
    true
    true |}];
  let parse_backtrace value =
    match
      Config.of_strings ~trace:None ~backtrace:(Some value) ~max_events:None ~max_frames:None ~max_external_bytes:None
    with
    | Ok parsed -> Format.asprintf "%a" Config.pp_backtrace (Config.backtrace parsed)
    | Error error -> Format.asprintf "%a" Config.pp_of_strings_error (Error.kind error)
  in
  (* "never" names the constructor and stays accepted; "off" is what is printed. *)
  Stdlib.List.iter
    (fun value -> print_endline (parse_backtrace value))
    [ "off"; "never"; "origin"; "events"; "sometimes" ];
  [%expect
    {|
    off
    off
    origin
    events
    unknown backtrace mode "sometimes" (expected off, never, origin, or events)
    |}];
  (* Action.Set.pp separates with a break hint, so parsing must ignore spacing. *)
  let parse_trace value =
    match
      Config.of_strings ~trace:(Some value) ~backtrace:None ~max_events:None ~max_frames:None ~max_external_bytes:None
    with
    | Ok parsed -> Format.asprintf "%a" Action.Set.pp (Config.actions parsed)
    | Error error -> Format.asprintf "%a" Config.pp_of_strings_error (Error.kind error)
  in
  Stdlib.List.iter
    (fun value -> print_endline (parse_trace value))
    [ " map , filter "; "off"; " boundaries "; "map,shout" ];
  [%expect
    {|
    map, filter
    off
    map, filter, catch, raise, import, export
    unknown trace action "shout"
    |}]

let%expect_test "configuration limit parsing ignores surrounding whitespace" =
  let parsed =
    Config.of_strings ~trace:None ~backtrace:None ~max_events:(Some " 7 ") ~max_frames:(Some "\t8\n")
      ~max_external_bytes:(Some " 9")
  in
  (match parsed with
  | Ok config ->
      Printf.printf "%d,%d,%d\n" (Config.max_events config) (Config.max_frames config)
        (Config.max_external_bytes config)
  | Error error -> print_endline (Format.asprintf "%a" Config.pp_of_strings_error (Error.kind error)));
  [%expect {| 7,8,9 |}];
  (* Invalid input retains the caller's original spelling for diagnostics. *)
  let invalid =
    Config.of_strings ~trace:None ~backtrace:None ~max_events:(Some " nope ") ~max_frames:None ~max_external_bytes:None
  in
  print_endline
    (match invalid with
    | Ok _ -> "accepted"
    | Error error -> Format.asprintf "%a" Config.pp_of_strings_error (Error.kind error));
  [%expect {| max_events must be an integer (got " nope ") |}]

let%expect_test "the deterministic preset keeps the trail without capturing stacks" =
  Printf.printf "%b,%b,%d,%d,%d\n"
    (Action.Set.mem Action.Map (Config.actions Config.deterministic))
    (not (Action.Set.mem Action.Detect (Config.actions Config.deterministic)))
    (Config.max_events Config.deterministic)
    (Config.max_frames Config.deterministic)
    (Config.max_external_bytes Config.deterministic);
  print_bool (Config.backtrace Config.deterministic = Config.Never);
  [%expect {|
    true,true,32,0,16384
    true |}];
  with_config Config.deterministic (fun () ->
      let error =
        fail ~pos:__POS__ `Boom
        |> map_error ~pos:__POS__ (fun `Boom -> `Wrapped)
        |> mark_error ~pos:__POS__ Action.Export |> get_error
      in
      (* The semantic trail survives; no stack is captured anywhere in it. *)
      print_endline (action_names error);
      let stacks = Stdlib.List.filter_map Event.origin (Error.events error) |> Stdlib.List.filter_map Origin.stack in
      print_bool (stacks = []);
      print_bool (match Error.origin error with Some origin -> Origin.stack origin = None | None -> true);
      [%expect {|
        map,export
        true
        true |}]);
  (* Config.fast, by contrast, drops the whole trail. An explicit ~pos still
     records a detection origin; omitting it leaves no provenance at all. *)
  with_config Config.fast (fun () ->
      let error = fail ~pos:__POS__ `Boom |> map_error ~pos:__POS__ (fun `Boom -> `Wrapped) |> get_error in
      print_endline (if action_names error = "" then "no trail" else action_names error);
      print_bool (Error.origin error <> None);
      print_bool (Error.origin (get_error (fail `Boom)) = None);
      [%expect {|
        no trail
        true
        true |}])

let%expect_test "with_config restores the previous policy after an exception" =
  let before = Format.asprintf "%a" Config.pp (Config.get ()) in
  (try Config.with_config Config.debug (fun () -> failwith "boom") with Failure _ -> ());
  print_bool (Format.asprintf "%a" Config.pp (Config.get ()) = before);
  print_bool (Config.with_config Config.debug (fun () -> Config.max_events (Config.get ())) = 64);
  print_bool (Format.asprintf "%a" Config.pp (Config.get ()) = before);
  [%expect {|
    true
    true
    true |}]

let%expect_test "two-list and predicate traversals" =
  with_config (make_config ~actions:Action.Set.all ()) (fun () ->
      let unequal_lengths left right = `Arity (left, right) in
      let pp_arity ppf = function
        | `Arity (left, right) -> Format.fprintf ppf "expected %d arguments, got %d" left right
        | `Bad value -> Format.fprintf ppf "bad %d" value
      in
      let paired = List.map2 ~unequal_lengths (fun a b -> return (a + b)) [ 1; 2; 3 ] [ 10; 20; 30 ] in
      print_endline
        (match paired with
        | Ok values -> String.concat "," (Stdlib.List.map string_of_int values)
        | Error _ -> "failed");
      [%expect {| 11,22,33 |}];
      (* A length mismatch is a detected error in the caller's domain, which is
         what lets this subsume the length check that precedes a List.combine. *)
      let mismatch_calls = ref 0 in
      let mismatch =
        List.map2 ~pos:__POS__ ~unequal_lengths
          (fun value _ ->
            incr mismatch_calls;
            fail (`Bad value))
          [ 1; 2; 3 ] [ 10 ]
      in
      let error = get_error mismatch in
      Printf.printf "%d|%s|%s\n" !mismatch_calls (Format.asprintf "%a" pp_arity (Error.kind error)) (action_names error);
      print_endline
        (match Error.origin error with
        | Some origin -> (
            match Origin.source origin with Some source -> Format.asprintf "%a" Source.pp source | None -> "-")
        | None -> "-");
      [%expect {|
        0|expected 3 arguments, got 1|detect
        test/core.ml:946:23-30
        |}];
      let visited = ref 0 in
      let iterated =
        List.iter2 ~pos:__POS__ ~unequal_lengths
          (fun a b ->
            incr visited;
            if a = b then fail ~pos:__POS__ (`Bad a) else return ())
          [ 1; 2; 3 ] [ 9; 2; 8 ]
      in
      Printf.printf "%d|%s\n" !visited
        (match iterated with Ok () -> "ok" | Error error -> Format.asprintf "%a" pp_arity (Error.kind error));
      [%expect {| 2|bad 2 |}];
      let unequal_visits = ref 0 in
      let unequal_iter =
        List.iter2 ~unequal_lengths
          (fun _ _ ->
            incr unequal_visits;
            return ())
          [ 1; 2 ] [ 9 ]
      in
      Printf.printf "%d|%s\n" !unequal_visits
        (match unequal_iter with Ok () -> "ok" | Error error -> Format.asprintf "%a" pp_arity (Error.kind error));
      [%expect {| 0|expected 2 arguments, got 1 |}];
      let kept =
        List.filter_map (fun value -> return (if value mod 2 = 0 then Some (value * 10) else None)) [ 1; 2; 3; 4 ]
      in
      print_endline
        (match kept with Ok values -> String.concat "," (Stdlib.List.map string_of_int values) | Error _ -> "failed");
      [%expect {| 20,40 |}];
      (* exists and for_all stop as soon as the answer is settled. *)
      let checked = ref 0 in
      let count_and value =
        incr checked;
        return value
      in
      let existed = List.exists count_and [ false; true; false ] in
      let first = !checked in
      checked := 0;
      let all_held = List.for_all count_and [ true; false; true ] in
      Printf.printf "%b,%d,%b,%d\n"
        (match existed with Ok value -> value | Error _ -> false)
        first
        (match all_held with Ok value -> value | Error _ -> true)
        !checked;
      [%expect {| true,2,false,2 |}];
      let values = Stdlib.List.init 100_000 Fun.id in
      let mapped = List.map2 ~unequal_lengths (fun a b -> return (a + b)) values values in
      let filtered = List.filter_map (fun value -> return (Some value)) values in
      Printf.printf "%d,%d\n"
        (match mapped with Ok values -> Stdlib.List.length values | Error _ -> 0)
        (match filtered with Ok values -> Stdlib.List.length values | Error _ -> 0);
      [%expect {| 100000,100000 |}])

let%expect_test "a foreign exception keeps its identity and backtrace through both boundaries" =
  (* [protect] and [Escape.with_escape] re-raise what they decline to absorb.
     Preserving the original backtrace uses a primitive that is unavailable on
     some backends, so the library reattaches one only when it has resolvable
     frames. Fetching that raw backtrace is independent of the provenance
     policy: Config.Never must not move the raise site to Err.reraise. *)
  let failure_line = __LINE__ + 1 in
  let[@inline never] raise_foreign () = raise (Failure "foreign") in
  let backtrace_is_preserved_or_unresolvable () =
    match Printexc.backtrace_slots (Printexc.get_raw_backtrace ()) with
    | None -> true
    | Some slots ->
        let locations = slots |> Array.to_list |> Stdlib.List.filter_map Printexc.Slot.location in
        locations = []
        || Stdlib.List.exists
             (fun (location : Printexc.location) -> location.filename = __FILE__ && location.line_number = failure_line)
             locations
  in
  let run boundary =
    match boundary () with
    | exception Failure message -> (message, backtrace_is_preserved_or_unresolvable ())
    | exception exn -> ("wrong exception: " ^ Printexc.to_string exn, false)
    | Ok _ | Error _ -> ("absorbed", false)
  in
  let previous = Printexc.backtrace_status () in
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace previous)
    (fun () ->
      Printexc.record_backtrace true;
      Stdlib.List.iter
        (fun backtrace ->
          with_config (make_config ~backtrace ()) (fun () ->
              let escaped = run (fun () -> Escape.with_escape (fun _ -> raise_foreign ())) in
              let protected = run (fun () -> protect ~catch:(fun _ -> None) raise_foreign) in
              Printf.printf "%s,%b|%s,%b\n" (fst escaped) (snd escaped) (fst protected) (snd protected)))
        [ Config.Never; Config.Origin; Config.Events ]);
  [%expect {|
    foreign,true|foreign,true
    foreign,true|foreign,true
    foreign,true|foreign,true |}];
  (* An exception the catch function does claim still becomes a typed error. *)
  with_config (make_config ~backtrace:Config.Origin ()) (fun () ->
      let caught =
        protect ~pos:__POS__
          ~catch:(function Failure m -> Some (`Caught m) | _ -> None)
          (fun () -> failwith "claimed")
      in
      let error = get_error caught in
      Printf.printf "%s|%s\n" (match Error.kind error with `Caught message -> message) (action_names error);
      [%expect {| claimed|catch |}])

let%expect_test "Accum crosses ordinary error-domain boundaries explicitly" =
  with_config Config.fast (fun () ->
      let first_pos = ("first.ml", 10, 2, 7) in
      let second_pos = ("second.ml", 20, 3, 8) in
      let batch = Accum.all [ fail ~pos:first_pos (`Bad 1); fail ~pos:second_pos (`Bad 2) ] in
      let collapsed =
        Accum.fold_errors (fun errors -> `Many (Stdlib.List.map (fun error -> Error.kind error) errors)) batch
      in
      (match collapsed with
      | Ok _ -> print_endline "unexpected success"
      | Error error ->
          let values =
            match Error.kind error with
            | `Many errors -> Stdlib.List.map (fun (`Bad value) -> string_of_int value) errors
          in
          let source =
            match Error.origin error with
            | Some origin -> (
                match Origin.source origin with Some source -> Format.asprintf "%a" Source.pp source | None -> "-")
            | None -> "-"
          in
          Printf.printf "%s|%s\n" (String.concat "," values) source);
      [%expect {| 1,2|first.ml:10:2-7 |}];
      let lifted = Accum.lift (fail ~pos:first_pos (`Bad 3)) in
      (match lifted with
      | Ok _ -> print_endline "unexpected success"
      | Error batch ->
          let values =
            Stdlib.List.map (fun error -> match Error.kind error with `Bad value -> value) (Error.kind batch)
          in
          let source =
            match Error.origin batch with
            | Some origin -> (
                match Origin.source origin with Some source -> Format.asprintf "%a" Source.pp source | None -> "-")
            | None -> "-"
          in
          Printf.printf "%d|%s\n" (Stdlib.List.hd values) source);
      [%expect {| 3|first.ml:10:2-7 |}])

let%expect_test "Escape.map narrows a caller token and shares its lifetime" =
  with_config Config.fast (fun () ->
      let leaked = ref None in
      let escaped =
        Escape.with_escape (fun token ->
            let narrow = Escape.map (fun (`Narrow value) -> `Wide value) token in
            leaked := Some narrow;
            Escape.throw narrow ~pos:("narrow.ml", 4, 1, 6) (`Narrow 7))
      in
      (match escaped with
      | Ok _ -> print_endline "unexpected success"
      | Error error ->
          let value = match Error.kind error with `Wide value -> value in
          let source =
            match Error.origin error with
            | Some origin -> (
                match Origin.source origin with Some source -> Format.asprintf "%a" Source.pp source | None -> "-")
            | None -> "-"
          in
          Printf.printf "%d|%s\n" value source);
      [%expect {| 7|narrow.ml:4:1-6 |}];
      (match !leaked with
      | None -> print_endline "missing token"
      | Some token -> (
          try Escape.throw token (`Narrow 8)
          with Escape.Escaped_after_exit _ -> print_endline (Format.asprintf "%a" Escape.pp token)));
      [%expect {| exited |}])

let%expect_test "protect and import record events under the configuration read at entry" =
  let no_catch = make_config ~actions:(Action.Set.of_list [ Action.Detect ]) () in
  with_config no_catch (fun () ->
      let caught =
        protect
          ~catch:(fun _ ->
            Config.set Config.debug;
            Some "caught")
          (fun () -> failwith "boom")
        |> get_error
      in
      print_endline ("[" ^ action_names caught ^ "]");
      [%expect "[]"]);
  let no_import = make_config ~actions:(Action.Set.of_list [ Action.Detect ]) () in
  with_config no_import (fun () ->
      let imported =
        import
          (fun kind ->
            Config.set Config.debug;
            kind)
          (Error "bare")
        |> get_error
      in
      print_endline ("[" ^ action_names imported ^ "]");
      [%expect "[]"])

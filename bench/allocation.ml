open Err_trace

let pp_string = Format.pp_print_string

let measure ~iterations label f =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  for _ = 1 to iterations do
    f ()
  done;
  let allocated = Gc.allocated_bytes () -. before in
  Printf.printf "%-32s %10.0f bytes (%7.2f/op)\n" label allocated (allocated /. float_of_int iterations)

let config ~actions ~backtrace ~max_events =
  Config.make ~actions ~backtrace ~max_events ~max_frames:32 ~max_external_bytes:256 |> Result.get_ok

let set config f =
  Config.set config;
  f ()

let () =
  let iterations = 100_000 in
  let success config label =
    set config (fun () -> measure ~iterations label (fun () -> ignore (map (( + ) 1) (return 1 : (int, string) t))))
  in
  success Config.fast "success / fast";
  success Config.with_stacks "success / with_stacks";
  success Config.debug "success / debug";
  let never = config ~actions:Action.Set.empty ~backtrace:Config.Never ~max_events:0 in
  let origin = config ~actions:Action.Set.empty ~backtrace:Config.Origin ~max_events:0 in
  set never (fun () ->
      measure ~iterations:10_000 "failure / no backtrace" (fun () -> ignore (fail "failure" : (unit, string) t)));
  set origin (fun () ->
      measure ~iterations:10_000 "failure / origin backtrace" (fun () -> ignore (fail "failure" : (unit, string) t)));
  let map_disabled = config ~actions:Action.Set.empty ~backtrace:Config.Never ~max_events:0 in
  let map_source = config ~actions:(Action.Set.of_list [ Action.Map ]) ~backtrace:Config.Never ~max_events:8 in
  let map_stack = config ~actions:(Action.Set.of_list [ Action.Map ]) ~backtrace:Config.Events ~max_events:8 in
  let pos = ("bench.ml", 1, 0, 10) in
  let base_error = Error.make_at ~origin:None "failure" in
  let map_case config label =
    set config (fun () ->
        measure ~iterations:10_000 label (fun () -> ignore (map_error ~pos Fun.id (Error base_error))))
  in
  map_case map_disabled "map error / disabled";
  map_case map_source "map error / source";
  map_case map_stack "map error / event stack";
  set map_source (fun () ->
      let full =
        Error base_error |> map_error Fun.id |> map_error Fun.id |> map_error Fun.id |> map_error Fun.id
        |> map_error Fun.id |> map_error Fun.id |> map_error Fun.id |> map_error Fun.id
      in
      measure ~iterations:10_000 "map error / overflow" (fun () -> ignore (map_error Fun.id full)));
  set map_source (fun () ->
      measure ~iterations:10_000 "external stack truncation" (fun () ->
          ignore (Stack.of_external ~runtime:"JavaScript" ~stack:(String.make 1_024 'x'))));
  set map_source (fun () ->
      measure ~iterations:10_000 "exception pack + render" (fun () ->
          let exn = to_exn ~pp_error:pp_string base_error in
          ignore (Printexc.to_string exn)));
  let monitored = config ~actions:(Action.Set.of_list [ Action.Map ]) ~backtrace:Config.Never ~max_events:0 in
  set monitored (fun () ->
      let handles = Stdlib.List.init 3 (fun _ -> Monitor.install (fun _ -> ())) in
      Fun.protect
        ~finally:(fun () -> Stdlib.List.iter (fun handle -> ignore (Monitor.remove handle)) handles)
        (fun () ->
          measure ~iterations:10_000 "monitor only / three" (fun () -> ignore (map_error Fun.id (Error base_error)))));
  Config.set Config.with_stacks

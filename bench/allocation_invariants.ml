open Err

let measure ~iterations f =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  for _ = 1 to iterations do
    f ()
  done;
  Gc.allocated_bytes () -. before

let config ~actions ~backtrace ~max_events =
  Config.make ~actions ~backtrace ~max_events ~max_frames:32 ~max_external_bytes:256 |> Result.get_ok

let measure_under config ~iterations f =
  Config.set config;
  measure ~iterations f

let equal label values =
  match values with
  | [] | [ _ ] -> ()
  | expected :: rest ->
      if not (Stdlib.List.for_all (( = ) expected) rest) then
        failwith
          (Printf.sprintf "%s: expected equal allocations, got %s" label
             (String.concat ", " (Stdlib.List.map (Printf.sprintf "%.0f") values)))

let less label left right =
  if not (left < right) then failwith (Printf.sprintf "%s: expected %.0f < %.0f allocated bytes" label left right)

let () =
  let previous = Config.get () in
  Fun.protect
    ~finally:(fun () -> Config.set previous)
    (fun () ->
      let iterations = 10_000 in
      let success config =
        measure_under config ~iterations (fun () -> ignore (map (( + ) 1) (return 1 : (int, string) t)))
      in
      equal "successful propagation is policy-independent"
        [ success Config.fast; success Config.deterministic; success Config.default; success Config.debug ];

      let values = Stdlib.List.init 32 Fun.id in
      let accumulation config =
        measure_under config ~iterations (fun () -> ignore (Accum.iter (fun _ -> return ()) values))
      in
      equal "successful accumulation is policy-independent"
        [ accumulation Config.fast; accumulation Config.default; accumulation Config.debug ];

      let never = config ~actions:Action.Set.empty ~backtrace:Config.Never ~max_events:0 in
      let origin = config ~actions:Action.Set.empty ~backtrace:Config.Origin ~max_events:0 in
      let failure config = measure_under config ~iterations (fun () -> ignore (fail "failure" : (unit, string) t)) in
      less "origin stack capture costs more than no capture" (failure never) (failure origin);

      let base_error = Error.make_at ~origin:None "failure" in
      let disabled = config ~actions:Action.Set.empty ~backtrace:Config.Never ~max_events:0 in
      let source = config ~actions:(Action.Set.of_list [ Action.Map ]) ~backtrace:Config.Never ~max_events:8 in
      let stacks = config ~actions:(Action.Set.of_list [ Action.Map ]) ~backtrace:Config.Events ~max_events:8 in
      let pos = ("allocation_invariants.ml", 1, 0, 10) in
      let mapped config =
        measure_under config ~iterations (fun () -> ignore (map_error ~pos Fun.id (Error base_error)))
      in
      let disabled_bytes = mapped disabled in
      let source_bytes = mapped source in
      let stack_bytes = mapped stacks in
      less "a retained source event costs more than a disabled event" disabled_bytes source_bytes;
      less "an event stack costs more than a source-only event" source_bytes stack_bytes;

      let monitored = config ~actions:(Action.Set.of_list [ Action.Map ]) ~backtrace:Config.Never ~max_events:0 in
      let map_monitored () = ignore (map_error Fun.id (Error base_error)) in
      let without_monitors = measure_under monitored ~iterations map_monitored in
      let handles = Stdlib.List.init 3 (fun _ -> Monitor.install (fun _ -> ())) in
      let with_monitors =
        Fun.protect
          ~finally:(fun () -> Stdlib.List.iter (fun handle -> ignore (Monitor.remove handle)) handles)
          (fun () -> measure_under monitored ~iterations map_monitored)
      in
      less "monitor dispatch costs more than an unmatched registry" without_monitors with_monitors;
      let trail = config ~actions:(Action.Set.of_list [ Action.Map ]) ~backtrace:Config.Never ~max_events:128 in
      let with_trail length =
        Config.set trail;
        let result = ref (Error base_error) in
        for _ = 1 to length do
          result := mark_error Action.Map !result
        done;
        let result = !result in
        measure_under trail ~iterations (fun () -> ignore (map_error Fun.id result))
      in
      equal "an unmonitored event does not pay for the length of the trail"
        [ with_trail 1; with_trail 8; with_trail 100 ];
      print_endline "allocation invariants: ok")

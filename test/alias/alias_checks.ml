let pp_error ppf `Boom = Format.pp_print_string ppf "boom"

let run ~check =
  let config : Err_trace.Config.t =
    match
      Err_trace.Config.make ~actions:Err_trace.Action.Set.all ~backtrace:Err_trace.Config.Never ~max_events:8
        ~max_frames:0 ~max_external_bytes:0
    with
    | Ok config -> config
    | Error _ -> assert false
  in
  let previous = Err.Config.get () in
  Err.Config.set config;
  check "Config.t crosses to Err_trace" (Err_trace.Config.get () == config);
  check "Config.t crosses to Err" (Err.Config.get () == config);
  let via_err = ref 0 and via_err_trace = ref 0 in
  let observe counter observation = if Err.Observation.is_creation observation then incr counter in
  let monitor_err = Err.Monitor.install (observe via_err) in
  let monitor_err_trace = Err_trace.Monitor.install (observe via_err_trace) in
  let (failed : (int, [> `Boom ]) Err.t) = Err_trace.fail ~pp_error `Boom in
  check "Err monitor sees Err_trace.fail" (!via_err = 1);
  check "Err_trace monitor sees Err_trace.fail" (!via_err_trace = 1);
  let (failed_again : (int, [> `Boom ]) Err_trace.t) = Err.fail ~pp_error `Boom in
  check "Err_trace monitor sees Err.fail" (!via_err_trace = 2);
  check "Err monitor sees Err.fail" (!via_err = 2);
  (match (failed, failed_again) with
  | Error left, Error right ->
      check "Error.kind crosses" (Err.Error.kind left = `Boom && Err_trace.Error.kind right = `Boom)
  | _ -> check "failures are errors" false);
  check "Err.E is Err_trace.Exn.E"
    (match Err.or_raise ~pp_error failed with _ -> false | exception Err_trace.Exn.E _ -> true);
  check "Err_trace.E is Err.Exn.E"
    (match Err_trace.or_raise ~pp_error failed_again with _ -> false | exception Err.Exn.E _ -> true);
  check "monitor handle crosses to Err_trace" (Err_trace.Monitor.remove monitor_err);
  check "monitor handle crosses to Err" (Err.Monitor.remove monitor_err_trace);
  Err.Config.set previous

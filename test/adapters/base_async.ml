type error = [ `Jane_street of Base.Error.t ]

let has_prefix ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length && String.sub value 0 prefix_length = prefix

let pp_error ppf = function `Jane_street error -> Format.pp_print_string ppf (Base.Error.to_string_hum error)

let config =
  Err.Config.make
    ~actions:(Err.Action.Set.of_list [ Err.Action.Import; Err.Action.Export ])
    ~backtrace:Err.Config.Never ~max_events:8 ~max_frames:0 ~max_external_bytes:0
  |> Result.get_ok

let import_or_error (result : ('a, Base.Error.t) result) : ('a, error Err.Error.t) result =
  result |> Stdlib.Result.map_error (fun error -> Err.Error.make (`Jane_street error)) |> Err.mark_error `Import

let export_or_error result : int Base.Or_error.t =
  result |> Err.mark_error `Export
  |> Stdlib.Result.map_error (fun error -> Base.Error.of_string (Format.asprintf "%a" (Err.Error.pp pp_error) error))

let deferred_map f deferred = Async_kernel.Deferred.map deferred ~f

let () =
  Err.Config.set config;
  assert (import_or_error (Ok 4) = Ok 4);
  let imported = import_or_error (Base.Or_error.error_string "base failure") in
  let imported_error = Result.get_error imported in
  assert (
    match Err.Error.kind imported_error with `Jane_street error -> Base.Error.to_string_hum error = "base failure");
  assert (Err.Error.events imported_error |> List.map Err.Event.action = [ Err.Action.Import ]);
  let exported = export_or_error imported in
  assert (
    match exported with
    | Error error -> has_prefix ~prefix:"base failure" (Base.Error.to_string_hum error)
    | Ok _ -> false);
  let deferred = Async_kernel.Deferred.return imported in
  let deferred = deferred_map (Err.map Fun.id) deferred in
  Async_kernel.Async_kernel_scheduler.Expert.run_cycles_until_no_jobs_remain ();
  assert (
    match Async_kernel.Deferred.peek deferred with
    | Some (Error error) -> Err.Error.kind error = Err.Error.kind imported_error
    | _ -> false);
  let exception_result =
    Async_kernel.try_with ~extract_exn:true ~run:`Schedule (fun () ->
        deferred_map (fun _ -> raise Exit) (Async_kernel.Deferred.return ()))
  in
  Async_kernel.Async_kernel_scheduler.Expert.run_cycles_until_no_jobs_remain ();
  assert (match Async_kernel.Deferred.peek exception_result with Some (Error Exit) -> true | _ -> false)

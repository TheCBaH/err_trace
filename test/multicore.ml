open Err_trace

let await predicate =
  while not (predicate ()) do
    Domain.cpu_relax ()
  done

let config =
  match
    Config.make ~actions:(Action.Set.of_list [ Action.Detect ]) ~backtrace:Config.Never ~max_events:0 ~max_frames:0
      ~max_external_bytes:0
  with
  | Ok config -> config
  | Error _ -> assert false

let () =
  let previous_config = Config.get () in
  let worker_count = max 2 (min 8 (Domain.recommended_domain_count ())) in
  let events_per_worker = 2_000 in
  let callback_count = Atomic.make 0 in
  let callback _ = ignore (Atomic.fetch_and_add callback_count 1) in
  let start_install = Atomic.make false in
  let installers =
    Array.init worker_count (fun _ ->
        Domain.spawn (fun () ->
            await (fun () -> Atomic.get start_install);
            Monitor.install callback))
  in
  Atomic.set start_install true;
  let monitors = Array.map Domain.join installers in
  Config.set config;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun monitor -> ignore (Monitor.remove monitor)) monitors;
      Config.set previous_config)
    (fun () ->
      let start_dispatch = Atomic.make false in
      let workers =
        Array.init worker_count (fun _ ->
            Domain.spawn (fun () ->
                await (fun () -> Atomic.get start_dispatch);
                for _ = 1 to events_per_worker do
                  ignore (fail "parallel failure")
                done))
      in
      Atomic.set start_dispatch true;
      Array.iter Domain.join workers;
      let expected = worker_count * worker_count * events_per_worker in
      assert (Atomic.get callback_count = expected);
      let start_removal = Atomic.make false in
      let removers =
        Array.map
          (fun monitor ->
            Domain.spawn (fun () ->
                await (fun () -> Atomic.get start_removal);
                assert (Monitor.remove monitor);
                assert (not (Monitor.remove monitor))))
          monitors
      in
      Atomic.set start_removal true;
      Array.iter Domain.join removers;
      ignore (fail "after removal");
      assert (Atomic.get callback_count = expected))

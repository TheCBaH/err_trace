let check name condition = if not condition then failwith ("assertion failed: " ^ name)
let () = Portable_checks.run ~check

let () =
  Err_trace.Config.set (Portable_checks.config Err_trace.Action.Set.all 8);
  let imported =
    Err_trace.Error.make_at
      ~origin:(Err_trace.Origin.make ~source:(Err_trace.Source.of_pos ("adapter.ml", 4, 2, 12)) ())
      (`Expected "native")
  in
  Portable_checks.check_imported ~check imported

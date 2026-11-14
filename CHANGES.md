# Changes

## Unreleased (after 0.1.0)

### Breaking

- The policy in force at start-up is now `Config.deterministic` (boundary
  events, no automatic stacks). It used to capture an origin stack for every
  error. `Config.default` is renamed `Config.with_stacks`; there is no
  `Config.default` any more. Programs that relied on start-up stacks call
  `Err.Config.set Err.Config.with_stacks`. Absent `Config.of_strings` settings
  are read from `Config.deterministic`.
- `Config.make` and `Config.of_strings` reject `max_events` above 4096
  (`` `Limit_too_large ``).
- `Config.of_strings_error` has a new case, `` `Empty_trace_action of int ``
  (1-based position of an empty item in a comma-separated `trace` list); an
  exhaustive match must handle it.
- `Config.of_strings` limits are digits only: `0x10`, `0b11` and `1_000` are
  no longer accepted, and an overflow is `` `Limit_too_large `` on every word
  size.
- `Err.mark_error` (and `Make(D).mark_error`) takes `Action.marking`, the polymorphic
  variant `` [ `Filter | `Catch | `Import | `Export ] ``, instead of `Action.t`:
  `Detect`, `Map` and `Raise` have their own operations and could only forge a
  transition by hand. Write `` Err.mark_error `Import `` for `Err.mark_error
  Err.Action.Import`; use `map_error Fun.id` for a bare `Map` event.
  `Action.t` is documented as a closed variant.
- `Err.protect` keeps at most `max_frames` frames of a caught stack, and none
  for `max_frames = 0`. A cut stack has no raw form, so
  `Stack.to_raw_backtrace` returns `None` for it.

### Fixed

- `guard`, `import` and `protect` read the policy once, so a policy change
  during the call cannot record an event the entry policy disabled.
- An `Accum` batch wrapper no longer dispatches an extra `Detect` or captures
  a call stack of its own.
- Rendered native stacks no longer start with "Raised by primitive operation",
  no longer end in a blank line, and skip this library's own frames.
- External stacks are cut at a line break or a UTF-8 boundary.
- Config limits and `trace` lists parse as documented, including group names
  in lists (`boundaries,detect`).
- The dropped-events line reads "N trace events not retained".
- Event dispatch no longer reverses the trail or filters the registry when no
  monitor matches.

### Added

- `Accum.Syntax` (`let+`, `and+`); `Observation.is_creation`; `Monitor.install ?on_failure` and
  `Monitor.last_failure`; `Action.Set.add`, `remove`, `union`, `to_list`,
  `equal`; `Source.to_pos`; `Stack.to_external`; `Exn.origin`, `events`,
  `dropped_events`; `?pos` on `Escape.throw_error` and `or_throw`;
  `Make(D).List.map2` and `iter2`.

### Build and CI

- `err_trace.opam` asks for `ppx_expect` and `mdx` only under `with-test`.
- The js example builds only with `ERR_TRACE_TEST_JS=true`.
- `validation` runs on `main`, `devel`, `v*` tags, pull requests and weekly.

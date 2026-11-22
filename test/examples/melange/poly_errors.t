  $ node "$DUNE_SOURCEROOT/_build/default/examples/melange/poly-errors-output/examples/melange/poly_errors.js"
  [monitor] detect
  users record 42 is missing
  detected at:
    poly_errors.ml:33:29-36
  trace:
    detected at poly_errors.ml:33:29-36
  [monitor] map
  profile unavailable: users record 42 is missing
  detected at:
    poly_errors.ml:33:29-36
  trace:
    detected at poly_errors.ml:33:29-36
    mapped at poly_errors.ml:59:32-39
  [handled] provision users record 42, then retry
  [monitor] detect
  users lookup timed out after 2s
  detected at:
    poly_errors.ml:32:26-33
  trace:
    detected at poly_errors.ml:32:26-33
  [monitor] map
  users lookup timed out after 2s
  detected at:
    poly_errors.ml:32:26-33
  trace:
    detected at poly_errors.ml:32:26-33
    mapped at poly_errors.ml:59:32-39
  [handled] retry users lookup later
  [origin without ~pos] explicit-source=false automatic-stack=true

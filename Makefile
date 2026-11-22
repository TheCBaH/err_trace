DUNE ?= opam exec -- dune
OPAM ?= opam

build:
	$(DUNE) build

test-core:
	$(DUNE) runtest

test-multicore:
	$(DUNE) exec ./test/multicore.exe

test-base-async:
	$(OPAM) install --yes base async_kernel
	ERR_TRACE_TEST_BASE_ASYNC=true $(DUNE) exec ./test/adapters/base_async.bc
	ERR_TRACE_TEST_BASE_ASYNC=true $(DUNE) exec ./test/adapters/base_async.exe

test-lwt:
	$(OPAM) install --yes lwt
	ERR_TRACE_TEST_LWT=true $(DUNE) exec ./test/adapters/lwt_adapter.bc
	ERR_TRACE_TEST_LWT=true $(DUNE) exec ./test/adapters/lwt_adapter.exe

test-rresult:
	$(OPAM) install --yes rresult
	ERR_TRACE_TEST_RRESULT=true $(DUNE) exec ./test/adapters/rresult_adapter.bc
	ERR_TRACE_TEST_RRESULT=true $(DUNE) exec ./test/adapters/rresult_adapter.exe

test-cmdliner:
	$(OPAM) install --yes cmdliner
	ERR_TRACE_TEST_CMDLINER=true $(DUNE) exec ./test/adapters/cmdliner.bc
	ERR_TRACE_TEST_CMDLINER=true $(DUNE) exec ./test/adapters/cmdliner.exe

test-mirage:
	$(OPAM) install --yes mirage-flow
	ERR_TRACE_TEST_MIRAGE=true $(DUNE) exec ./test/adapters/mirage.bc
	ERR_TRACE_TEST_MIRAGE=true $(DUNE) exec ./test/adapters/mirage.exe

test-octez:
	@if $(OPAM) list --installed --short octez-libs | grep -qx octez-libs; then ERR_TRACE_TEST_OCTEZ=true $(DUNE) exec ./test/adapters/octez.bc && ERR_TRACE_TEST_OCTEZ=true $(DUNE) exec ./test/adapters/octez.exe; else echo 'Octez unavailable: capability skipped'; fi

test-fmt-logs-yojson:
	$(OPAM) install --yes fmt logs yojson
	ERR_TRACE_TEST_FMT_LOGS_YOJSON=true $(DUNE) exec ./test/adapters/fmt_logs_yojson.bc
	ERR_TRACE_TEST_FMT_LOGS_YOJSON=true $(DUNE) exec ./test/adapters/fmt_logs_yojson.exe

test-js:
	$(OPAM) install --yes js_of_ocaml-compiler js_of_ocaml-ppx
	ERR_TRACE_TEST_JS=true $(DUNE) build test/js.bc.js @test/examples/runtest
	node _build/default/test/js.bc.js

test-compiler-locations:
	$(DUNE) exec ./test/adapters/compiler_locations.bc
	$(DUNE) exec ./test/adapters/compiler_locations.exe

test-melange:
	@if $(OPAM) list --installed --short melange | grep -qx melange; then ERR_TRACE_TEST_MELANGE=true $(DUNE) build @melange-test @test/examples/melange/runtest && node _build/default/test/melange-output/test/melange_test.js; else echo 'Melange unavailable: capability skipped'; exit 2; fi

test-melange-optin:
	tools/melange-optin.sh

bench:
	$(DUNE) exec bench/allocation.exe

bench-check:
	$(DUNE) exec bench/allocation_invariants.exe

doc:
	$(DUNE) build @doc

NS_PREFIX ?= $(CURDIR)/_build/ns-install

namespace-check:
	$(DUNE) build -p err_trace @install
	$(DUNE) install --prefix $(NS_PREFIX) err_trace
	ERR_TRACE_MELANGE=true $(DUNE) build -p err_trace-melange @install
	ERR_TRACE_MELANGE=true $(DUNE) install --prefix $(NS_PREFIX) err_trace-melange
	scripts/namespace-check.sh --fail -q --prefix Err_trace \
	  --exceptions scripts/namespace.exceptions --expect-libs scripts/namespace.expect \
	  native=$(NS_PREFIX)/lib/err_trace melange=$(NS_PREFIX)/lib/err_trace-melange

fmt:
	$(DUNE) fmt

fmt-check:
	$(DUNE) build @fmt

test: test-core
ci: build test-core bench-check fmt-check

.PHONY: namespace-check build test test-core test-multicore test-base-async test-lwt test-rresult test-cmdliner test-mirage test-octez test-fmt-logs-yojson test-compiler-locations test-js test-melange test-melange-optin bench bench-check doc fmt fmt-check ci

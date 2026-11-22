# Working with the devcontainer locally

This repository's CI builds and runs containers with `@devcontainers/cli`
(`devcontainer` on `PATH`), through
`.github/workflows/actions/devcontainer/action.yml`. Reproduce a CI leg with the
same `up` and `exec` operations rather than invoking `docker build` directly.

## Select the OCaml version and container

The OCaml feature reads `${localEnv:OCAML_VERSION}` while the image is built, so
set it in the shell that runs `devcontainer up`:

```sh
export OCAML_VERSION=5.5.0
devcontainer up --workspace-folder .
```

The core versions and architectures are defined in
`.github/workflows/ocaml-versions.yml`. The current versions are 4.12.1, 4.13.1,
4.14.3, 5.2.1, 5.3.0, 5.4.1, and 5.5.0. CI covers `linux/amd64` and `linux/arm64`
for every version; only 4.14.3 additionally covers `linux/i386` and
`linux/arm/v7`. The two older compilers are kept 64-bit-only to bound the
legacy toolchain and emulation surface.

The 4.12 developer image pins `pp` to 1.2.0 and `yojson` to 2.2.2. Its
compatible `ocaml-lsp-server.1.9.0` has no upper bounds for the later breaking
`pp.2.0.0` and `yojson.3.0.0` releases. These pins repair the developer
toolchain rather than constraining the runtime library.

Feature suites use dedicated cached images. Pass the same configuration to both
`up` and `exec` when reproducing one:

```sh
export OCAML_VERSION=4.14.3
devcontainer up --workspace-folder . \
  --config .devcontainer/javascript/devcontainer.json
devcontainer exec --workspace-folder . \
  --config .devcontainer/javascript/devcontainer.json make test-js test-melange
```

Available feature configurations are `native-adapters`, `javascript`, and
`octez`. Melange is constrained to OCaml 4.14. Octez is an optional package:
the 4.14 image exercises it, while OCaml 5 legs verify that its absence is a
clean capability skip.

CI also passes `--platform <docker-platform>` while building. Use that locally
only when Docker has the required native host or binfmt emulation. Its generated
`exec` prefix exports the matching `PLATFORM` as well; current test targets do
not branch on it, but passing it reproduces the complete CI environment:

```sh
devcontainer exec --remote-env PLATFORM=linux/arm64 \
  --workspace-folder . make ci
```

## Run checks

The common core checks are:

```sh
devcontainer exec --workspace-folder . make ci
devcontainer exec --workspace-folder . make bench
```

`make bench` reports exact allocated bytes and is intended for comparison within
one pinned compiler, architecture, and build configuration. `make bench-check`
is included in `make ci` and asserts only cross-version relational invariants,
such as stack capture allocating more than no capture and successful propagation
being independent of tracing policy.

`make build` builds Dune's default alias, including the bytecode, native, and
js_of_ocaml forms of the cross-runtime example. The core image therefore
preinstalls `js_of_ocaml-compiler` and `js_of_ocaml-ppx`; JavaScript execution
and Melange remain focused checks in the JavaScript feature image.

The core image does not install `odoc`; the documentation workflow does. To
check API documentation in the core container, first run
`devcontainer exec --workspace-folder . opam install --yes odoc`, then
`devcontainer exec --workspace-folder . make doc`.

Focused feature checks are `test-base-async`, `test-lwt`, `test-rresult`,
`test-cmdliner`, `test-mirage`, `test-fmt-logs-yojson`,
`test-compiler-locations`, `test-js`, `test-melange`, and `test-octez`. The
dedicated feature images already contain their dependencies; the corresponding
Makefile installs are therefore normally cached no-ops.

`make test-multicore` is a native-only OCaml 5 check. The validation workflow
runs it as a separate step in the existing OCaml 5 core jobs; its Dune stanza is
disabled for OCaml 4 so the `Domain`-using module is not compiled there.

`devcontainer up` is idempotent and reuses a container keyed by its workspace
and configuration. The generated `.devcontainer/devcontainer-lock.json` files
are feature-resolution artifacts and should not be edited manually.

## Nested devcontainer mount caveat

When this repository is itself opened in the
`.devcontainer/devcontainers.cli/devcontainer.json` environment, the Docker
daemon may run outside that CLI container. In that arrangement the daemon
resolves bind-mount source paths in the host namespace. `devcontainer exec` can
therefore report `/workspaces/err_trace` while the inner validation container
sees an empty or stale directory at that path.

Check before trusting a validation run:

```sh
devcontainer exec --workspace-folder . bash -lc \
  'test -f src/err_trace.ml && command -v opam && opam exec -- dune --version'
```

### When `up` itself fails

With an empty mount, `devcontainer up` does not merely produce a container with
no sources: it fails, because `postCreateCommand` runs a script that lives in
the workspace.

```json
{"outcome":"error","message":"Command failed: /bin/sh -c sudo .devcontainer/fix-opam-owner.sh $(id -u) $(id -g)","description":"opam of postCreateCommand from devcontainer.json failed.","containerId":"a3e60f1cb101..."}
```

The container named by `containerId` was created and is usable; only the
post-create step failed. Because `up` never completed, `devcontainer exec`
cannot drive it, so use `docker exec` and finish the setup by hand. Do what
`fix-opam-owner.sh` would have done — the image bakes `OPAMROOT` ownership as
uid 1000, while `updateRemoteUserUID` remaps the container's `vscode` user to
the host uid:

```sh
CONTAINER=<containerId from the up failure>
docker exec -u root "$CONTAINER" chown -R vscode:vscode /opt/opam
```

`docker exec` does not inherit the devcontainer environment — the container's
`Config.Env` carries only `PATH` — so pass `OPAMROOT` on every call:

```sh
docker exec -u vscode -e OPAMROOT=/opt/opam "$CONTAINER" \
  sh -lc 'opam exec -- dune --version'
```

### Validate a disposable snapshot

If the source is not mounted, validate a copy instead. Create a temporary
directory inside the target container, stream the working tree into it
(excluding local build and archive artifacts), and run checks there:

```sh
ERR_TRACE_SNAPSHOT_PATH=$(devcontainer exec --workspace-folder . \
  mktemp -d /tmp/err_trace-review.XXXXXX | tail -n 1)
tar --exclude=.git --exclude=_build --exclude='*.tar.gz' -cf - . \
  | devcontainer exec --workspace-folder . \
      tar -xf - -C "$ERR_TRACE_SNAPSHOT_PATH"
devcontainer exec --remote-env ERR_TRACE_SNAPSHOT_PATH="$ERR_TRACE_SNAPSHOT_PATH" \
  --workspace-folder . bash -lc 'cd "$ERR_TRACE_SNAPSHOT_PATH" && make ci'
```

When `up` failed as above, the same recipe works with `docker exec`, reading the
tree from its real path in this container rather than from `.`:

```sh
SNAP=$(docker exec -u vscode "$CONTAINER" mktemp -d /tmp/err_trace-review.XXXXXX | tr -d '\r')
tar --exclude=.git --exclude=_build --exclude='*.tar.gz' \
  -cf - -C /workspaces/err_trace . \
  | docker exec -i -u vscode "$CONTAINER" tar -xf - -C "$SNAP"
docker exec -u vscode -e OPAMROOT=/opt/opam "$CONTAINER" \
  sh -lc "cd $SNAP && make ci"
```

Use a newly created path for each independent snapshot so stale files cannot
mask deletions. This is only a validation copy; make source edits in the shared
workspace.

## Container lifecycle

Prefer rerunning `devcontainer up` over deleting a container. If a genuinely
clean rebuild is necessary, first identify the exact container with
`docker ps`, then remove only that container explicitly.

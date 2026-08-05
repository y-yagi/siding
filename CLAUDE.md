# Siding — working notes

A Rails application preloader whose design point is a single guarantee: **it never serves stale
code**. Everything below exists to keep that true. When a change would trade the guarantee for
speed, convenience, or a configuration option, the change is wrong — that is Principle I, and it is
not negotiable.

This file is binding, not advisory. Code comments cite the principles and invariants below by
number, and those citations resolve to this file. Every guarantee stated here must have a test that
fails when it stops being true; adding or moving a guarantee means adding or moving that test.

## Principles

### I. Correctness Over Speed (NON-NEGOTIABLE)

Siding exists to make development faster, not faster than it is correct. Where the two conflict,
correctness wins — every time, without a configuration option to decide otherwise.

- MUST NOT execute a command against application state that predates the developer's most recent
  saved edit.
- MUST NOT offer a setting, flag, or environment variable that trades staleness for speed. A knob
  that disables a correctness check will be found, enabled, and then blamed on us.
- Correctness mechanisms MUST be structural, not procedural. A guarantee that depends on a
  developer maintaining a list, or a reviewer remembering to check, is not a guarantee. Prefer
  designs where the incorrect state is unrepresentable.
- When correctness forces a slow path, the system MUST say so within a bounded time. Silent
  slowness is indistinguishable from a hang.
- Optimizations that reduce the cost of a correct path are welcome. Optimizations that skip a
  correctness check are rejected regardless of measured benefit.

**Rationale**: the established tools in this space are fast but not trustworthy, so developers
preemptively disable them. A preloader that serves stale code has negative value — it costs more
debugging time than it saves in boot time, and trust is not recovered by a benchmark.

### II. Executable Guarantees

Any claim the project makes about its own behavior MUST be enforced by an automated test in CI. A
guarantee that is not executed is a hope.

- Every MUST-level requirement, and every absolute success criterion ("zero stale results", "no
  orphaned processes", "byte-identical output"), MUST map to a test that fails if it breaks.
- Absolute claims MUST be tested against the real thing. Where fidelity to a real environment is
  the property under test, mocks are not acceptable evidence.
- Failure and degraded paths MUST be tested, not merely implemented — that code otherwise runs
  unobserved on other people's machines.
- A skipped, quarantined, or pending test is a guarantee that no longer holds. Fix it, or withdraw
  the claim from the documentation.

### III. Code Quality

Code MUST be written to be read by the next person to debug it under time pressure. This is systems
code involving processes, signals, and file descriptors, where bugs are intermittent and expensive
to reproduce.

- New code MUST match the surrounding conventions — naming, structure, comment density, idiom.
  Consistency outranks personal preference.
- Public API MUST be minimal and explicitly declared. Anything not documented as public is private
  and may change freely.
- Every configuration option MUST justify itself against the cost of another code path to keep
  correct. Absence of an option is the default.
- Dependencies MUST be justified; prefer the standard library. A dependency added here is imposed
  on every project that installs the tool (see Invariant 9).
- Comments MUST explain why, not what. Code needing a comment to explain what it does should be
  rewritten.
- Error messages MUST identify what failed, what the system did about it, and what the user can do
  next. An error the user cannot act on is a bug in the error.

### IV. User Experience Consistency

The tool MUST behave the same way every time, and the way the tools it wraps already behave.
Surprise is the failure mode. A tool sitting between a developer and their command inherits blame
for everything downstream; the only defense is being ruled out quickly, and being trivially
removable when it cannot be.

- Accelerated execution MUST be observationally indistinguishable from unaccelerated execution,
  except faster (Invariant 5).
- Logger MUST NOT reach stdout, stderr, or any stream the user redirected; they go to the
  controlling terminal, visually distinct from application output (Invariant 4). With no
  controlling terminal there is no developer to inform and the notice is dropped, but it MUST
  remain recoverable from `siding status`.
- MUST NOT require a ritual. Any reachable state MUST recover automatically on the next
  invocation — no manual cleanup, restart, or stop command.
- MUST be disableable for a single invocation and for a whole session, without editing files
  committed to the repository.
- MUST be able to explain its own behavior on request: whether acceleration was used, against what
  state, and why or why not.
- When the tool cannot do its job, the user's command MUST still run (Invariant 6).

Naming stderr as the logger destination reads as the obvious answer and is wrong: stderr
belongs to the command, not to the tool. Once a developer redirects it, "write to stderr" and "never
pollute redirected output" cannot both hold, and the only way to obey both is silence — which
Principle I prohibits. The controlling terminal is the one channel that belongs to the developer
rather than to their command.

## Constraints

**Platform**: Linux and macOS. WSL is supported and treated as Linux. Windows is not supported, and
this MUST be stated explicitly rather than manifest as degraded behavior.

**Runtime dependencies**: code on the latency-critical path MUST NOT load Bundler or the application
framework. What may be declared is governed by Principle III and Invariant 9.

**Isolation**: runtime state MUST be per-user and user-owned. Never shared across users, project
checkouts, tool versions, or language runtime versions.

**Compatibility**: the supported Ruby floor is declared in the gemspec and MUST NOT be raised in a
patch release. EOL Ruby and framework versions are out of scope.

## Invariants

Break one of these and the tool becomes the thing it was written to replace. They are the
codebase-specific shape of the principles above; where an invariant looks arbitrary, the principle
it serves is the reason.

1. **Validation precedes fork.** Every invocation revalidates the manifest before a worker exists.
   Filesystem watching (`Restarter`) is an optimization on the *rebuild*, never on the *decision*.
2. **No knob turns validation off.** No flag, no environment variable, no config file.
   `test/unit/platform_test.rb` scans `lib/**/*.rb` for per-project config file reads and fails.
3. **The watch set is derived, never declared.** `LoadManifest` is the `$LOADED_FEATURES` delta
   across boot, plus autoload/eager-load roots, `config/initializers`, `Gemfile.lock`, the resolved
   gem set, and boot-component environment. `Siding.boot_component` is a residue escape hatch — if
   ordinary application code needs it, the derivation has a bug.
4. **The tool never writes to stdout or stderr.** Everything goes to `/dev/tty` via `Logger`.
   `SIDING_LOG` changes verbosity, never destination. Application boot errors are the exception,
   because an unaccelerated run would put them on stderr too.
5. **An accelerated run is observationally identical to an unaccelerated one.** Same bytes on each
   stream in the same order, same exit status including death by signal, same tty behaviour.
6. **The tool is never the reason a command fails.** Unsupported platform, unusable runtime
   directory, a boot that will not finish, a protocol version mismatch — each degrades to running
   the command unaccelerated.
7. **Runtime state is per-user and owner-only.** `XDG_RUNTIME_DIR` or `~/.local/state/siding`, mode
   `0700`, never a shared temp directory. A warm application reachable by another user is the same
   class of failure as stale code. Every file under there is a hint: confirm a pid is live before
   using it, and recover from any leftover combination without asking a developer to clean up.
8. **No orphaned processes.** `ProcessHelpers#assert_no_surviving_processes` runs in the teardown of
   *every* integration test, not just the ones about life cycle.
9. **`watchcat` is the one runtime gem dependency; standard library otherwise.** `siding.gemspec`
   depends on it directly, so `bundle install` resolves it the moment `gem "siding"` is added — no
   separate step, no silent gap. It backs *both* `SIDING_WATCH` backends (`events`, native OS
   notification; `poll`, watchcat's `force_polling`), so `Restarter`'s wake source is watchcat or
   nothing — never a home-grown poll loop that behaves differently depending on what happened to be
   installed, which is what made `SIDING_WATCH=poll` and "watchcat isn't installed" the same code
   path before the dependency was declared. Reimplementing cross-platform file watching in the
   standard library is a worse trade than depending on the one gem written for this project's own
   fork-safety needs (see `restarter.rb`'s `around_fork`). Every other dependency remains
   disallowed.

## Layout

| File | Role |
|---|---|
| `exe/siding` | Entry point. Requires exactly one file — the client's load time is a floor on the speedup |
| `lib/siding.rb` | The public API surface, and *not* what the client loads |
| `lib/siding/client.rb` | The process the developer runs. Loads no gems, no Bundler, no application. `DEFAULT_BOOT_TIMEOUT = 90.0` (`SIDING_TIMEOUT`), `NOTICE_AFTER = 0.75` |
| `lib/siding/cli.rb` | Argument handling, management commands, the `doctor` / `status` reports |
| `lib/siding/server.rb` | The long-lived booted application. `setsid` first: no controlling terminal, own process group. Validates, forks, hands off — never relays I/O |
| `lib/siding/worker.rb` | One invocation in a fork. Takes the developer's descriptors, env, cwd, signals; leaves the server's process group. Cannot be constructed without a verdict |
| `lib/siding/load_manifest.rb` | What the boot actually loaded. The central design decision |
| `lib/siding/staleness.rb` | `fresh` / `reloadable` / `reboot`, with reasons and trigger paths |
| `lib/siding/restarter.rb` | Speculative reboot while idle. Allowed to be wrong; can only cost speed. Wakes on filesystem events or a poll backoff (`Watch`, `SIDING_WATCH`) — the wake source, never what a boot is validated against |
| `lib/siding/watch.rb` | Backend selection and the watchcat life cycle for `Restarter`'s wake source only — no staleness logic. `SIDING_WATCH=poll` drives watchcat with `force_polling: true`. watchcat is a declared dependency (Invariant 9), so its *absence* is not a case to handle; a watcher that cannot *start* — an environment problem — degrades to `Restarter`'s own interval backoff, because Principle I only asks watchcat to cost speed, never correctness |
| `lib/siding/runtime.rb` | The on-disk layout and its permissions |
| `lib/siding/project_key.rb` | app_root + uid + tool version + ruby version + app env. Every field names a way a warm application could serve a command it has no business serving |
| `lib/siding/protocol.rb` | Wire protocol. `VERSION = 1`, versioned independently of the gem |
| `lib/siding/logger.rb` | The `/dev/tty` rule, in code |
| `lib/siding/life cycle.rb` | `before_fork` / `after_fork`. The only configuration hook in the project |
| `lib/siding/platform.rb` | Support detection. Deliberately has **no** Rails version check — resolution already makes a below-floor install unreachable |
| `lib/siding/invocation.rb` | Reads the `SIDING_RESOLUTION` / `_REVISION` / `_BOOT_SECONDS` env keys back out, so introspection is truthful unaccelerated too |
| `lib/siding/boot_component.rb` | The `Siding.boot_component` registry (Invariant 3) |

`reloadable` vs `reboot` is decided from the booted application's own configuration — a file under
an autoload path *when reloading is actually enabled* is repaired by Rails' reloader in the worker.
Directory layout alone does not decide it.

## Tests

```bash
bundle exec rake test              # unit + integration; green on every commit
bundle exec rake test:unit         # in-process only; fastest loop
bundle exec rake test:integration  # drives exe/siding as a subprocess
bundle exec rake test:pty          # interactive fidelity; needs a real pty

SIDING_SOAK=1 bundle exec ruby -Ilib -Itest test/integration/soak_test.rb      # opt-in, ~2 min
bundle exec ruby -Ilib -Itest test/unit/staleness_events_test.rb -n /pattern/  # one file or test
```

The suites split by *character*, not by mirrored source path: `test/unit/`, `test/integration/`,
`test/pty/`.

Things that will bite you:

- **The fixture application is a prerequisite, not a fixture file.** `test/fixtures/rails_app` has
  its own Gemfile and sqlite databases, neither in version control. `rake fixture:prepare` is a
  prerequisite of the test tasks and is cheap when there is nothing to do. Skipping it fails
  quietly: with no bundle, accelerated and unaccelerated runs fail the same way, and every
  output-identity comparison passes by comparing two identical failures.
- **Integration tests run the real executable** through `TestSupport#siding_invoke` /
  `#unaccelerated_invoke`. Byte-identity, exit status, and process cleanup are properties of a
  process and cannot fail in a way an in-process call would notice.
- **`siding_env` nils out** `SIDING_DISABLE`, `SIDING_LOG`, and the bundler variables.
- **Anything asserting on the tool's own output needs a pty.** `include TerminalTests`, then
  `open_siding_terminal` + `expect_on(session, pattern, timeout:)` + `session.screen`. A piped
  `siding doctor` or `siding status` produces nothing by contract; the exit status is the part a
  script reads, and that is checked through the pipe.
- **Tests inspect the runtime directory directly** (`siding_state_dir`, `siding_server_info`,
  `warm_application?`, `siding_server_pid`) rather than asking the tool, because "is something
  warm?" has to be answerable when the tool is what is under suspicion.
- **A timing bound is proved by squeezing the bound, not by slowing the subject** — see the
  boot-timeout test in `test/integration/degradation_test.rb`, which sets `SIDING_TIMEOUT=0.05`
  rather than waiting 90 seconds, then waits for the abandoned boot to finish publishing so it does
  not leak into the next test.
- **`SIDING_WATCH` gets both modes run for real.** `test/unit/restarter_test.rb` parameterizes the
  decision tests over `events` and `poll`; `test/integration/restarter_test.rb` does the same end to
  end. `bundle exec rake test:integration` alone only proves the default; add
  `SIDING_WATCH=poll bundle exec rake test:integration` for the poll backend. The fixture lists
  `watchcat` directly in its own Gemfile because it never adds `gem "siding"` itself
  (`test/test_helper.rb` invokes `exe/siding` by absolute path, outside Bundler, so siding's gemspec
  dependencies never reach the fixture's lockfile).

There is no performance suite. Wall-clock budgets and the benchmarks enforcing them were removed;
what remains are the correctness properties, which is why `test/integration/` asserts on *where*
code ran rather than how long it took. A change made for speed is currently unmeasured — if that
becomes a problem, the honest fix is to bring the benchmarks back, not to reason about it.

## Environment surface

`SIDING_DISABLE`, `SIDING_TIMEOUT`, `SIDING_IDLE_TIMEOUT`, `SIDING_LOG`, `SIDING_SERVER`,
`SIDING_RESOLUTION`, `SIDING_REVISION`, `SIDING_BOOT_SECONDS`, `SIDING_WATCH`. That list is asserted
by an allowlist scan in `test/unit/config_test.rb` — adding a variable without adding it there fails
the build, which is the point.

## Before merge

1. All tests pass, with none skipped or quarantined to achieve it.
2. Every new MUST-level requirement has an automated test (Principle II).
3. Public API changes are documented, including what is deliberately not public. Public API is the
   life cycle hooks, `boot_component`, and introspection — what `lib/siding.rb` exposes and documents
   as public. Everything else under `Siding::` may change.
4. Any new configuration option carries a written justification (Principle III).
5. Comments name the principle or invariant that forced the shape, at the density already in the
   surrounding file — it is high, deliberately.

Repository artifacts — code, comments, README, commit messages — are written in English.

A deviation from a principle MUST name the simpler alternative and why it was insufficient, in the
commit that introduces it. Amending a principle to weaken or remove it MUST document what problem it
was preventing and why that problem no longer applies; rewording that does not change what is
permitted needs no justification.

# Siding

An alternative Rals application preloader that focuses to never serves state code.

Siding's design point is that guarantee. It derives the set of files it watches from what the boot
actually loaded, rather than from a maintained list, and it revalidates before every invocation. So
"you never run against stale code" is structural rather than best-effort, and when it cannot
accelerate, your command still runs — unaccelerated, never refused.

## Design

**The watch set is the whole argument.** A hand-maintained list is incomplete by construction: it is
maintained by a person while the boot process is free to load anything. All files are loaded at boot,
none is watched, and all of them persist across invocations after you change them. You then debug
behavior that does not match the source in front of you. Deriving the set from what boot *actually loaded*
makes it complete instead, because the program is observing itself rather than trusting a list.

**Checking on every invocation is what makes it a guarantee.** Filesystem events are missable sometimes.
So a watcher can only ever be best-effort, so Siding uses one solely to get a head start on the rebuild,
never to decide whether the application is current. That decision is made by revalidating before the fork,
on the path that cannot be skipped. Siding uses filesystem events by default, but you can switch it
by `SIDING_WATCH`. If you want to use polling, please specify `poll`.

## Supported versions and platforms

| | Supported | Below the line |
|---|---|---|
| Platform | Linux, macOS (WSL counts as Linux) | Commands run unaccelerated |
| Commands | `rails`, `rake`, `rspec`, `test` | Commands run unaccelerated |

`test` is Rails' own `bin/test` (minitest); invoke it as `siding test ...`. `siding init` does not
generate a `bin/test` binstub, since `bin/rails test` already covers the same entry point — prefix
`test` explicitly when you use it directly.

`rails server` (and its alias `rails s`) are accelerated. But, two rails subcommands
stay below the line: `rails server -d`/`--daemon` (daemonizing detaches from the process siding
manages, which would leave nothing for it to signal or clean up) and `rails dev:cache` (a
one-shot toggle of the running application's caching mode, not something to accelerate). Below the
line means passed through unaccelerated, never refused.

`siding status` and `siding doctor` describe the warm *application* process siding manages — not the
Rails web server you get from `rails server`. Once `rails server` is itself accelerated, it's easy
to conflate the two: "server" in siding's own output always means the former.

## Installation

Add it to the `development` and `test` groups of your application's `Gemfile`:

```ruby
group :development, :test do
  gem "siding"
end
```

Then:

```bash
bundle install
```

That's enough to use it — prefix any command with `siding`, as shown below. Optionally, run
`bundle exec siding init` to generate `bin/rails`, `bin/rake`, and `bin/rspec` binstub shims, so
that the plain, unprefixed commands you already run are accelerated automatically. It reports
exactly which files it wrote.

`init` exists purely to remove the friction of remembering the `siding` prefix. Each shim it writes
is a one-line `exec("siding", ...)` wrapper — nothing else depends on it, deleting the file reverts
to the plain, unaccelerated command, and an existing `bin/rails` you've edited by hand is never
overwritten. `siding <command>` behaves identically whether or not you've ever run `init`.

## Usage

Prefix any command you would normally run:

```bash
siding rspec test/models/user_test.rb
siding rails runner 'puts User.count'
siding rails db:migrate
```

The accelerated run is observationally indistinguishable from the unaccelerated one: same stdout and
stderr, byte for byte and in the same order; same exit status, including death by signal; the same
interactive behavior, including debuggers and a real tty.

Siding's own logger never appear on stdout or stderr. They go to your controlling terminal, so
a redirected or piped stream contains exactly what your command wrote and nothing else.

### Other commands

| Command | What it does |
|---------|--------------|
| `siding start` | Boots a warm application without running a command. Idempotent, and never a prerequisite — the first accelerated command boots the same thing |
| `siding status` | Whether a warm application exists, when it booted, what it has served, and recent staleness events |
| `siding stop` | Stops everything belonging to this project. Idempotent |
| `siding restart` | `stop` followed by a fresh boot |
| `siding doctor` | Why a given invocation was or was not accelerated: platform support, runtime directory state, recent boot failures |
| `siding init` | Generates binstub shims |

### Environment variables

| Variable | Effect |
|----------|--------|
| `SIDING_DISABLE` | Truthy value runs the invocation unaccelerated. Works per-command and per-shell |
| `SIDING_TIMEOUT` | Maximum wait for a boot before surfacing the situation rather than hanging |
| `SIDING_IDLE_TIMEOUT` | Idle period after which the warm application exits (default 15 minutes) |
| `SIDING_LOG` | Raises diagnostic verbosity. Changes how much is said, never where |
| `SIDING_WATCH` | `events` (default) or `poll`. Chooses how watchcat wakes a speculative reboot while idle, never what it is validated against |

Siding is active in `development` and `test`, and stays inactive in production-like environments.
The gate is an allowlist: an unrecognized environment name defaults to inactive.

There is no option that turns staleness validation off. That is the guarantee the tool is for, and a
tool that can be put into an unsafe state on purpose will be found in one by accident.

## Ruby API

A correctly-behaving application needs none of this. It exists for the cases automatic derivation
cannot reach on its own, and for tooling that wants to know what state a run happened against.

**Fork life cycle hooks.** Forking leaves a child with dead background threads and sockets shared
with its parent. A gem that holds either releases it before the fork and re-establishes it after:

```ruby
Siding.before_fork { MyConnectionPool.disconnect! }
Siding.after_fork  { MyConnectionPool.reconnect! }
```

**Boot-relevance declaration.** Siding derives what it watches from what your boot actually loaded,
so ordinary code needs no declaration. Use this only for what that cannot see — a data file read at
boot, a generated artifact:

```ruby
Siding.boot_component "config/feature_flags.yml"
```

If you find yourself needing this for ordinary application code, the derivation has a gap. That is a
bug worth reporting, not a line worth adding.

**Introspection.** Truthful in an unaccelerated run too, so no guard is needed:

```ruby
Siding.accelerated?   # => true / false
Siding.resolution     # => "fresh", "reloaded_in_worker", "rebuild", or nil
Siding.revision       # => a label for the source state this run served
Siding.boot_seconds   # => how long the warm application took to boot
Siding.invocation     # => all of the above, as a Hash
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then:

```bash
bundle exec rake test          # unit + integration; expected green on every commit
bundle exec rake test:pty      # interactive fidelity, needs a real pty
```

The integration suite drives the real executable against the fixture application in
`test/fixtures/rails_app/`. Its bundle and databases are a prerequisite of those tasks and are
prepared automatically on a fresh clone, so there is nothing to install by hand.

Before changing behavior, read `CLAUDE.md` — its principles and invariants are binding, not
advisory.

To install the gem onto your local machine, run `bundle exec rake install`. To release a new
version, update the version number in `version.rb`, then run `bundle exec rake release`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/y-yagi/siding. This
project is intended to be a safe, welcoming space for collaboration, and contributors are expected
to adhere to the [code of conduct](https://github.com/y-yagi/siding/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Siding project's codebases, issue trackers, chat rooms and mailing lists
is expected to follow the [code of conduct](https://github.com/y-yagi/siding/blob/main/CODE_OF_CONDUCT.md).

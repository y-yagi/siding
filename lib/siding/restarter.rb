# frozen_string_literal: true

require_relative "staleness"
require_relative "watch"

module Siding
  class Restarter
    MIN_INTERVAL = 3.0
    MAX_INTERVAL = 60.0
    IDLE_FRACTION = 0.1
    SETTLE = 1.0
    HANDOVER_INTERVAL = 0.5

    QUIET = :quiet
    SETTLING = :settling
    BOOT = :boot
    SUPERSEDED = :superseded

    attr_reader :manifest, :project_key, :runtime, :logger

    def initialize(manifest:, project_key:, runtime:, logger:, env: ENV, clock: nil, busy: nil, superseded: nil, on_superseded: nil, spawner: nil)
      @manifest = manifest
      @project_key = project_key
      @runtime = runtime
      @logger = logger
      @env = env
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @busy = busy || -> { false }
      @superseded = superseded || -> { false }
      @on_superseded = on_superseded
      @spawner = spawner
      @gate = Mutex.new
      @signal = Thread::Queue.new
      @running = false
      @last_activity = @clock.call
    end

    def start
      return self if @thread

      @watch = start_watch

      @running = true
      @thread = Thread.new { poll_loop }
      @thread.name = "siding-restarter" if @thread.respond_to?(:name=)
      self
    end

    def stop
      thread = @thread
      @running = false
      @thread = nil
      @watch&.stop
      return self if thread.nil?

      @signal << :stop
      thread.join(1) || thread.kill
      self
    end

    def watch_mode
      @watch ? @watch.mode_label : "poll"
    end

    def busy!
      @last_activity = @clock.call
    end
    alias idle! busy!

    def idle_seconds(now = @clock.call)
      now - @last_activity
    end

    def interval_for(idle)
      [[idle * IDLE_FRACTION, MIN_INTERVAL].max, MAX_INTERVAL].min
    end

    def quiesce
      @gate.synchronize { yield }
    end

    def around_fork
      quiesce do
        @watch&.stop
        yield
      ensure
        @watch = start_watch if @running
      end
    end

    def poll(now: @clock.call)
      decision = tick(now: now)
      act(decision)
      decision
    end

    def tick(now: @clock.call)
      return SUPERSEDED if @superseded.call
      return QUIET if @busy.call

      verdict = Staleness.validate(manifest, env: @env)
      return settled(QUIET) if verdict.fresh?

      settle(verdict.revision_label, now)
    end

    def replacement_pid
      pid = @replacement_pid
      return nil if pid.nil?
      return pid if alive?(pid)

      @replacement_pid = nil
    end

    private

    def start_watch
      Watch.start(manifest: manifest, env: @env, logger: logger) do
        @signal << :changed if @signal.empty?
      end
    end

    def poll_loop
      while @running
        wait(wait_interval)
        break unless @running

        @last_decision = quiesce { poll }
      end
    rescue StandardError => e
      logger.debug("restarter stopped: #{e.class}: #{e.message}")
    end

    def wait(seconds)
      @signal.pop(timeout: seconds)
    end

    def wait_interval
      return SETTLE if @last_decision == SETTLING
      return HANDOVER_INTERVAL if replacement_pid
      return MAX_INTERVAL if @watch&.watching?

      interval_for(idle_seconds)
    end

    def act(decision)
      case decision
      when BOOT then spawn_replacement
      when SUPERSEDED then withdraw
      end
    end

    def settle(label, now)
      if label != @pending_label
        @pending_label = label
        @pending_since = now
        return SETTLING
      end

      return SETTLING if now - @pending_since < SETTLE
      return QUIET if label == @attempted_label

      @attempted_label = label
      BOOT
    end

    def settled(decision)
      @pending_label = nil
      @pending_since = nil
      decision
    end

    def spawn_replacement
      require_relative "server"

      @replacement_pid = spawner.call
      reaper = Process.detach(@replacement_pid) if @replacement_pid
      # A reaper that finds the pid was never ours has nothing to report to anyone's terminal.
      reaper&.report_on_exception = false
      logger.debug("restarter booting #{@pending_label} as #{@replacement_pid}")
      @replacement_pid
    rescue StandardError => e
      logger.debug("restarter could not boot a replacement: #{e.message}")
      @replacement_pid = nil
    end

    def spawner
      @spawner || -> { Server.spawn(project_key: project_key, runtime: runtime, env: @env) }
    end

    def withdraw
      @running = false
      @on_superseded&.call
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue SystemCallError
      true
    end
  end
end

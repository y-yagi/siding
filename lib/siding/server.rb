# frozen_string_literal: true

require "json"
require "socket"
require "fileutils"
require "rbconfig"

require_relative "error"
require_relative "version"
require_relative "project_key"
require_relative "runtime"
require_relative "logger"
require_relative "protocol"
require_relative "life_cycle"
require_relative "load_manifest"
require_relative "staleness"
require_relative "restarter"
require_relative "worker"

module Siding
  class Server
    BOOTSTRAP = <<~RUBY
      begin
        Process.setsid
      rescue SystemCallError
        begin
          Process.setpgrp
        rescue SystemCallError
          nil
        end
      end
      require ARGV.shift
      Siding::Server.start(app_root: ARGV.shift, digest: ARGV.shift)
    RUBY

    class << self
      def spawn(project_key:, runtime:, env:)
        log = File.open(runtime.boot_log_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600)
        begin
          Process.spawn(
            spawn_env(project_key, env),
            RbConfig.ruby, "-e", BOOTSTRAP, "--",
            __FILE__, project_key.app_root, project_key.digest,
            chdir: project_key.app_root,
            in: File::NULL, out: log, err: log
          )
        ensure
          log.close
        end
      end

      def spawn_env(project_key, env)
        vars = { "SIDING_SERVER" => "1" }
        gemfile = File.join(project_key.app_root, "Gemfile")
        vars["BUNDLE_GEMFILE"] = gemfile if File.file?(gemfile)
        vars["RAILS_ENV"] = project_key.app_env
        vars["RACK_ENV"] = project_key.app_env
        vars
      end

      def start(app_root:, digest:)
        key = ProjectKey.for(app_root)
        if key.digest != digest
          warn("siding: project key mismatch (client #{digest}, server #{key.digest})")
          exit 1
        end

        new(project_key: key, runtime: Runtime.for(key)).run
      end
    end

    DRAIN_INTERVAL = 0.05
    SELECT_INTERVAL = 1.0
    DEFAULT_IDLE_TIMEOUT = 900.0

    attr_reader :project_key, :runtime, :logger, :manifest, :events, :restarter

    def initialize(project_key:, runtime:, logger: nil, env: ENV)
      @project_key = project_key
      @runtime = runtime
      @logger = logger || Logger.new(log_path: runtime.log_path)
      @env = env
      @events = Staleness::Events.new(path: runtime.events_path)
      @workers = {}
      @workers_mutex = Mutex.new
      @shutting_down = false
      @withdrawn = false
      @served = 0
      @idle_timeout = self.class.idle_timeout_from(env)
      touch
    end

    def self.idle_timeout_from(env)
      timeout = env["SIDING_IDLE_TIMEOUT"].to_f
      timeout.positive? ? timeout : DEFAULT_IDLE_TIMEOUT
    end

    def run
      boot_application
      listen
      publish
      install_signal_handlers
      start_restarter
      accept_loop
    ensure
      drain_workers
      shutdown
    end

    def start_restarter
      @restarter = Restarter.new(manifest: manifest, project_key: project_key, runtime: runtime,
                                 logger: logger,
                                 busy: -> { busy? },
                                 superseded: -> { !published_by_us? },
                                 on_superseded: -> { retire })
      @restarter.start
    end

    def busy?
      @shutting_down || @workers_mutex.synchronize { !@workers.empty? }
    end

    def retire
      logger.debug("standing down; a replacement has taken over #{project_key.label}")
      @shutting_down = true
      wake
    end

    private

    def boot_application
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @manifest = LoadManifest.around_boot(app_root: project_key.app_root) do
        require "bundler/setup" if File.file?(File.join(project_key.app_root, "Gemfile"))
        require File.join(project_key.app_root, "config", "environment")
      end
      @boot_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      @booted_at = Time.now.to_f
      touch
      logger.debug("booted #{manifest.revision_label} in #{(@boot_seconds * 1000).round}ms, watching #{manifest.file_entries.size} files")
    end

    def listen
      staging = "#{runtime.socket_path}.#{Process.pid}"
      File.unlink(staging) if File.exist?(staging)
      @server_socket = UNIXServer.new(staging)
      File.chmod(0o600, staging)
      File.rename(staging, runtime.socket_path)
    end

    def publish
      payload = {
        "pid" => Process.pid,
        "protocol_version" => Protocol::VERSION,
        "tool_version" => Siding::VERSION,
        "app_root" => project_key.app_root,
        "app_env" => project_key.app_env,
        "booted_at" => @booted_at,
        "boot_seconds" => @boot_seconds&.round(3),
        "revision_label" => manifest.revision_label
      }
      staging = "#{runtime.server_info_path}.#{Process.pid}"
      File.write(staging, JSON.generate(payload))
      File.chmod(0o600, staging)
      File.rename(staging, runtime.server_info_path)
    end

    def install_signal_handlers
      @wake_read, @wake_write = IO.pipe
      LifeCycle::SERVER_SIGNALS.each do |signal|
        previous = trap(signal) do
          @forced = true if @shutting_down
          @shutting_down = true
          wake
        end
        LifeCycle.remember_signal_handler(signal, previous)
      end
    end

    def wake
      @wake_write.write_nonblock(".")
    rescue StandardError
      nil
    end

    def accept_loop
      until @shutting_down
        ready = IO.select([@server_socket, @wake_read], nil, nil, SELECT_INTERVAL)
        if ready.nil?
          expire_if_idle
          next
        end
        break if ready[0].include?(@wake_read)

        connection = accept
        next if connection.nil?

        handle(connection)
      end
    end

    def expire_if_idle
      return if busy?
      return if idle_seconds < idle_timeout

      logger.debug("idle for #{idle_seconds.round}s; leaving")
      @shutting_down = true
      unpublish
      close_quietly(@server_socket)
    end

    def idle_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_activity
    def idle_timeout = @idle_timeout

    def touch
      @last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @last_activity_at = Time.now
    end

    def accept
      @server_socket.accept_nonblock
    rescue IO::WaitReadable, Errno::EINTR
      nil
    end

    def handle(connection)
      return connection.close unless Protocol.server_handshake(connection)

      message = Protocol.read_message(connection)
      return connection.close if message.nil?

      case message.type
      when Protocol::RUN then dispatch(connection, message)
      when Protocol::STATUS then respond_status(connection)
      when Protocol::STOP then stop(connection)
      else connection.close
      end
    rescue Protocol::ProtocolError => e
      # A malformed or truncated request loses its own connection and nothing else. The server has
      # other clients, and one of them crashing mid-request is not a reason to drop the warm
      # application they are all sharing.
      logger.debug("dropping connection: #{e.message}")
      close_quietly(connection)
    end

    def dispatch(connection, message)
      restarter&.busy!
      touch
      @served += 1
      verdict = Staleness.validate(manifest, env: invocation_env(message))
      return supersede(connection, verdict) if verdict.reboot?

      serve(connection, message, verdict)
    end

    def invocation_env(message)
      env = message["env"]
      env.is_a?(Hash) ? env : ENV
    end

    def serve(connection, message, verdict)
      events.record(verdict)

      pid = quiesced do
        LifeCycle.prepare_for_fork

        fork do
          @server_socket.close
          @wake_read.close
          @wake_write.close
          Worker.new(connection: connection, message: message, project_key: project_key, manifest: manifest, verdict: verdict, boot_seconds: @boot_seconds).run
        end
      end

      Protocol.write_message(connection, Protocol::STARTED, pid: pid)
      reap(pid, connection)
    rescue LifeCycle::HookError => e
      Protocol.write_message(connection, Protocol::BOOT_FAILED, output: "#{e.message}\n")
      close_quietly(connection)
    end

    def supersede(connection, verdict)
      logger.debug("superseded: #{verdict.summary} (#{verdict.reasons.join(', ')})")
      events.record(verdict, resolution: "rebuild")
      @shutting_down = true
      unpublish

      Protocol.write_message(connection, Protocol::BOOTING,
                             reason: verdict.summary,
                             restart: true,
                             replacement_pid: restarter&.replacement_pid,
                             estimated_seconds: estimated_boot_seconds)
      close_quietly(connection)
    end

    def quiesced(&block)
      return yield if restarter.nil?

      restarter.around_fork(&block)
    end

    def estimated_boot_seconds = @boot_seconds&.round(1)

    def reap(pid, connection)
      @workers_mutex.synchronize { @workers[pid] = connection }

      Thread.new do
        _, status = Process.waitpid2(pid)
        Protocol.write_message(connection, Protocol::FINISHED,
                               exit_code: status.exitstatus || 0, signal: status.termsig)
      rescue StandardError => e
        logger.debug("lost track of worker #{pid}: #{e.message}")
      ensure
        @workers_mutex.synchronize { @workers.delete(pid) }
        # The idle clock starts when the last worker finishes, not when it started: a two-hour test
        # run is not two hours of idleness.
        touch
        restarter&.idle!
        close_quietly(connection)
      end
    end

    def respond_status(connection)
      touch
      Protocol.write_message(connection, Protocol::STATUS_REPORT,
                             pid: Process.pid,
                             workers: @workers_mutex.synchronize { @workers.keys },
                             tool_version: Siding::VERSION,
                             revision_label: manifest&.revision_label,
                             booted_at: @booted_at,
                             boot_seconds: @boot_seconds&.round(3),
                             served: @served,
                             last_activity_at: @last_activity_at.to_f,
                             idle_timeout: idle_timeout,
                             watch: restarter&.watch_mode,
                             events: notable_events)
      close_quietly(connection)
    end

    def notable_events
      events.to_a.reject { |event| event.resolution == "fresh" }.last(10).map(&:to_h)
    end

    def stop(connection)
      @shutting_down = true
      unpublish
      terminate_workers
      Protocol.write_message(connection, Protocol::FINISHED, exit_code: 0, signal: nil)
      close_quietly(connection)
    end

    def terminate_workers
      @workers_mutex.synchronize { @workers.keys }.each do |pid|
        Process.kill("TERM", -pid)
      rescue SystemCallError
        nil
      end
    end

    # The `draining` state, which is where every departure passes through. Workers outlive
    # the accept loop.
    #
    # They are separate processes holding the developer's terminal, and the thread waiting for each
    # one is the only place its exit status can be observed (see `reap`). Exiting underneath them
    # would turn every command still running into one that reports a failure it did not have.
    #
    # A second TERM or INT gives up on this: someone asking twice wants the process gone now, and
    # by then they know what it is costing them.
    def drain_workers
      sleep(DRAIN_INTERVAL) until @forced || @workers_mutex.synchronize { @workers.empty? }
    rescue StandardError
      nil
    end

    def shutdown
      restarter&.stop
      @server_socket&.close
      unpublish
      logger.close
    end

    def unpublish
      return if @withdrawn

      @withdrawn = true
      return unless published_by_us?

      [runtime.socket_path, runtime.server_info_path].each do |path|
        File.unlink(path)
      rescue SystemCallError
        nil
      end
    end

    def published_by_us?
      pid = JSON.parse(File.read(runtime.server_info_path))["pid"]
      pid.nil? || pid == Process.pid
    rescue StandardError
      true
    end

    def close_quietly(io)
      io.close unless io.nil? || io.closed?
    rescue IOError
      nil
    end
  end
end

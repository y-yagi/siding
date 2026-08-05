# frozen_string_literal: true

require_relative "error"
require_relative "version"
require_relative "platform"
require_relative "project_key"
require_relative "runtime"
require_relative "logger"
require_relative "protocol"
require_relative "cli"

module Siding
  class Client
    ACTIVE_ENVIRONMENTS = %w[development test].freeze
    DISABLE_OFF_VALUES = ["0", "false", "no", "off", ""].freeze
    DEFAULT_BOOT_TIMEOUT = 90.0
    NOTICE_AFTER = 0.75
    FORWARDED_SIGNALS = %w[INT TERM QUIT TSTP WINCH].freeze
    SUSPEND = "TSTP"
    SIGNAL_LINES = FORWARDED_SIGNALS.to_h { |name| [name, "#{name}\n".freeze] }.freeze
    RESTART = :restart
    MAX_HANDOVERS = 3

    attr_reader :argv, :env, :cwd, :logger

    def initialize(argv, env: ENV, cwd: Dir.pwd)
      @argv = argv.dup
      @env = env
      @cwd = cwd
      @logger = Logger.new(env: env)
    end

    def run
      return CLI.new(argv, self).run if CLI.management?(argv.first) || argv.empty?

      reason = decline_reason
      if reason
        logger.debug("running unaccelerated: #{reason}")
        return passthrough
      end

      accelerated_run
    rescue Protocol::VersionMismatch => e
      logger.debug(e.message)
      replace_mismatched_server
    rescue StandardError => e
      logger.debug("running unaccelerated after #{e.class}: #{e.message}")
      passthrough
    ensure
      logger.close
    end

    def app_root
      return @app_root if defined?(@app_root)

      @app_root = self.class.discover_app_root(cwd)
    end

    def self.discover_app_root(start)
      dir = File.expand_path(start)
      loop do
        return dir if File.file?(File.join(dir, "config", "application.rb"))

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    def project_key
      @project_key ||= app_root && ProjectKey.for(app_root, env: env)
    end

    def runtime
      @runtime ||= project_key && Runtime.for(project_key, env: env)
    end

    def app_env = ProjectKey.app_env_from(env)

    def warm_up
      reason = unusable_reason
      if reason
        logger.debug("not warming up: #{reason}")
        return false
      end

      runtime.prepare
      # The connection attempt under the boot lock is the only authoritative answer to "was one
      # already warm?", so the distinction is carried out from there rather than reconstructed by
      # the caller from a record that can go stale between the two reads. `restart` reads the
      # result as a truth value; `start` reports which of the two happened.
      outcome, socket = with_boot_lock do
        connected = try_connect
        next [:already_warm, connected] if connected

        runtime.discard_socket
        [:booted, boot_server]
      end
      return false if socket.nil?

      socket.close
      outcome
    rescue StandardError => e
      logger.debug("could not warm up: #{e.class}: #{e.message}")
      false
    end

    def decline_reason
      return "#{argv.first} is not in the accelerated set" unless CLI.accelerated?(argv)

      unusable_reason
    end

    def unusable_reason
      return "SIDING_DISABLE is set" if disabled?
      return Platform.unsupported_reason unless Platform.supported?
      return "no Rails application found above #{cwd}" if app_root.nil?
      return "#{app_env.inspect} is not an accelerated environment" unless ACTIVE_ENVIRONMENTS.include?(app_env)

      runtime.unavailable_reason
    end

    private

    def disabled?
      value = env["SIDING_DISABLE"]
      return false if value.nil?

      !DISABLE_OFF_VALUES.include?(value.strip.downcase)
    end

    def passthrough
      command = passthrough_command
      logger.close
      exec(*command)
    rescue SystemCallError => e
      warn("siding: #{command.first}: #{e.message}")
      127
    end

    def passthrough_command
      return argv if app_root.nil? || !File.file?(File.join(app_root, "Gemfile"))
      return argv if argv.first == "bundle"

      ["bundle", "exec", *argv]
    end

    def accelerated_run
      runtime.prepare

      (MAX_HANDOVERS + 1).times do |attempt|
        socket = connect_or_boot
        return passthrough if socket.nil?

        result = hand_over(socket, restarted: attempt.positive?)
        return result unless result == RESTART
      end

      logger.debug("the warm application kept being replaced; running unaccelerated")

      passthrough
    end

    def hand_over(socket, restarted: false)
      return RESTART unless greet(socket)

      Protocol.write_message(socket, Protocol::RUN,
                             argv: argv, env: env.to_h, cwd: cwd, pid: Process.pid,
                             restarted: restarted)
      Protocol.send_streams(socket)
      forwarding_signals(socket) { await_result(socket) }
    ensure
      socket.close unless socket.closed?
    end

    def forwarding_signals(socket)
      @signal_read, @signal_write = IO.pipe
      @displaced_traps = install_forwarding_traps
      @forwarder = Thread.new { forward_signals(socket) }
      yield
    ensure
      stop_forwarding
    end

    def install_forwarding_traps
      FORWARDED_SIGNALS.to_h { |name| [name, install_forwarding_trap(name)] }
    end

    def install_forwarding_trap(name)
      line = SIGNAL_LINES[name]
      Signal.trap(name) do
        @signal_write.write_nonblock(line)
      rescue StandardError
        # The command finished, or the pipe is full because five thousand resize events arrived
        # while the forwarder was busy. Either way the next signal is not worth a crash.
        nil
      end
    rescue ArgumentError, SystemCallError
      nil
    end

    def forward_signals(socket)
      while (line = @signal_read.gets)
        name = line.chomp
        Protocol.write_message(socket, Protocol::SIGNAL, name: name)
        suspend if name == SUSPEND
      end
    rescue StandardError => e
      # The socket is gone, which means the command is over. Nothing to forward to and nothing to
      # report: the result the developer is waiting for is already on its way through the main thread.
      logger.debug("stopped forwarding signals: #{e.class}")
    end

    def suspend
      Signal.trap(SUSPEND, "SYSTEM_DEFAULT")
      Process.kill(SUSPEND, Process.pid)
      # Resumed here, by `fg` or `bg`.
      install_forwarding_trap(SUSPEND)
      continue_worker
    end

    def continue_worker
      pid = @worker_pid
      return if pid.nil?

      Process.kill("CONT", -pid)
    rescue SystemCallError
      # The command finished while we were stopped. Its group is gone, and continuing it is moot.
      nil
    end

    def stop_forwarding
      @displaced_traps&.each do |name, previous|
        Signal.trap(name, previous.nil? ? "DEFAULT" : previous)
      rescue ArgumentError, SystemCallError
        nil
      end
      @displaced_traps = nil

      @signal_write&.close unless @signal_write&.closed?
      @forwarder&.join(1)
      @signal_read&.close unless @signal_read&.closed?
      @signal_write = @signal_read = @forwarder = nil
    end

    def greet(socket)
      Protocol.client_handshake(socket)
      true
    rescue Protocol::TruncatedMessage, SystemCallError => e
      logger.debug("the warm application went away before it answered: #{e.class}")
      false
    end

    def connect_or_boot
      socket = try_connect
      return socket if socket

      socket = await_replacement
      return socket if socket

      with_boot_lock do
        socket = try_connect
        next socket if socket

        runtime.discard_socket
        boot_server
      end
    end

    def await_replacement
      pid = @replacement_pid
      @replacement_pid = nil
      return nil if pid.nil?

      logger.debug("waiting for the replacement already booting (#{pid})")
      await_socket(pid)
    end

    def try_connect
      require "socket"
      UNIXSocket.new(runtime.socket_path)
    rescue SystemCallError
      # ENOENT (never booted), ECONNREFUSED (socket file outlived its server). Neither is an
      # error: both mean "boot one".
      nil
    end

    def with_boot_lock
      File.open(runtime.lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def boot_server
      require_relative "server"

      logger.debug("booting a warm application for #{project_key.label}")
      pid = Server.spawn(project_key: project_key, runtime: runtime, env: env)
      await_socket(pid)
    end

    def await_socket(server_pid)
      started_at = now
      deadline = started_at + boot_timeout
      notified = false

      loop do
        socket = try_connect
        return socket if socket

        if server_died?(server_pid)
          report_boot_failure
          return nil
        end

        return nil if now >= deadline

        notified = announce_wait(started_at) unless notified
        sleep 0.02
      end
    end

    def announce_wait(started_at)
      return false if now < started_at + NOTICE_AFTER

      logger.notice("booting #{File.basename(app_root)} (#{app_env})")
      true
    end

    def server_died?(pid)
      return true if pid.nil?

      !Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      # Not our child: a replacement started by the server that turned us away. We cannot reap it and
      # have no status to read, so liveness is both all we can ask and all we need.
      !alive?(pid)
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue SystemCallError
      true
    end

    # An application that cannot boot is not reported by this tool at all. It is left to the
    # unaccelerated run that follows.
    #
    # Writing the boot log to stderr here was the obvious thing, and it was wrong: this invocation
    # then runs the command unaccelerated, that run fails to boot for the same reason, and the
    # developer reads the same traceback twice -- once from a process they never asked about. Saying
    # nothing leaves stderr byte-identical to an unaccelerated run even in the failure case, which is
    # a stronger form of "does not swallow, reformat or truncate" than reproducing it would be.
    #
    # The log stays on disk, where `doctor` can point at it. It is the only account of the *server's*
    # boot, which matters in the case this method exists for and no other: a boot that fails only
    # under the preloader, where the unaccelerated run then succeeds and says nothing at all.
    def report_boot_failure
      logger.debug("the application did not boot; its output is in #{runtime.boot_log_path}")
    end

    def await_result(socket)
      loop do
        message = Protocol.read_message(socket)
        # The server went away without a verdict. Nothing ran, or nothing we can account for, so
        # the honest answer is a failure the developer can see rather than a fabricated zero.
        return 1 if message.nil?

        case message.type
        when Protocol::BOOTING
          logger.notice(booting_notice(message))
          # The warm application is gone rather than slow: it found itself stale and withdrew, and
          # what happens next is a fresh boot -- ours, or one the departing server had already
          # started for us while the machine was idle (`await_replacement`).
          if message["restart"]
            @replacement_pid = message["replacement_pid"]
            return RESTART
          end
        when Protocol::BOOT_FAILED
          logger.notice(message["output"].to_s.chomp)
          return 1
        when Protocol::STARTED
          @worker_pid = message["pid"]
        when Protocol::FINISHED
          return reproduce(message)
        end
      end
    end

    def booting_notice(message)
      notice = +"waiting for the application: #{message['reason']}"
      seconds = message["estimated_seconds"]
      notice << " (about #{seconds}s)" if seconds
      notice
    end

    def reproduce(message)
      signal = message["signal"]
      return message["exit_code"].to_i if signal.nil?

      die_of(signal.to_i)
    end

    def die_of(number)
      name = Signal.signame(number)
      return 128 + number if name.nil?

      logger.close
      Signal.trap(name, "SYSTEM_DEFAULT")
      Process.kill(name, Process.pid)
      # Reached only for a signal this process cannot die of -- one the platform ignores by default.
      # The conventional encoding is then the best available answer, and it is at least non-zero.
      sleep 0.05
      128 + number
    rescue ArgumentError, SystemCallError
      128 + number
    end

    def replace_mismatched_server
      CLI.new(["stop"], self).run
      accelerated_run
    rescue StandardError => e
      logger.debug("running unaccelerated after failed replacement: #{e.message}")
      passthrough
    end

    def boot_timeout
      value = env["SIDING_TIMEOUT"]
      timeout = value.to_f
      timeout.positive? ? timeout : DEFAULT_BOOT_TIMEOUT
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

# frozen_string_literal: true

require_relative "error"
require_relative "protocol"
require_relative "life_cycle"
require_relative "staleness"
require_relative "invocation"

module Siding
  class Worker
    PRESERVED_KEYS = %w[
      SIDING_SERVER
    ].freeze

    RESOLUTION_KEY = Invocation::RESOLUTION_KEY
    REVISION_KEY = Invocation::REVISION_KEY
    BOOT_SECONDS_KEY = Invocation::BOOT_SECONDS_KEY

    # A backtrace line belongs to the tool itself, not the application, if it is either a frame
    # inside this file's own directory or the `-e:` frame `Server::BOOTSTRAP` runs as (server.rb
    # spawns the server with `ruby -e`, so that frame has no path of its own to match). Shared
    # between the uncaught-exception path and the rspec path so the two cannot drift apart.
    HARNESS_FRAME_PATTERN = /\A(?:#{Regexp.escape(__dir__)}\/|-e:)/

    attr_reader :connection, :message, :project_key, :manifest, :verdict, :revision_label, :boot_seconds

    def initialize(connection:, message:, project_key:, manifest:, verdict:, boot_seconds: nil)
      @connection = connection
      @message = message
      @project_key = project_key
      @manifest = manifest
      @verdict = verdict
      @revision_label = verdict.revision_label
      @boot_seconds = boot_seconds
    end

    def run
      detach_from_server
      streams = Protocol.receive_streams(connection)
      install_streams(streams)
      apply_environment
      apply_working_directory
      LifeCycle.repair_after_fork
      refresh_application
      announce_state
      watch_the_client
      execute
    rescue Protocol::TruncatedMessage
      exit! 1
    rescue SystemExit => e
      exit e.status
    rescue SignalException => e
      report_uncaught(e)
      die_of(e)
    rescue Exception => e
      report_uncaught(e)
      exit! 1
    end

    private

    def detach_from_server
      Process.setpgrp
    rescue SystemCallError
      nil
    end

    def install_streams(streams)
      $stdin.reopen(streams[:stdin])
      $stdout.reopen(streams[:stdout])
      $stderr.reopen(streams[:stderr])

      $stdout.sync = true
      $stderr.sync = true

      close_inherited_console
    end

    def close_inherited_console
      IO.console(:close) if IO.respond_to?(:console)
    rescue StandardError
      nil
    end

    def apply_environment
      incoming = message["env"]
      return unless incoming.is_a?(Hash)

      preserved = PRESERVED_KEYS.to_h { |key| [key, ENV.fetch(key, nil)] }
      ENV.replace(incoming)
      preserved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    def apply_working_directory
      cwd = message["cwd"]
      Dir.chdir(cwd) if cwd && File.directory?(cwd)
    end

    def refresh_application
      return unless verdict.reloadable?

      reloader = application_reloader
      return if reloader.nil?

      reloader.reload!
      @revision_label = Staleness.validate(manifest).revision_label
    end

    def application_reloader
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:application)

      application = ::Rails.application
      return nil unless application.respond_to?(:reloader)

      reloader = application.reloader
      reloader.respond_to?(:reload!) ? reloader : nil
    end

    def announce_state
      ENV[RESOLUTION_KEY] = resolution
      ENV[REVISION_KEY] = revision_label
      ENV[BOOT_SECONDS_KEY] = format("%.3f", boot_seconds) if boot_seconds
    end

    def resolution
      message["restarted"] ? "rebuild" : verdict.resolution
    end

    def watch_the_client
      Thread.new do
        loop do
          message = Protocol.read_message(connection)
          break if message.nil?

          relay(message["name"]) if message.type == Protocol::SIGNAL
        end
      rescue StandardError
        nil
      ensure
        terminate_process_group
      end
    end

    def relay(name)
      return if name.nil?

      Process.kill(name, 0)
    rescue ArgumentError, SystemCallError
      nil
    end

    def terminate_process_group
      Process.kill("TERM", 0)
    rescue StandardError
      nil
    end

    def die_of(error)
      number = error.signo
      exit!(1) if number.nil?

      Signal.trap(number, "SYSTEM_DEFAULT")
      Process.kill(number, Process.pid)
      sleep 0.05
      exit! 128 + number
    rescue ArgumentError, SystemCallError, NoMethodError
      exit! 1
    end

    def execute
      argv = Array(message["argv"])
      executable = argv.first
      args = argv[1..] || []

      $PROGRAM_NAME = executable

      case executable
      when "rails" then run_rails(args)
      when "rake" then run_rake(args)
      when "rspec" then run_rspec(args)
      when "test" then run_rails(["test", *args])
      else
        raise Error, "no in-process runner for #{executable.inspect}"
      end

      exit 0
    end

    def run_rails(args)
      require "rails/command"

      aliases = {
        "g"  => "generate",
        "d"  => "destroy",
        "c"  => "console",
        "s"  => "server",
        "db" => "dbconsole",
        "r"  => "runner",
        "t"  => "test"
      }

      ARGV.replace(args)

      command = args.shift
      command = aliases[command] || command
      define_app_path if command == "server"

      ::Rails::Command.invoke(command, args)
    end

    def define_app_path
      return if defined?(::APP_PATH)

      Object.const_set(:APP_PATH, File.join(File.realpath(project_key.app_root), "config", "application"))
    end

    def run_rake(args)
      require "rake"
      ARGV.replace(args)
      app = ::Rake.application
      app.standard_exception_handling do
        app.init("rake", args)
        suppress_worker_frames(app)
        app.load_rakefile
        app.top_level
      end
    end

    def suppress_worker_frames(app)
      existing = app.options.suppress_backtrace_pattern || ::Rake::Backtrace::SUPPRESS_PATTERN
      app.options.suppress_backtrace_pattern = Regexp.union(existing, /\A#{Regexp.escape(__dir__)}/)
    rescue StandardError
      nil
    end

    def run_rspec(args)
      require "rspec/core"
      ::RSpec::Core::Runner.disable_autorun! if ::RSpec::Core::Runner.respond_to?(:disable_autorun!)
      suppress_worker_frames_in_rspec
      exit ::RSpec::Core::Runner.run(args, $stderr, $stdout)
    end

    def suppress_worker_frames_in_rspec
      ::RSpec.configure { |config| config.backtrace_exclusion_patterns << HARNESS_FRAME_PATTERN }
    rescue StandardError
      nil
    end

    def report_uncaught(error)
      error.set_backtrace(application_frames(error.backtrace)) if error.backtrace
      $stderr.write(error.full_message)
    rescue StandardError
      nil
    end

    def application_frames(backtrace)
      frames = backtrace.dup
      frames.pop while frames.last && harness_frame?(frames.last)
      frames
    end

    def harness_frame?(frame)
      HARNESS_FRAME_PATTERN.match?(frame)
    end
  end
end

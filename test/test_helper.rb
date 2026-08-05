# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "siding"

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

require_relative "support/unbundled_env"
require_relative "support/short_runtime_dir"
require_relative "support/process_helpers"
require_relative "support/fixture_edits"
require_relative "support/terminal_session"

module Siding
  module TestSupport
    include ProcessHelpers

    ROOT = File.expand_path("..", __dir__)
    EXE = File.join(ROOT, "exe", "siding")
    FIXTURE_APP = File.join(__dir__, "fixtures", "rails_app")

    Invocation = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def exitstatus = status.exitstatus
      def success? = status.success?
      def termsig = status.termsig
    end

    def siding_runtime_dir
      @siding_runtime_dir ||= ShortRuntimeDir.make
    end

    def siding_env(overrides = {})
      {
        "XDG_RUNTIME_DIR" => siding_runtime_dir,
        "SIDING_DISABLE" => nil,
        "SIDING_LOG" => nil
      }.merge(bundler_env).merge(overrides)
    end

    def bundler_env = UnbundledEnv.unbundled_env_overrides

    def siding_invoke(*argv, env: {}, chdir: FIXTURE_APP, stdin_data: nil)
      run_capture([RbConfig.ruby, EXE, *argv], env: siding_env(env), chdir: chdir, stdin_data: stdin_data)
    end

    def unaccelerated_invoke(*argv, env: {}, chdir: FIXTURE_APP, stdin_data: nil)
      run_capture(["bundle", "exec", *argv], env: siding_env(env), chdir: chdir, stdin_data: stdin_data)
    end

    def run_capture(command, env:, chdir:, stdin_data: nil)
      options = { chdir: chdir }
      options[:stdin_data] = stdin_data if stdin_data
      stdout, stderr, status = Open3.capture3(env, *command, **options)
      Invocation.new(stdout: stdout, stderr: stderr, status: status)
    end

    def siding_state_dir
      Dir.glob(File.join(siding_runtime_dir, Siding::Runtime::NAMESPACE, "*")).find do |path|
        File.directory?(path)
      end
    end

    def siding_server_info
      dir = siding_state_dir
      return nil unless dir

      path = File.join(dir, "server.json")
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # The pid of the warm application, tracked so the leak assertion in teardown covers it even
    # when the test itself never looks at it again.
    def siding_server_pid
      pid = siding_server_info&.dig("pid")
      pid && track_pid(pid)
    end

    def warm_application?
      dir = siding_state_dir
      !dir.nil? && File.socket?(File.join(dir, "sock")) && !siding_server_info.nil?
    end

    def teardown
      stop_siding
      assert_no_surviving_processes(runtime_dir: @siding_runtime_dir)
    ensure
      reap_tracked_processes
      FileUtils.remove_entry(@siding_runtime_dir) if @siding_runtime_dir && File.directory?(@siding_runtime_dir)
      super
    end

    def stop_siding
      return unless File.executable?(EXE) && File.directory?(FIXTURE_APP)

      run_capture([RbConfig.ruby, EXE, "stop"], env: siding_env, chdir: FIXTURE_APP)
    rescue StandardError
      # A failure to stop is not itself the assertion; the survivor check below is. Swallowing
      # here keeps a broken `stop` from masking the more specific failure.
      nil
    end
  end
end

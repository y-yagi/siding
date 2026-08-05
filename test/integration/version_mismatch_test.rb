# frozen_string_literal: true

require "test_helper"

module Siding
  class VersionMismatchTest < Minitest::Test
    include TestSupport

    PREVIOUS_VERSION_SERVER = File.expand_path("../support/previous_version_server.rb", __dir__)
    OTHER_PROTOCOL_VERSION = -1
    RESOLUTION_PROBE = ["rails", "runner", 'puts ENV.fetch("SIDING_RESOLUTION", "none")'].freeze

    def test_a_server_it_cannot_speak_to_is_replaced_rather_than_worked_around
      previous = start_previous_version_server

      result = siding_invoke(*RESOLUTION_PROBE)

      assert_equal 0, result.exitstatus, "the command did not run: #{result.stderr}"
      refute_equal "none", result.stdout.strip, "the invocation was not served by a warm application"
      refute alive?(previous), "the server speaking another protocol version is still running"
      assert warm_application?, "nothing was booted to replace it"
      refute_equal previous, siding_server_pid
    end

    def test_the_replacement_leaves_the_command_output_untouched
      start_previous_version_server
      script = 'puts "out"; warn "err"'

      accelerated = siding_invoke("rails", "runner", script)
      unaccelerated = unaccelerated_invoke("rails", "runner", script)

      assert_equal unaccelerated.stdout, accelerated.stdout
      assert_equal unaccelerated.stderr, accelerated.stderr
      assert_equal unaccelerated.exitstatus, accelerated.exitstatus
    end

    def test_the_published_record_describes_the_server_that_replaced_it
      start_previous_version_server

      siding_invoke(*RESOLUTION_PROBE)

      info = siding_server_info

      refute_nil info
      refute_equal "previous-version", info["revision_label"]
      assert_equal Protocol::VERSION, info["protocol_version"]
    end

    def test_stop_removes_a_server_it_cannot_speak_to
      previous = start_previous_version_server

      result = siding_invoke("stop")

      assert_equal 0, result.exitstatus
      refute alive?(previous), "`stop` returned with the server still running"
      refute warm_application?
    end

    private

    def runtime
      @runtime ||= begin
        env = subprocess_env
        Runtime.for(ProjectKey.for(FIXTURE_APP, env: env), env: env).tap(&:prepare)
      end
    end

    def subprocess_env
      ENV.to_h.merge(siding_env).compact
    end

    def start_previous_version_server
      stdin, stdout, wait = Open3.popen2(RbConfig.ruby, PREVIOUS_VERSION_SERVER,
                                         runtime.socket_path, runtime.server_info_path,
                                         OTHER_PROTOCOL_VERSION.to_s)
      stdin.close
      @previous_streams = [stdout]
      flunk "the previous-version server never became ready" unless stdout.gets == "ready\n"

      track_pid(wait.pid)
    end

    def teardown
      super
    ensure
      @previous_streams&.each { |stream| stream.close unless stream.closed? }
    end
  end
end

# frozen_string_literal: true

require "test_helper"

require "siding/worker"

module Siding
  class ValidationOrderTest < Minitest::Test
    include TestSupport
    include FixtureEdits

    def test_a_command_never_runs_against_an_application_that_is_already_stale
      log = File.join(Dir.mktmpdir("siding-order"), "runs.log")
      script = "File.open(#{log.inspect}, 'a') { |f| f.puts BootMarker::VALUE }"

      first = siding_invoke("rails", "runner", script)

      assert_equal 0, first.exitstatus, first.stderr
      siding_server_pid

      edit_fixture("lib/boot_marker.rb") { |source| source.sub("boot-marker-v1", "boot-marker-v9") }
      second = siding_invoke("rails", "runner", script)

      assert_equal 0, second.exitstatus, second.stderr
      siding_server_pid

      assert_equal %w[boot-marker-v1 boot-marker-v9], File.readlines(log, chomp: true),
                   "the command ran against a state the tool had already seen change"
    ensure
      FileUtils.remove_entry(File.dirname(log)) if log && File.directory?(File.dirname(log))
    end

    def test_a_worker_cannot_be_built_without_a_verdict
      error = assert_raises(ArgumentError) do
        Worker.new(connection: nil, message: {}, project_key: nil, manifest: nil)
      end

      assert_match(/verdict/, error.message)
    end
  end
end

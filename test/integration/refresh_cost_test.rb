# frozen_string_literal: true

require "test_helper"
require "pty"
require "shellwords"

module Siding
  class RefreshCostTest < Minitest::Test
    include TestSupport
    include FixtureEdits

    REBUILD_MARGIN = 0.75
    NOTICE_DEADLINE = 2.0

    def teardown
      super
    ensure
      @stream_dirs&.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
    end

    def test_a_rebuild_costs_no_more_than_running_the_command_without_the_tool
      warm_up
      edit_fixture("config/initializers/fixture_marker.rb") do |source|
        source.sub("initializer-v1", "initializer-v5")
      end

      accelerated, accelerated_seconds = time_it { siding_invoke("rails", "runner", marker_script) }
      siding_server_pid

      assert_equal 0, accelerated.exitstatus, accelerated.stderr
      assert_equal "initializer-v5", accelerated.stdout.split.last

      unaccelerated, unaccelerated_seconds = time_it do
        unaccelerated_invoke("rails", "runner", marker_script)
      end

      assert_equal 0, unaccelerated.exitstatus, unaccelerated.stderr
      assert_operator accelerated_seconds, :<=, unaccelerated_seconds + REBUILD_MARGIN,
                      "a rebuild took #{format('%.2f', accelerated_seconds)}s against " \
                      "#{format('%.2f', unaccelerated_seconds)}s unaccelerated -- the tool made " \
                      "the worst case worse"
    end

    def test_a_reloadable_change_is_repaired_without_a_rebuild_and_without_a_boot
      before = observe

      edit_fixture("app/models/gadget.rb") do
        "class Gadget\n  VALUE = \"gadget-cost\"\nend\n"
      end

      result, seconds = time_it { siding_invoke("rails", "runner", gadget_script) }
      siding_server_pid

      assert_equal 0, result.exitstatus, result.stderr
      after = read_observation(result)

      assert_equal "gadget-cost", after.value, "the added class was not found"
      assert_equal "reloaded_in_worker", after.resolution
      assert_equal before.booted_at, after.booted_at, "the repair rebooted the application"

      _, unaccelerated_seconds = time_it { unaccelerated_invoke("rails", "runner", gadget_script) }

      assert_operator seconds, :<, unaccelerated_seconds,
                      "repairing in the worker cost #{format('%.2f', seconds)}s, no better than " \
                      "the #{format('%.2f', unaccelerated_seconds)}s boot it was avoiding"
    end

    def test_a_wait_is_announced_on_the_terminal_and_nowhere_near_the_redirected_streams
      warm_up
      edit_fixture("config/initializers/fixture_marker.rb") do |source|
        source.sub("initializer-v1", "initializer-v6")
      end

      terminal = run_through_a_terminal("rails", "runner", marker_script)
      siding_server_pid

      assert_includes terminal.transcript, "[siding] waiting for the application",
                      "the developer was left waiting with no explanation"
      assert_includes terminal.transcript, "fixture_marker.rb"
      refute_nil terminal.notice_seconds
      assert_operator terminal.notice_seconds, :<, NOTICE_DEADLINE,
                      "the wait was announced after #{format('%.2f', terminal.notice_seconds)}s"

      unaccelerated = unaccelerated_invoke("rails", "runner", marker_script)

      assert_equal unaccelerated.stdout, File.read(terminal.stdout_path),
                   "the redirected stdout is not what an unaccelerated run would have written"
      assert_equal unaccelerated.stderr, File.read(terminal.stderr_path),
                   "the tool wrote to a stream that belonged to the command"
      refute_includes File.read(terminal.stdout_path), "siding"
      refute_includes File.read(terminal.stderr_path), "siding"
    end

    private

    Observation = Struct.new(:booted_at, :resolution, :revision, :value, keyword_init: true)
    Terminal = Struct.new(:transcript, :notice_seconds, :stdout_path, :stderr_path,
                          keyword_init: true)

    def marker_script
      "puts FixtureMarker::MARKER"
    end

    def gadget_script
      "puts [BootMarker.booted_at, ENV['SIDING_RESOLUTION'], ENV['SIDING_REVISION'], " \
        "Gadget::VALUE].join(' ')"
    end

    def observe
      result = siding_invoke("rails", "runner", gadget_script.sub("Gadget::VALUE", "'-'"))

      assert_equal 0, result.exitstatus, "invocation failed:\n#{result.stderr}"
      siding_server_pid
      read_observation(result)
    end

    def read_observation(result)
      fields = result.stdout.split.last(4)
      Observation.new(booted_at: fields[0], resolution: fields[1], revision: fields[2],
                      value: fields[3])
    end

    def warm_up
      result = siding_invoke("rails", "runner", marker_script)

      assert_equal 0, result.exitstatus, result.stderr
      refute_nil siding_server_pid, "nothing was warmed up to measure against"
    end

    def time_it
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end

    def run_through_a_terminal(*argv)
      dir = Dir.mktmpdir("siding-streams")
      # Removed in teardown rather than here: the captures are read after this method returns.
      (@stream_dirs ||= []) << dir
      stdout_path = File.join(dir, "out")
      stderr_path = File.join(dir, "err")
      command = "exec #{Shellwords.join([RbConfig.ruby, EXE, *argv])} " \
                "> #{Shellwords.escape(stdout_path)} 2> #{Shellwords.escape(stderr_path)}"

      transcript, notice_seconds = read_terminal(command)
      Terminal.new(transcript: transcript, notice_seconds: notice_seconds,
                   stdout_path: stdout_path, stderr_path: stderr_path)
    end

    def read_terminal(command)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      transcript = +""
      notice_seconds = nil
      reader, writer, pid = PTY.spawn(siding_env, "/bin/sh", "-c", command, chdir: FIXTURE_APP)
      writer.close

      begin
        loop do
          break unless reader.wait_readable(30)

          transcript << reader.readpartial(4096)
          notice_seconds ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
      rescue Errno::EIO, EOFError
        nil
      ensure
        reader.close unless reader.closed?
        Process.wait(pid)
      end

      [transcript, notice_seconds]
    end
  end
end

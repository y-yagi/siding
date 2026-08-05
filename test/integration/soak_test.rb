# frozen_string_literal: true

require "test_helper"

module Siding
  class SoakTest < Minitest::Test
    include TestSupport
    include FixtureEdits

    INVOCATIONS = Integer(ENV.fetch("SIDING_SOAK_INVOCATIONS", "500"))
    RELOADABLE_EDIT_EVERY = 7
    INITIALIZER_EDIT_EVERY = 29
    INTERRUPT_EVERY = 41
    DEPENDENCY_CHANGE_EVERY = 53
    BRANCH_SWITCH_EVERY = 97

    def setup
      unless ENV["SIDING_SOAK"]
        skip "set SIDING_SOAK=1 to run the #{INVOCATIONS}-invocation soak exercise"
      end

      write_markers(reloadable: "r0", initializer: "i0")
    end

    def test_hundreds_of_invocations_mixed_with_edits_interruptions_and_branch_switches
      failures = []
      disruptions = Hash.new(0)
      last = :none

      INVOCATIONS.times do |i|
        if i.positive?
          last = disrupt(i)
          disruptions[last] += 1
        end

        result = siding_invoke("rails", "runner", "print [SoakMarker.token, SoakInitializer::TOKEN].join('|')")
        observed = result.stdout.split.last

        # One invocation, two questions: did it run at all, and did it run against the source that was
        # on disk when it started. A wrong marker is the failure this whole project exists to prevent,
        # so it counts the same as a crash.
        next if result.exitstatus.zero? && observed == expected_marker

        failures << <<~DETAIL
          invocation #{i} (after #{last}): exit #{result.exitstatus.inspect}
            expected #{expected_marker.inspect}, got #{observed.inspect}
            #{result.stderr.lines.first(4).join("    ").strip}
        DETAIL
      end

      assert_empty failures, <<~MESSAGE
        #{failures.size} of #{INVOCATIONS} invocations did not run correctly.
        Disruptions applied: #{disruptions.reject { |key, _| key == :none }.inspect}

        #{failures.first(10).join("\n")}
      MESSAGE
    end

    private

    def disrupt(index)
      case
      when (index % BRANCH_SWITCH_EVERY).zero? then switch_branch(index)
      when (index % DEPENDENCY_CHANGE_EVERY).zero? then change_dependencies(index)
      when (index % INITIALIZER_EDIT_EVERY).zero? then edit_initializer(index)
      when (index % INTERRUPT_EVERY).zero? then interrupt_a_command(index)
      when (index % RELOADABLE_EDIT_EVERY).zero? then edit_reloadable(index)
      else :none
      end
    end

    def edit_reloadable(index)
      write_markers(reloadable: "r#{index}")
      :reloadable_edit
    end

    def edit_initializer(index)
      write_markers(initializer: "i#{index}")
      :initializer_edit
    end

    def change_dependencies(index)
      edit_fixture("Gemfile") { |original| "#{original.sub(/^# soak: .*\n/, '')}# soak: #{index}\n" }
      :dependency_change
    end

    def switch_branch(index)
      write_markers(reloadable: "r#{index}", initializer: "i#{index}")
      # A real definition, not a comment: `lib` is autoloaded in this fixture, and a file that defines
      # nothing is a Zeitwerk error rather than a staleness event.
      edit_fixture("lib/soak_support.rb") { "module SoakSupport\n  SWITCHED_AT = #{index}\nend\n" }
      :branch_switch
    end

    def interrupt_a_command(index)
      pid_path = File.join(scratch_dir, "interrupted-#{index}.pid")
      script = "File.write(#{pid_path.inspect}, Process.pid); sleep 30"
      client = Process.spawn(siding_env, RbConfig.ruby, EXE, "rails", "runner", script,
                             chdir: FIXTURE_APP, out: File::NULL, err: File::NULL)
      track_pid(client)
      worker = wait_for_pid(pid_path)

      Process.kill("KILL", client)
      Process.wait(client)

      if worker
        assert wait_until(15) { !alive?(worker) },
               "invocation #{index}: the worker survived the client that was killed"
      end
      :interruption
    end

    def expected_marker = "#{@reloadable}|#{@initializer}"

    def write_markers(reloadable: nil, initializer: nil)
      @reloadable = reloadable if reloadable
      @initializer = initializer if initializer

      if reloadable
        edit_fixture("app/models/soak_marker.rb") do
          "class SoakMarker\n  def self.token = #{@reloadable.inspect}\nend\n"
        end
      end
      return unless initializer

      edit_fixture("config/initializers/soak_initializer.rb") do
        "module SoakInitializer\n  TOKEN = #{@initializer.inspect}\nend\n"
      end
    end

    def scratch_dir
      @scratch_dir ||= Dir.mktmpdir("siding-soak")
    end

    def teardown
      super
    ensure
      FileUtils.remove_entry(@scratch_dir) if @scratch_dir && File.directory?(@scratch_dir)
    end

    def wait_for_pid(path, timeout = 60.0)
      wait_until(timeout) { File.file?(path) && !File.read(path).strip.empty? }
      return nil unless File.file?(path)

      pid = File.read(path).strip.to_i
      pid.positive? ? track_pid(pid) : nil
    rescue SystemCallError
      nil
    end

    def wait_until(timeout = 10.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return true if yield
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end
  end
end

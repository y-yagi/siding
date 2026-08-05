# frozen_string_literal: true

require "test_helper"

module Siding
  class OutputIdentityTest < Minitest::Test
    include TestSupport
    include FixtureEdits

    RSPEC_TIMING_LINE = /^Finished in .+\n/

    def test_stdout_is_identical
      assert_identical("rails", "runner", 'puts "hello from the application"')
    end

    def test_both_streams_are_identical
      assert_identical("rails", "runner", 'puts "to stdout"; warn "to stderr"')
    end

    def test_stream_ordering_is_preserved
      assert_identical("rails", "runner", '3.times { |i| puts "out-#{i}"; warn "err-#{i}" }')
    end

    def test_output_without_a_trailing_newline_is_identical
      assert_identical("rails", "runner", 'print "no trailing newline"')
    end

    def test_large_output_is_not_truncated
      result = assert_identical("rails", "runner", "2000.times { |i| puts i }")

      assert_equal 2000, result.stdout.lines.size
    end

    def test_a_non_zero_exit_status_is_reproduced
      result = assert_identical("rails", "runner", "exit 3")

      assert_equal 3, result.exitstatus
    end

    def test_rake_output_is_identical
      assert_identical("rake", "-T")
    end

    def test_stdin_reaches_the_command
      result = assert_identical("rails", "runner", "puts $stdin.read.upcase",
                                stdin_data: "typed by the developer\n")

      assert_equal "TYPED BY THE DEVELOPER\n", result.stdout
    end

    def test_an_uncaught_exception_is_reported_in_ruby_s_own_format
      command = ["rails", "runner", 'raise ArgumentError, "boom"']
      accelerated = siding_invoke(*command)
      unaccelerated = unaccelerated_invoke(*command)

      assert_equal unaccelerated.exitstatus, accelerated.exitstatus
      assert_equal unaccelerated.stdout, accelerated.stdout
      assert_operator accelerated.stderr.length, :>, 0
      assert unaccelerated.stderr.start_with?(accelerated.stderr), <<~MESSAGE
        the accelerated trace is not the unaccelerated one with the launcher's frames removed.

        accelerated:
        #{accelerated.stderr}
        unaccelerated:
        #{unaccelerated.stderr}
      MESSAGE
      refute_includes accelerated.stderr, "siding/worker.rb",
                      "the tool's own frames leaked into an application backtrace"
    end

    def test_a_failing_rake_task_is_reported_by_rake
      command = ["rake", "no_such_task_exists"]
      accelerated = siding_invoke(*command)
      unaccelerated = unaccelerated_invoke(*command)

      assert_equal unaccelerated.exitstatus, accelerated.exitstatus
      refute_equal 0, accelerated.exitstatus
      assert_equal unaccelerated.stderr.lines.first(2), accelerated.stderr.lines.first(2)
      assert_equal unaccelerated.stderr.lines.last, accelerated.stderr.lines.last
      refute_includes accelerated.stderr, "siding/worker.rb"
    end

    def test_rspec_output_is_identical
      result = assert_identical("rspec", "spec/boot_marker_spec.rb", normalize: RSPEC_TIMING_LINE)

      assert_includes result.stdout, "1 example, 0 failures"
    end

    def test_a_failing_rspec_example_is_reported_by_rspec
      relative_path = edit_fixture("spec/output_identity_failure_spec.rb") do
        <<~RUBY
          RSpec.describe "a failing example" do
            it "fails" do
              expect(1).to eq(2)
            end
          end
        RUBY
      end.delete_prefix("#{FIXTURE_APP}/")

      result = assert_identical("rspec", relative_path, normalize: RSPEC_TIMING_LINE)

      refute_equal 0, result.exitstatus
      assert_includes result.stdout, "1 example, 1 failure"
      refute_includes result.stdout, "siding/worker.rb"
    end

    private

    def assert_identical(*argv, stdin_data: nil, normalize: nil)
      accelerated = siding_invoke(*argv, stdin_data: stdin_data)
      unaccelerated = unaccelerated_invoke(*argv, stdin_data: stdin_data)

      accelerated_stdout = normalize ? accelerated.stdout.sub(normalize, "") : accelerated.stdout
      unaccelerated_stdout = normalize ? unaccelerated.stdout.sub(normalize, "") : unaccelerated.stdout

      assert_equal unaccelerated_stdout, accelerated_stdout, "stdout differs for #{argv.inspect}"
      assert_equal unaccelerated.stderr, accelerated.stderr, "stderr differs for #{argv.inspect}"
      assert_equal unaccelerated.exitstatus, accelerated.exitstatus,
                   "exit status differs for #{argv.inspect}"
      accelerated
    end
  end
end

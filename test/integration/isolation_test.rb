# frozen_string_literal: true

require "test_helper"

module Siding
  class IsolationTest < Minitest::Test
    include TestSupport

    OTHER_MARKER = "second-checkout"

    def test_two_checkouts_get_separate_warm_applications
      other = second_checkout

      here = siding_invoke("rails", "runner", "print FixtureMarker::MARKER")
      there = siding_invoke("rails", "runner", "print FixtureMarker::MARKER", chdir: other)

      assert_equal 0, here.exitstatus, here.stderr
      assert_equal 0, there.exitstatus, there.stderr

      # The load-bearing assertion. Each command was served by the source tree it was run in.
      assert_equal "initializer-v1", here.stdout.split.last
      assert_equal OTHER_MARKER, there.stdout.split.last,
                   "a command in the second checkout was served by the first checkout's application"
    end

    def test_the_two_checkouts_share_no_state_and_no_server
      other = second_checkout

      siding_invoke("rails", "runner", "print 'ok'")
      siding_invoke("rails", "runner", "print 'ok'", chdir: other)

      assert_equal 2, state_dirs.size,
                   "the two checkouts were resolved to #{state_dirs.size} state directory(s)"

      here = state_dir_for(FIXTURE_APP)
      there = state_dir_for(other)

      refute_nil here, "the first checkout published no server record"
      refute_nil there, "the second checkout did not get a server of its own"
      # Same digest would mean the same socket path, which is the mechanism by which the wrong
      # application would have answered.
      refute_equal File.basename(here), File.basename(there)
      refute_equal server_pid_in(FIXTURE_APP), server_pid_in(other),
                   "both checkouts are being served by one process"
    end

    def test_stopping_one_checkout_leaves_the_other_running
      other = second_checkout
      siding_invoke("rails", "runner", "print 'ok'")
      siding_invoke("rails", "runner", "print 'ok'", chdir: other)
      here = server_pid_in(FIXTURE_APP)
      there = server_pid_in(other)

      refute_nil here
      refute_nil there

      run_capture([RbConfig.ruby, EXE, "stop"], env: siding_env, chdir: FIXTURE_APP)

      refute alive?(here), "`stop` did not stop the checkout it was run in"
      assert alive?(there), "`stop` in one checkout stopped the other checkout's application"
    end

    def teardown
      # Before `TestSupport#teardown`, which stops the fixture checkout and then asserts that nothing
      # belonging to the tool survived. The second checkout is stopped through the same documented
      # path, so a server left behind there fails that assertion rather than the temp-dir removal.
      if @second_checkout && File.directory?(@second_checkout)
        run_capture([RbConfig.ruby, EXE, "stop"], env: siding_env, chdir: @second_checkout)
      end
      super
    ensure
      FileUtils.remove_entry(@checkout_root) if @checkout_root && File.directory?(@checkout_root)
    end

    private

    def second_checkout
      @second_checkout ||= begin
        @checkout_root = Dir.mktmpdir("siding-second-checkout")
        destination = File.join(@checkout_root, "rails_app")
        FileUtils.cp_r(FIXTURE_APP, destination)
        # Neither is source, and both are large enough to be worth not copying twice.
        %w[log tmp].each do |scratch|
          FileUtils.rm_rf(File.join(destination, scratch))
          FileUtils.mkdir_p(File.join(destination, scratch))
        end
        rewrite_marker(destination)
        destination
      end
    end

    def rewrite_marker(root)
      path = File.join(root, "config", "initializers", "fixture_marker.rb")
      File.write(path, File.read(path).sub('"initializer-v1"', OTHER_MARKER.inspect))
    end

    def state_dirs
      Dir.glob(File.join(siding_runtime_dir, Siding::Runtime::NAMESPACE, "*")).select do |path|
        File.directory?(path)
      end
    end

    def state_dir_for(root)
      wanted = File.realpath(root)
      state_dirs.find { |dir| record_in(dir)&.dig("app_root") == wanted }
    end

    def server_pid_in(root)
      pid = record_in(state_dir_for(root))&.dig("pid")
      pid && track_pid(pid)
    end

    def record_in(dir)
      return nil if dir.nil?

      path = File.join(dir, "server.json")
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end
end

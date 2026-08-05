# frozen_string_literal: true

require "test_helper"

require "siding/logger"
require "siding/restarter"
require "siding/load_manifest"

module Siding
  module RestarterDecisionCases
    def setup
      @dir = File.realpath(Dir.mktmpdir("siding-restarter"))
      @source = File.join(@dir, "source.rb")
      File.write(@source, "SOURCE = 1\n")
      @now = 1000.0
      @boots = []
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
      super
    end

    def test_the_poll_interval_grows_with_idle_time_and_stops_growing
      restarter = build

      assert_in_delta Restarter::MIN_INTERVAL, restarter.interval_for(0)
      assert_in_delta Restarter::MIN_INTERVAL, restarter.interval_for(10)
      assert_in_delta 6.0, restarter.interval_for(60)
      assert_in_delta 30.0, restarter.interval_for(300)
      assert_in_delta Restarter::MAX_INTERVAL, restarter.interval_for(3_600)
    end

    def test_the_poll_interval_never_exceeds_its_ceiling
      restarter = build
      intervals = [0, 1, 60, 600, 86_400].map { |idle| restarter.interval_for(idle) }

      assert_operator intervals.max, :<=, Restarter::MAX_INTERVAL
      assert_operator intervals.min, :>=, Restarter::MIN_INTERVAL
    end

    def test_a_burst_of_saves_produces_one_boot_after_it_settles
      restarter = build

      5.times do |index|
        File.write(@source, "SOURCE = #{index + 2}\n")
        advance(0.2)

        assert_equal Restarter::SETTLING, poll(restarter), "booted in the middle of a burst"
      end

      advance(Restarter::SETTLE + 0.1)

      assert_equal Restarter::BOOT, poll(restarter)
      assert_equal 1, @boots.size
    end

    def test_the_same_change_is_not_booted_twice
      restarter = build
      change_and_settle(restarter)

      assert_equal Restarter::BOOT, poll(restarter)

      3.times do
        advance(10)

        assert_equal Restarter::QUIET, poll(restarter)
      end

      assert_equal 1, @boots.size
    end

    def test_nothing_is_booted_while_the_server_is_busy
      busy = true
      restarter = build(busy: -> { busy })

      change_and_settle(restarter)

      assert_equal Restarter::QUIET, poll(restarter)
      assert_empty @boots

      busy = false
      change_and_settle(restarter)

      assert_equal Restarter::BOOT, poll(restarter)
    end

    def test_a_superseded_server_stands_down_instead_of_booting
      restarter = build(superseded: -> { true })
      change_and_settle(restarter)

      assert_equal Restarter::SUPERSEDED, poll(restarter)
      assert_empty @boots
    end

    def test_a_change_that_is_undone_before_it_settles_is_not_booted
      restarter = build
      original = File.stat(@source)

      File.write(@source, "SOURCE = 2\n")
      advance(0.2)

      assert_equal Restarter::SETTLING, poll(restarter)

      File.write(@source, "SOURCE = 1\n")
      File.utime(original.atime, original.mtime, @source)
      advance(Restarter::SETTLE + 0.1)

      assert_equal Restarter::QUIET, poll(restarter)
      assert_empty @boots
    end

    def test_an_event_with_nothing_changed_on_disk_produces_no_boot
      restarter = build
      restarter.instance_variable_get(:@signal) << :changed

      assert_equal Restarter::QUIET, poll(restarter)
      assert_empty @boots
    end

    private

    def build(busy: nil, superseded: nil)
      Restarter.new(manifest: manifest, project_key: nil, runtime: nil,
                    logger: Logger.new(log_path: File.join(@dir, "log")),
                    env: env, clock: -> { @now }, busy: busy, superseded: superseded,
                    spawner: -> { @boots << @now; 4242 })
    end

    def manifest
      @manifest ||= LoadManifest.build(app_root: @dir, loaded: [@source])
    end

    def poll(restarter)
      restarter.poll(now: @now)
    end

    def advance(seconds)
      @now += seconds
    end

    def change_and_settle(restarter)
      File.write(@source, "SOURCE = #{rand(1_000_000)}\n")
      advance(0.1)
      restarter.poll(now: @now)
      advance(Restarter::SETTLE + 0.1)
    end
  end

  class RestarterDecisionEventsTest < Minitest::Test
    include RestarterDecisionCases

    def env = {}
  end

  class RestarterDecisionPollTest < Minitest::Test
    include RestarterDecisionCases

    def env = { "SIDING_WATCH" => "poll" }
  end
end

# frozen_string_literal: true

require "test_helper"

require "siding/staleness"

module Siding
  class StalenessEventsTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir("siding-events")
      @path = File.join(@dir, "events.jsonl")
      super
    end

    def teardown
      FileUtils.remove_entry(@dir) if File.directory?(@dir)
      super
    end

    def verdict(reason: Staleness::SOURCE_CHANGED, paths: ["config/initializers/thing.rb"])
      Staleness::Verdict.new(strategy: Staleness::REBOOT, reasons: [reason], trigger_paths: paths,
                             revision_label: "abc123")
    end

    def test_a_recorded_event_is_readable_by_a_later_process
      Staleness::Events.new(path: @path).record(verdict)

      reread = Staleness::Events.new(path: @path).to_a

      assert_equal 1, reread.size
      assert_equal "rebuild", reread.first.resolution
      assert_equal ["config/initializers/thing.rb"], reread.first.trigger_paths
      assert_equal Staleness::SOURCE_CHANGED.to_s, reread.first.reason
    end

    def test_events_from_separate_instances_accumulate
      Staleness::Events.new(path: @path).record(verdict(paths: ["a.rb"]))
      Staleness::Events.new(path: @path).record(verdict(paths: ["b.rb"]))

      assert_equal [["a.rb"], ["b.rb"]], Staleness::Events.new(path: @path).to_a.map(&:trigger_paths)
    end

    def test_a_torn_line_is_skipped_rather_than_fatal
      Staleness::Events.new(path: @path).record(verdict(paths: ["intact.rb"]))
      File.open(@path, "a") { |file| file.write('{"at":"2026-07-27T00:00:00') }

      events = Staleness::Events.new(path: @path).to_a

      assert_equal [["intact.rb"]], events.map(&:trigger_paths)
    end

    def test_an_unwritable_path_does_not_raise
      File.chmod(0o500, @dir)

      events = Staleness::Events.new(path: File.join(@dir, "nested", "events.jsonl"))

      assert_equal 1, events.record(verdict) && events.size
    ensure
      File.chmod(0o700, @dir)
    end

    def test_the_history_read_back_is_bounded
      recorder = Staleness::Events.new(path: @path)
      (Staleness::Events::LIMIT + 10).times { |i| recorder.record(verdict(paths: ["file-#{i}.rb"])) }

      events = Staleness::Events.new(path: @path).to_a

      assert_equal Staleness::Events::LIMIT, events.size
      assert_equal ["file-#{Staleness::Events::LIMIT + 9}.rb"], events.last.trigger_paths
    end
  end
end

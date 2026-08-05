# frozen_string_literal: true

require "test_helper"
require "timeout"

require "siding/watch"
require "siding/load_manifest"
require "siding/logger"

module Siding
  class WatchTest < Minitest::Test
    def setup
      @dir = File.realpath(Dir.mktmpdir("siding-watch"))
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
      super
    end

    def test_the_default_is_events
      assert_equal Watch::EVENTS, Watch.mode_from({})
    end

    def test_poll_is_recognized_explicitly
      assert_equal Watch::POLL, Watch.mode_from({ "SIDING_WATCH" => "poll" })
    end

    def test_events_is_recognized_explicitly
      assert_equal Watch::EVENTS, Watch.mode_from({ "SIDING_WATCH" => "events" })
    end

    def test_an_unrecognized_value_falls_back_to_events_and_says_so
      logger = verbose_logger

      assert_equal Watch::EVENTS, Watch.mode_from({ "SIDING_WATCH" => "sometimes" }, logger: logger)
      assert logger.events.any? { |event| event.message.include?("sometimes") },
             "the unrecognized value was not reported"
    end

    def test_mode_from_works_without_logger
      assert_equal Watch::EVENTS, Watch.mode_from({ "SIDING_WATCH" => "sometimes" })
    end

    def test_poll_mode_starts_a_watcher_labeled_poll_and_wakes_on_a_change
      watched = File.join(@dir, "config", "initializers")
      FileUtils.mkdir_p(watched)
      manifest = manifest_double(directories: [dir_entry(watched)])
      changed = Queue.new

      watcher = Watch.start(manifest: manifest, env: { "SIDING_WATCH" => "poll" },
                            logger: silent_logger) { changed << true }

      refute_nil watcher, "poll mode did not start against the real watchcat gem"
      assert watcher.watching?
      assert_equal "poll (watchcat)", watcher.mode_label
      sleep 0.3

      File.write(File.join(watched, "new_file.rb"), "X = 1\n")

      begin
        Timeout.timeout(5) { changed.pop }
      rescue Timeout::Error
        flunk "the poll watcher never called back after a file changed under a watched root"
      end
    ensure
      watcher&.stop
    end

    def test_a_manifest_with_nothing_to_watch_starts_no_watcher
      manifest = manifest_double

      watcher = Watch.start(manifest: manifest, env: {}, logger: silent_logger) { nil }

      assert_nil watcher
    end

    def test_falls_back_to_poll_when_watchcat_fails_to_start
      require "watchcat"
      manifest = manifest_double(directories: [dir_entry(@dir)])
      logger = verbose_logger

      watcher = Watchcat.stub(:watch, ->(*) { raise ArgumentError, "boom" }) do
        Watch.start(manifest: manifest, env: {}, logger: logger) { nil }
      end

      refute_nil watcher
      refute watcher.watching?
      assert_match(/ArgumentError/, watcher.mode_label)
    end

    def test_a_change_under_a_watched_root_wakes_the_callback
      initializers = File.join(@dir, "config", "initializers")
      FileUtils.mkdir_p(initializers)
      manifest = manifest_double(directories: [dir_entry(initializers)])
      changed = Queue.new

      watcher = Watch.start(manifest: manifest, env: {}, logger: silent_logger) { changed << true }
      refute_nil watcher, "events mode did not start against the real watchcat gem"
      assert watcher.watching?
      sleep 0.3

      File.write(File.join(initializers, "new_file.rb"), "X = 1\n")

      begin
        Timeout.timeout(5) { changed.pop }
      rescue Timeout::Error
        flunk "the watcher never called back after a file changed under a watched root"
      end
    ensure
      watcher&.stop
    end

    def test_reading_a_watched_file_does_not_wake_the_restarter
      watched = File.join(@dir, "config", "initializers")
      FileUtils.mkdir_p(watched)
      target = File.join(watched, "existing.rb")
      File.write(target, "X = 1\n")
      manifest = manifest_double(directories: [dir_entry(watched)])
      changed = Queue.new

      watcher = Watch.start(manifest: manifest, env: {}, logger: silent_logger) { changed << true }
      refute_nil watcher, "events mode did not start against the real watchcat gem"
      assert watcher.watching?

      drain_until_quiet(changed)

      File.read(target)
      Dir.children(watched)

      begin
        Timeout.timeout(1) { changed.pop }
        flunk "a read under a watched root woke the restarter -- ignore_access is not being applied"
      rescue Timeout::Error
        # expected: no callback for a read
      end

      File.write(File.join(watched, "new_file.rb"), "Y = 1\n")

      begin
        Timeout.timeout(5) { changed.pop }
      rescue Timeout::Error
        flunk "the watcher never called back after a real write -- it was dead, not just filtered"
      end
    ensure
      watcher&.stop
    end

    def test_directory_entries_are_watched_recursively
      autoload_root = File.join(@dir, "app", "models")
      FileUtils.mkdir_p(autoload_root)
      manifest = manifest_double(directories: [dir_entry(autoload_root)])

      assert_equal [Watch::RootEntry.new(autoload_root, true)], Watch.roots_for(manifest)
    end

    def test_file_entry_dirnames_are_watched_non_recursively_and_deduplicated
      lib_dir = File.join(@dir, "lib")
      FileUtils.mkdir_p(lib_dir)
      a = File.join(lib_dir, "a.rb")
      b = File.join(lib_dir, "b.rb")
      [a, b].each { |path| File.write(path, "") }
      manifest = manifest_double(files: [file_entry(a), file_entry(b)])

      assert_equal [Watch::RootEntry.new(lib_dir, false)], Watch.roots_for(manifest)
    end

    def test_a_file_dirname_already_covered_by_a_recursive_root_is_not_duplicated
      root = File.join(@dir, "app", "models")
      FileUtils.mkdir_p(root)
      nested = File.join(root, "user.rb")
      File.write(nested, "")
      manifest = manifest_double(directories: [dir_entry(root)], files: [file_entry(nested)])

      assert_equal [Watch::RootEntry.new(root, true)], Watch.roots_for(manifest)
    end

    def test_the_bundle_files_directory_is_watched_non_recursively
      gemfile = File.join(@dir, "Gemfile")
      File.write(gemfile, "")
      manifest = manifest_double(bundle_files: [gemfile, "#{gemfile}.lock"])

      assert_equal [Watch::RootEntry.new(@dir, false)], Watch.roots_for(manifest)
    end

    def test_a_root_that_does_not_exist_is_not_returned
      missing = File.join(@dir, "gone")
      manifest = manifest_double(directories: [dir_entry(missing)])

      assert_empty Watch.roots_for(manifest)
    end

    def test_roots_derived_from_a_real_manifest_exclude_tmp_and_log_and_include_initializers
      initializers = File.join(@dir, "config", "initializers")
      lib_dir = File.join(@dir, "lib")
      tmp_dir = File.join(@dir, "tmp")
      log_dir = File.join(@dir, "log")
      [initializers, lib_dir, tmp_dir, log_dir].each { |dir| FileUtils.mkdir_p(dir) }

      lib_file = File.join(lib_dir, "thing.rb")
      tmp_file = File.join(tmp_dir, "cache.txt")
      log_file = File.join(log_dir, "development.log")
      [lib_file, tmp_file, log_file].each { |path| File.write(path, "") }

      manifest = LoadManifest.build(app_root: @dir, loaded: [lib_file, tmp_file, log_file])
      roots = Watch.roots_for(manifest)

      initializer_root = roots.find { |entry| entry.path == initializers }
      refute_nil initializer_root, "config/initializers was not derived from the manifest"
      assert initializer_root.recursive

      assert_includes roots.map(&:path), lib_dir
      refute roots.any? { |entry| entry.path == tmp_dir || entry.path.start_with?("#{tmp_dir}/") }
      refute roots.any? { |entry| entry.path == log_dir || entry.path.start_with?("#{log_dir}/") }
    end

    private

    ManifestDouble = Struct.new(:directory_entries, :file_entries, :bundle_files)

    def manifest_double(directories: [], files: [], bundle_files: [])
      ManifestDouble.new(directories, files, bundle_files)
    end

    def dir_entry(path)
      LoadManifest::DirectoryEntry.new(path, "digest", true, LoadManifest::REBOOT)
    end

    def file_entry(path)
      stat = File.stat(path)
      LoadManifest::FileEntry.new(path, stat.size, stat.mtime.to_f, LoadManifest::REBOOT)
    end

    def silent_logger
      Logger.new(env: {}, log_path: File.join(@dir, "silent.log"))
    end

    def verbose_logger
      Logger.new(env: { "SIDING_LOG" => "1" }, log_path: File.join(@dir, "verbose.log"))
    end

    def drain_until_quiet(queue, quiet_for: 0.3)
      loop do
        queue.pop until queue.empty?
        Timeout.timeout(quiet_for) { queue.pop }
      rescue Timeout::Error
        return
      end
    end
  end
end

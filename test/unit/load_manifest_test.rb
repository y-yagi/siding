# frozen_string_literal: true

require "test_helper"

require "siding/load_manifest"
require "siding/staleness"

module Siding
  class LoadManifestTest < Minitest::Test
    def setup
      @dir = File.realpath(Dir.mktmpdir("siding-manifest"))
      @source = File.join(@dir, "source.rb")
      File.write(@source, "SOURCE = 1\n")
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
      super
    end

    def test_a_change_within_the_same_second_is_detected
      manifest = build
      entry = manifest.file_entries.find { |candidate| candidate.path == @source }

      File.write(@source, "SOURCE = 2\n")
      unless File.stat(@source).mtime.to_i == Time.at(entry.mtime).to_i
        skip "the two writes landed in different whole seconds; this run proves nothing"
      end

      verdict = Staleness.validate(manifest)

      assert_predicate verdict, :stale?
      assert_includes verdict.reasons, Staleness::SOURCE_CHANGED
    end

    def test_the_recorded_stamp_keeps_sub_second_precision
      stamp = LoadManifest.stamp_for(@source)

      assert_match(/\A\d+:\d+\.\d{6}\z/, stamp)
    end

    def test_a_missing_file_has_a_stamp_of_its_own_rather_than_an_exception
      assert_equal "missing", LoadManifest.stamp_for(File.join(@dir, "absent.rb"))
    end

    def test_the_revision_label_is_a_function_of_the_state_and_nothing_else
      assert_equal build.revision_label, build.revision_label
    end

    def test_the_revision_label_changes_with_the_state_and_changes_back
      original = File.stat(@source)
      before = build.revision_label

      File.write(@source, "SOURCE = 2\n")

      refute_equal before, build.revision_label

      File.write(@source, "SOURCE = 1\n")
      File.utime(original.atime, original.mtime, @source)

      assert_equal before, build.revision_label
    end

    def test_validation_of_an_unchanged_manifest_is_cheap
      manifest = build
      samples = Array.new(20) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Staleness.validate(manifest)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      assert_operator samples.min, :<, 0.010,
                      "validating a trivial manifest cost #{(samples.min * 1000).round(2)}ms"
    end

    def test_an_environment_value_is_never_retained_verbatim
      manifest = LoadManifest.build(app_root: @dir, loaded: [],
                                     env_reads: { "SECRET_KEY_BASE" => "shh-do-not-keep-this" })
      entry = manifest.env_entries.find { |candidate| candidate.key == "SECRET_KEY_BASE" }

      refute_nil entry
      refute_equal "shh-do-not-keep-this", entry.value_digest
      assert_equal LoadManifest.digest_env_value("shh-do-not-keep-this"), entry.value_digest
      assert_match(/\A[0-9a-f]{64}\z/, entry.value_digest)
    end

    def test_a_nil_environment_value_never_collides_with_a_real_value
      unset = LoadManifest.digest_env_value(nil)

      refute_equal unset, LoadManifest.digest_env_value("")
      refute_equal unset, LoadManifest.digest_env_value("\1")
      refute_equal unset, LoadManifest.digest_env_value("0")
    end

    def test_environment_changed_forces_reboot_scope_by_key_name_not_value
      manifest = LoadManifest.build(app_root: @dir, loaded: [@source],
                                     env_reads: { "SECRET_KEY_BASE" => "old" })

      verdict = Staleness.validate(manifest, env: { "SECRET_KEY_BASE" => "new" })

      assert_predicate verdict, :reboot?
      assert_includes verdict.reasons, Staleness::ENVIRONMENT_CHANGED
      assert_equal ["SECRET_KEY_BASE"], verdict.trigger_paths
    end

    def test_autoload_roots_outside_app_root_are_excluded_from_directory_entries
      inside_dir = File.join(@dir, "app", "models")
      FileUtils.mkdir_p(inside_dir)

      outside_dir = File.realpath(Dir.mktmpdir("siding-gem-engine"))

      with_fake_rails(dirs: [inside_dir, outside_dir]) do
        manifest = build
        paths = manifest.directory_entries.map(&:path)

        assert_includes paths, inside_dir
        refute_includes paths, outside_dir
      end
    ensure
      FileUtils.remove_entry(outside_dir) if outside_dir && File.directory?(outside_dir)
    end

    private

    FakeLoader = Struct.new(:dirs) do
      def reloading_enabled? = false
    end

    def with_fake_rails(dirs:)
      had_rails = Object.const_defined?(:Rails)
      previous_rails = Object.const_get(:Rails) if had_rails
      Object.send(:remove_const, :Rails) if had_rails

      fake_rails = Module.new
      fake_rails.define_singleton_method(:application) { Object.new }
      fake_rails.define_singleton_method(:autoloaders) { [FakeLoader.new(dirs)] }
      Object.const_set(:Rails, fake_rails)
      yield
    ensure
      Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails)
      Object.const_set(:Rails, previous_rails) if had_rails
    end

    def build
      LoadManifest.build(app_root: @dir, loaded: [@source])
    end
  end
end

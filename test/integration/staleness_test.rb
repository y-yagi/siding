# frozen_string_literal: true

require "test_helper"

module Siding
  class StalenessTest < Minitest::Test
    include TestSupport
    include FixtureEdits

    Observation = Struct.new(:booted_at, :resolution, :revision, :value, keyword_init: true)

    FRESH = "fresh"
    RELOADED = "reloaded_in_worker"
    REBUILD = "rebuild"

    def test_an_unchanged_application_is_served_without_repair
      first = observe
      second = observe

      assert_equal first.booted_at, second.booted_at, "the application was rebuilt for no reason"
      assert_equal FRESH, second.resolution
      assert_equal first.revision, second.revision
    end

    def test_editing_an_initializer_rebuilds_and_the_new_value_is_visible
      before = observe("FixtureMarker::MARKER")

      assert_equal "initializer-v1", before.value

      edit_fixture("config/initializers/fixture_marker.rb") do |source|
        source.sub("initializer-v1", "initializer-v2")
      end
      after = observe("FixtureMarker::MARKER")

      assert_equal "initializer-v2", after.value, "the invocation ran against the old initializer"
      assert_equal REBUILD, after.resolution
      refute_equal before.booted_at, after.booted_at, "the application was not replaced"
    end

    def test_a_newly_added_initializer_rebuilds_and_runs
      before = observe

      edit_fixture("config/initializers/zz_matrix_marker.rb") do
        "MatrixMarker = \"added-initializer\"\n"
      end
      after = observe("defined?(MatrixMarker) ? MatrixMarker : 'absent'")

      assert_equal "added-initializer", after.value, "the added initializer never ran"
      assert_equal REBUILD, after.resolution
      refute_equal before.booted_at, after.booted_at
    end

    def test_editing_a_file_required_at_boot_rebuilds
      before = observe("BootMarker::VALUE")

      assert_equal "boot-marker-v1", before.value

      edit_fixture("lib/boot_marker.rb") { |source| source.sub("boot-marker-v1", "boot-marker-v2") }
      after = observe("BootMarker::VALUE")

      assert_equal "boot-marker-v2", after.value
      assert_equal REBUILD, after.resolution
      refute_equal before.booted_at, after.booted_at
    end

    def test_a_file_added_to_an_autoload_path_is_reloaded_in_the_worker
      before = observe

      edit_fixture("app/models/gadget.rb") do
        "class Gadget\n  VALUE = \"gadget-v1\"\nend\n"
      end
      after = observe("Gadget::VALUE")

      assert_equal "gadget-v1", after.value, "the added class was not found"
      assert_equal RELOADED, after.resolution
      assert_equal before.booted_at, after.booted_at,
                   "a reloadable change rebooted the application"
    end

    def test_editing_an_autoloaded_file_is_visible_without_any_repair
      before = observe("Widget::SHAPE")

      assert_equal "widget-v1", before.value

      edit_fixture("app/models/widget.rb") { |source| source.sub("widget-v1", "widget-v2") }
      after = observe("Widget::SHAPE")

      assert_equal "widget-v2", after.value, "the invocation ran against the old class"
      assert_equal FRESH, after.resolution
      assert_equal before.booted_at, after.booted_at
    end

    def test_an_eager_loaded_class_is_reboot_scope_when_reloading_is_disabled
      env = { "RAILS_ENV" => "test" }
      before = observe("Widget::SHAPE", env: env)

      assert_equal "widget-v1", before.value

      edit_fixture("app/models/widget.rb") { |source| source.sub("widget-v1", "widget-v3") }
      after = observe("Widget::SHAPE", env: env)

      assert_equal "widget-v3", after.value
      assert_equal REBUILD, after.resolution
      refute_equal before.booted_at, after.booted_at
    ensure
      run_capture([RbConfig.ruby, EXE, "stop"], env: siding_env(env), chdir: FIXTURE_APP)
    end

    def test_changing_an_environment_variable_read_at_boot_rebuilds
      before = observe("FixtureMarker::FIXTURE_ENV", env: { "FIXTURE_ENV" => "first" })

      assert_equal "first", before.value

      after = observe("FixtureMarker::FIXTURE_ENV", env: { "FIXTURE_ENV" => "second" })

      assert_equal "second", after.value, "the invocation was served an application built with " \
                                         "the old value"
      assert_equal REBUILD, after.resolution
      refute_equal before.booted_at, after.booted_at
    end

    def test_changing_the_bundle_rebuilds
      before = observe

      edit_fixture("Gemfile") { |source| "#{source}\n# staleness matrix\n" }
      after = observe

      assert_equal REBUILD, after.resolution
      refute_equal before.booted_at, after.booted_at
    end

    private

    def observe(expression = '"-"', env: {})
      script = "puts [BootMarker.booted_at, ENV['SIDING_RESOLUTION'], ENV['SIDING_REVISION'], " \
               "(#{expression})].join(' ')"
      result = siding_invoke("rails", "runner", script, env: env)

      assert_equal 0, result.exitstatus, "invocation failed:\n#{result.stderr}"
      siding_server_pid # tracked here so the leak assertion covers every server a test warmed

      fields = result.stdout.split.last(4)
      Observation.new(booted_at: fields[0], resolution: fields[1], revision: fields[2],
                      value: fields[3])
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "bundler/environment_preserver"

module Siding
  class UnbundledEnvTest < Minitest::Test
    def test_it_restores_every_variable_bundler_recorded_an_original_for
      overrides = UnbundledEnv.unbundled_env_overrides

      recorded = ENV.keys.grep(/\ABUNDLER_ORIG_/)
      refute_empty recorded,
                   "this process is not running under a bundle, so the test asserts nothing " \
                   "(run it through `rake`, not bare ruby)"

      recorded.each do |key|
        name = key.delete_prefix("BUNDLER_ORIG_")
        original = ENV[key]
        original = nil if original == Bundler::EnvironmentPreserver::INTENTIONALLY_NIL
        effective = overrides.key?(name) ? overrides[name] : ENV[name]

        expected = normalize(name, original)
        actual = normalize(name, effective)
        message = "#{name} would reach the subprocess as Bundler set it, not as it was before"

        expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
      end
    end

    def test_it_removes_bundlers_own_bookkeeping
      overrides = UnbundledEnv.unbundled_env_overrides

      ENV.keys.grep(/\ABUNDLER_ORIG_/).each do |key|
        assert overrides.key?(key) && overrides[key].nil?,
               "#{key} was left for the subprocess to inherit"
      end
    end

    def test_it_names_only_what_it_changes
      overrides = UnbundledEnv.unbundled_env_overrides

      overrides.each do |name, value|
        refute_equal ENV[name], value, "#{name} is in the override set without changing anything"
      end
    end

    private

    # Bundler removes its own entry from the search-path variables rather than replacing them
    # wholesale, which also normalises away the empty segment its own append left behind:
    # `"…/gem-rehash:"` comes back as `"…/gem-rehash"`. Same path, different string, and comparing
    # the strings would fail on a difference that reaches no subprocess. Only the list-valued
    # variables get this; `nil` stays distinguishable from empty everywhere, because `GEM_PATH=""`
    # leaking as if it were unset is one of the failures this is here to catch.
    SEARCH_PATHS = %w[PATH RUBYLIB GEM_PATH MANPATH].freeze

    def normalize(name, value)
      return value if value.nil? || !SEARCH_PATHS.include?(name)

      value.split(File::PATH_SEPARATOR).reject(&:empty?)
    end
  end
end

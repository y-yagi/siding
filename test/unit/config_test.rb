# frozen_string_literal: true

require "test_helper"

require "siding/staleness"
require "siding/client"

module Siding
  class ConfigTest < Minitest::Test
    LIB = File.expand_path("../../lib", __dir__)

    KNOWN_VARIABLES = %w[
      SIDING_BOOT_SECONDS
      SIDING_DISABLE
      SIDING_IDLE_TIMEOUT
      SIDING_LOG
      SIDING_RESOLUTION
      SIDING_REVISION
      SIDING_SERVER
      SIDING_TIMEOUT
      SIDING_WATCH
    ].freeze

    ESCAPE_HATCH_WORDS = /skip|no_?verif|no_?valid|unsafe|force|trust|trusted|assume/i

    def test_the_tool_reads_no_environment_variable_outside_its_documented_set
      found = library_sources.flat_map { |source| source.scan(/SIDING_[A-Z_]+/) }.uniq.sort

      assert_equal KNOWN_VARIABLES, found,
                   "the tool's environment surface changed; see the note above before widening it"
    end

    def test_the_opt_out_declines_acceleration_rather_than_validation
      client = Client.new(["rails", "runner", "1"], env: { "SIDING_DISABLE" => "1" }, cwd: Dir.pwd)

      assert_equal "SIDING_DISABLE is set", client.unusable_reason
    end

    def test_validation_accepts_no_parameter_that_would_switch_it_off
      names = Staleness.method(:validate).parameters.map { |(_, name)| name.to_s }

      assert_equal %w[manifest env], names
    end

    def test_the_server_validates_on_one_path_only
      call_sites = File.read(File.join(LIB, "siding", "server.rb")).scan(/Staleness\.validate/)

      assert_equal 1, call_sites.size
    end

    def test_no_public_entry_point_offers_an_escape_hatch
      offenders = escape_hatch_signatures

      assert_empty offenders,
                   "a parameter here would let a caller opt out of staleness validation"
    end

    def test_the_command_line_offers_no_such_command
      assert_empty CLI::MANAGEMENT_COMMANDS.grep(ESCAPE_HATCH_WORDS)
    end

    private

    def library_sources
      Dir.glob(File.join(LIB, "**", "*.rb")).sort.map { |path| File.read(path) }
    end

    def escape_hatch_signatures
      [Staleness, Siding, LoadManifest].flat_map do |mod|
        mod.methods(false).flat_map do |name|
          mod.method(name).parameters.filter_map do |(_kind, parameter)|
            "#{mod}.#{name}(#{parameter})" if parameter.to_s.match?(ESCAPE_HATCH_WORDS)
          end
        end
      end
    end
  end
end

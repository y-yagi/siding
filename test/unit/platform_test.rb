# frozen_string_literal: true

require "test_helper"

module Siding
  class PlatformTest < Minitest::Test
    WINDOWS_HOSTS = %w[mswin32 mingw32 x64-mingw-ucrt cygwin].freeze

    def setup
      Platform.instance_variable_set(:@wsl, nil)
      super
    end

    def teardown
      Platform.instance_variable_set(:@wsl, nil)
      super
    end

    def test_the_supported_platforms_are_supported
      Platform.stub(:host_os, "linux-gnu") do
        assert Platform.supported?
        assert_nil Platform.unsupported_reason
      end

      Platform.stub(:host_os, "darwin24") do
        assert Platform.supported?
        assert_nil Platform.unsupported_reason
      end
    end

    def test_windows_is_recognized_rather_than_merely_unsupported
      WINDOWS_HOSTS.each do |host_os|
        Platform.stub(:host_os, host_os) do
          assert Platform.windows?, "#{host_os} was not recognized as Windows"
          refute Platform.supported?, "#{host_os} was reported as supported"
        end
      end
    end

    def test_an_unsupported_platform_is_stated_rather_than_left_silent
      Platform.stub(:host_os, "mswin32") do
        reason = Platform.unsupported_reason

        refute_nil reason, "an unsupported platform reported no reason at all"
        assert_match(/Windows/, reason, "the reason did not name the platform")
        assert_match(/not supported/i, reason)
        assert_match(/unaccelerated/i, reason,
                     "the reason did not say what happens to the developer's command")
      end
    end

    def test_an_unrecognized_platform_names_itself_too
      Platform.stub(:host_os, "haiku") do
        reason = Platform.unsupported_reason

        refute_nil reason
        assert_match(/haiku/, reason, "the reason did not name the platform it was refusing")
        assert_match(/unaccelerated/i, reason)
      end
    end

    def test_wsl_is_treated_as_linux
      Platform.stub(:host_os, "linux-gnu") do
        assert Platform.supported?
        assert_match(/\ALinux( \(WSL\))?\z/, Platform.description)
      end
    end

    def test_nothing_is_read_from_a_per_project_configuration_file
      offenders = Dir.glob(File.join(__dir__, "../../lib/**/*.rb")).select do |path|
        File.read(path).match?(/\.siding(rc|\.ya?ml|\.toml)|config\/siding/)
      end

      assert_empty offenders.map { |path| File.basename(path) },
                   "the tool reads a per-project configuration file"
    end
  end
end

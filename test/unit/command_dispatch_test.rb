# frozen_string_literal: true

require "test_helper"

require "siding/client"

module Siding
  class CommandDispatchTest < Minitest::Test
    def test_rails_server_is_accelerated
      assert CLI.accelerated?(%w[rails server])
    end

    def test_rails_s_is_accelerated
      assert CLI.accelerated?(%w[rails s])
    end

    def test_rails_server_with_unrelated_flags_is_still_accelerated
      assert CLI.accelerated?(%w[rails server -p 4000])
    end

    def test_rails_server_daemonized_with_short_flag_is_not_accelerated
      refute CLI.accelerated?(%w[rails server -d])
    end

    def test_rails_server_daemonized_with_long_flag_is_not_accelerated
      refute CLI.accelerated?(%w[rails server --daemon])
    end

    def test_rails_s_daemonized_is_not_accelerated
      refute CLI.accelerated?(%w[rails s --daemon])
    end

    def test_rails_dev_cache_is_not_accelerated
      refute CLI.accelerated?(%w[rails dev:cache])
    end

    def test_rails_console_is_still_accelerated
      assert CLI.accelerated?(%w[rails console])
    end

    def test_rake_is_accelerated
      assert CLI.accelerated?(%w[rake -T])
    end

    def test_an_executable_outside_the_accelerated_set_is_not_accelerated
      refute CLI.accelerated?(%w[ruby -e 1])
    end
  end
end

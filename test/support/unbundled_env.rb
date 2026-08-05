# frozen_string_literal: true

require "bundler"

module Siding
  module UnbundledEnv
    module_function

    def unbundled_env_overrides
      @unbundled_env_overrides ||= begin
        unbundled = Bundler.unbundled_env
        (ENV.keys | unbundled.keys)
          .to_h { |name| [name, unbundled[name]] }
          .reject { |name, value| ENV[name] == value }
          .freeze
      end
    end
  end
end

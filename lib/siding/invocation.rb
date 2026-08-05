# frozen_string_literal: true

module Siding
  module Invocation
    RESOLUTION_KEY = "SIDING_RESOLUTION"
    REVISION_KEY = "SIDING_REVISION"
    BOOT_SECONDS_KEY = "SIDING_BOOT_SECONDS"

    RESOLUTIONS = %w[fresh reloaded_in_worker rebuild].freeze

    module_function

    def accelerated?(env = ENV) = !env[RESOLUTION_KEY].nil?
    def resolution(env = ENV) = env[RESOLUTION_KEY]
    def revision(env = ENV) = env[REVISION_KEY]

    def boot_seconds(env = ENV)
      value = env[BOOT_SECONDS_KEY]
      return nil if value.nil? || value.empty?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def to_h(env = ENV)
      {
        accelerated: accelerated?(env),
        resolution: resolution(env),
        revision: revision(env),
        boot_seconds: boot_seconds(env)
      }
    end
  end
end

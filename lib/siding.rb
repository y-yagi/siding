# frozen_string_literal: true

require_relative "siding/error"
require_relative "siding/version"
require_relative "siding/platform"
require_relative "siding/project_key"
require_relative "siding/runtime"
require_relative "siding/logger"
require_relative "siding/protocol"
require_relative "siding/life_cycle"
require_relative "siding/invocation"
require_relative "siding/boot_component"

module Siding
  class << self
    def accelerated? = Invocation.accelerated?
    def resolution = Invocation.resolution
    def revision = Invocation.revision
    def boot_seconds = Invocation.boot_seconds
    def invocation = Invocation.to_h

    def before_fork(name = nil, &block) = LifeCycle.before_fork(name, &block)
    def after_fork(name = nil, &block) = LifeCycle.after_fork(name, &block)

    def boot_component(*paths) = BootComponent.declare(*paths)
  end
end

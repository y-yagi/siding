ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Single worker, deliberately. Minitest's parallelization forks, and this suite exists to be
    # run *by* a forking preloader -- nested forking would make "which process wrote this" the
    # hardest question in every failure report, for no coverage in return.
    parallelize(workers: 1)

    # Add more helper methods to be used by all tests here...
  end
end

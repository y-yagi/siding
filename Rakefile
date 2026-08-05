# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

UNIT_GLOBS = ["test/test_*.rb", "test/unit/**/*_test.rb"].freeze
INTEGRATION_GLOBS = ["test/integration/**/*_test.rb"].freeze
PTY_GLOBS = ["test/pty/**/*_test.rb"].freeze

FIXTURE_APP = File.expand_path("test/fixtures/rails_app", __dir__)

Minitest::TestTask.create(:"test:unit") { |t| t.test_globs = UNIT_GLOBS }
Minitest::TestTask.create(:"test:integration") { |t| t.test_globs = INTEGRATION_GLOBS }
Minitest::TestTask.create(:"test:pty") { |t| t.test_globs = PTY_GLOBS }
Minitest::TestTask.create(:test) { |t| t.test_globs = UNIT_GLOBS + INTEGRATION_GLOBS }

# The soak exercise, as a task rather than a documented incantation.
SOAK_GLOBS = ["test/integration/soak_test.rb"].freeze
Minitest::TestTask.create(:"test:soak") { |t| t.test_globs = SOAK_GLOBS }

task :"soak:enable" do
  ENV["SIDING_SOAK"] ||= "1"
end

desc "Install the fixture application's bundle and prepare its databases"
task :"fixture:prepare" do
  Bundler.with_unbundled_env do
    unless system({}, "bundle", "check", chdir: FIXTURE_APP, out: File::NULL, err: File::NULL)
      run_in_fixture({}, "bundle", "install")
    end

    %w[development test].each do |rails_env|
      next if File.exist?(File.join(FIXTURE_APP, "storage", "#{rails_env}.sqlite3"))

      run_in_fixture({ "RAILS_ENV" => rails_env }, "bundle", "exec", "rails", "db:prepare")
    end
  end
end

def run_in_fixture(env, *command)
  return if system(env, *command, chdir: FIXTURE_APP)

  raise "#{command.join(' ')} failed in #{FIXTURE_APP}"
end

task test: :"fixture:prepare"
task "test:integration" => :"fixture:prepare"
task "test:pty" => :"fixture:prepare"
task "test:soak" => [:"soak:enable", :"fixture:prepare"]

task default: :test

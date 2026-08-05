# frozen_string_literal: true

module Siding
  module FixtureEdits
    def edit_fixture(relative_path)
      path = File.join(TestSupport::FIXTURE_APP, relative_path)
      original = File.exist?(path) ? File.binread(path) : nil
      fixture_originals[path] = original unless fixture_originals.key?(path)
      File.write(path, yield(original.to_s))
      path
    end

    def fixture_originals
      @fixture_originals ||= {}
    end

    def restore_fixtures
      fixture_originals.each do |path, original|
        original.nil? ? FileUtils.rm_f(path) : File.binwrite(path, original)
      end
      fixture_originals.clear
    end

    def teardown
      restore_fixtures
      super
    end
  end
end

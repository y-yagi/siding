# frozen_string_literal: true

require "test_helper"

class ProjectKeyTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("siding-project-key")
    @real_root = File.join(@tmpdir, "app")
    FileUtils.mkdir_p(@real_root)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
    super
  end

  def key(**overrides)
    Siding::ProjectKey.new(**{
      app_root: @real_root,
      uid: 1000,
      tool_version: "0.1.0",
      ruby_version: "3.4.0",
      app_env: "test"
    }.merge(overrides))
  end

  def test_symlinked_paths_collapse_to_one_key
    link = File.join(@tmpdir, "link-to-app")
    File.symlink(@real_root, link)

    assert_equal key.digest, key(app_root: link).digest
    assert_equal key, key(app_root: link)
  end

  def test_a_symlinked_parent_directory_also_collapses
    # The realistic version of the case above: developers symlink a projects directory, not an
    # individual checkout. Resolving only the last path component would miss this entirely.
    nested = File.join(@real_root, "nested", "checkout")
    FileUtils.mkdir_p(nested)
    link_root = File.join(@tmpdir, "linked-parent")
    File.symlink(@real_root, link_root)

    assert_equal key(app_root: nested).digest,
                 key(app_root: File.join(link_root, "nested", "checkout")).digest
  end

  def test_a_different_app_root_produces_a_different_key
    other = File.join(@tmpdir, "other-app")
    FileUtils.mkdir_p(other)

    refute_equal key.digest, key(app_root: other).digest
  end

  def test_a_different_uid_produces_a_different_key
    refute_equal key.digest, key(uid: 1001).digest
  end

  def test_a_different_tool_version_produces_a_different_key
    refute_equal key.digest, key(tool_version: "0.2.0").digest
  end

  def test_a_different_ruby_version_produces_a_different_key
    refute_equal key.digest, key(ruby_version: "3.3.0").digest
  end

  def test_a_different_app_environment_produces_a_different_key
    refute_equal key.digest, key(app_env: "development").digest
  end

  def test_the_digest_is_short_enough_for_a_socket_path
    assert_equal Siding::ProjectKey::DIGEST_LENGTH, key.digest.length
    assert_match(/\A[0-9a-f]+\z/, key.digest)
  end

  def test_for_reads_the_environment_and_the_running_process
    built = Siding::ProjectKey.for(@real_root, env: { "RAILS_ENV" => "test" })

    assert_equal File.realpath(@real_root), built.app_root
    assert_equal Process.uid, built.uid
    assert_equal Siding::VERSION, built.tool_version
    assert_equal RUBY_VERSION, built.ruby_version
    assert_equal "test", built.app_env
  end

  def test_the_app_environment_defaults_the_way_rails_does
    assert_equal "development", Siding::ProjectKey.app_env_from({})
    assert_equal "development", Siding::ProjectKey.app_env_from({ "RAILS_ENV" => "" })
    assert_equal "staging", Siding::ProjectKey.app_env_from({ "RACK_ENV" => "staging" })
    assert_equal "test", Siding::ProjectKey.app_env_from({ "RAILS_ENV" => "test", "RACK_ENV" => "development" })
  end

  def test_equal_keys_hash_alike
    # So a key can be used as a Hash key when the server tracks more than one project.
    assert_equal key.hash, key.hash
    assert_equal 1, [key, key].uniq.size
  end

  def test_the_label_names_the_application_a_developer_would_recognize
    assert_includes key.label, "app"
    assert_includes key.label, "test"
    assert_includes key.label, key.digest
  end
end

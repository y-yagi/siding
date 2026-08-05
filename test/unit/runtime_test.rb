# frozen_string_literal: true

require "test_helper"

class RuntimeTest < Minitest::Test
  def setup
    @tmpdir = Siding::ShortRuntimeDir.make
    @app_root = File.join(@tmpdir, "app")
    FileUtils.mkdir_p(@app_root)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
    super
  end

  def project_key(app_root: @app_root)
    Siding::ProjectKey.new(
      app_root: app_root, uid: Process.uid, tool_version: Siding::VERSION,
      ruby_version: RUBY_VERSION, app_env: "test"
    )
  end

  def runtime(root: File.join(@tmpdir, "state"), key: project_key)
    Siding::Runtime.new(project_key: key, root: root)
  end

  def test_xdg_runtime_dir_is_used_when_set
    root = Siding::Runtime.root_for({ "XDG_RUNTIME_DIR" => "/run/user/1000" })

    assert_equal "/run/user/1000/siding", root
  end

  def test_the_fallback_is_under_the_home_directory_when_xdg_is_unset
    # macOS has no XDG_RUNTIME_DIR convention, so this is the ordinary path there, not a corner.
    assert_equal File.join(Dir.home, ".local", "state", "siding"),
                 Siding::Runtime.root_for({})
    assert_equal File.join(Dir.home, ".local", "state", "siding"),
                 Siding::Runtime.root_for({ "XDG_RUNTIME_DIR" => "" })
  end

  def test_each_layout_path_lives_under_the_project_directory
    rt = runtime

    [rt.socket_path, rt.lock_path, rt.server_info_path, rt.boot_log_path, rt.log_path].each do |path|
      assert_equal rt.dir, File.dirname(path)
    end

    assert_equal 5, [rt.socket_path, rt.lock_path, rt.server_info_path, rt.boot_log_path,
                     rt.log_path].uniq.size
  end

  def test_different_projects_get_different_directories
    other_root = File.join(@tmpdir, "other-app")
    FileUtils.mkdir_p(other_root)

    refute_equal runtime.dir, runtime(key: project_key(app_root: other_root)).dir
  end

  def test_the_socket_path_stays_within_the_limit_for_a_deeply_nested_project
    deep = File.join(@tmpdir, *Array.new(12) { |i| "level-#{i}-with-a-fairly-long-name" })
    FileUtils.mkdir_p(deep)

    rt = runtime(root: "/run/user/1000/siding", key: project_key(app_root: deep))

    assert rt.socket_path_within_limit?,
           "socket path is #{rt.socket_path.bytesize} bytes: #{rt.socket_path}"
    assert_operator rt.socket_path.bytesize, :<=, Siding::Platform::UNIX_SOCKET_PATH_LIMIT - 1
  end

  def test_the_socket_path_length_is_independent_of_the_project_path_length
    deep = File.join(@tmpdir, *Array.new(20) { |i| "segment-#{i}" })
    FileUtils.mkdir_p(deep)

    shallow = runtime(root: "/run/user/1000/siding")
    nested = runtime(root: "/run/user/1000/siding", key: project_key(app_root: deep))

    assert_equal shallow.socket_path.bytesize, nested.socket_path.bytesize
  end

  def test_an_overlong_root_is_refused_rather_than_left_to_fail_at_bind_time
    rt = runtime(root: "/#{'x' * 120}")

    refute rt.socket_path_within_limit?
    error = assert_raises(Siding::Runtime::Unavailable) { rt.prepare }
    assert_match(/limit for Unix domain sockets/, error.message)
  end

  def test_prepare_creates_the_tree_owner_only
    rt = runtime.prepare

    assert File.directory?(rt.dir)
    assert_equal 0o700, File.stat(rt.dir).mode & 0o777
    assert_equal 0o700, File.stat(rt.root).mode & 0o777
    assert_equal Process.uid, File.stat(rt.dir).uid
  end

  def test_prepare_is_idempotent
    rt = runtime
    rt.prepare

    assert_equal rt.dir, rt.prepare.dir
    assert rt.prepared?
  end

  def test_a_directory_left_readable_by_others_is_tightened
    rt = runtime
    FileUtils.mkdir_p(rt.dir)
    File.chmod(0o755, rt.dir)

    rt.prepare

    assert_equal 0o700, File.stat(rt.dir).mode & 0o777
  end

  def test_an_unusable_root_reports_a_reason_instead_of_raising_at_the_call_site
    blocker = File.join(@tmpdir, "not-a-directory")
    File.write(blocker, "")

    rt = runtime(root: blocker)

    refute rt.prepared?
    refute_nil rt.unavailable_reason
  end

  def test_a_usable_runtime_reports_no_reason
    assert_nil runtime.unavailable_reason
  end

  def test_a_root_owned_by_another_user_is_refused
    foreign = ["/root", "/var/root"].find { |p| File.directory?(p) && File.stat(p).uid != Process.uid }
    skip "no directory owned by another user available" if foreign.nil?

    rt = runtime(root: foreign)

    refute_nil rt.unavailable_reason
  end
end

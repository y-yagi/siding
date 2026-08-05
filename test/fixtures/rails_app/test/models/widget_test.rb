# frozen_string_literal: true

require "test_helper"

# The trivial test the integration suite runs through the tool.
#
# Its job is not to test Widget. Its job is to be a command with an observable result, a real
# database connection, and a short runtime, so that tests of the *tool* can compare an
# accelerated run against an unaccelerated one byte for byte.
class WidgetTest < ActiveSupport::TestCase
  test "the boot marker is present" do
    # Asserts the boot-time require in config/application.rb actually ran. If this fails, the
    # manifest derived from the boot's $LOADED_FEATURES diff would silently lose a file.
    assert_equal "boot-marker-v1", BootMarker::VALUE
  end

  test "the initializer ran" do
    assert_equal "initializer-v1", FixtureMarker::MARKER
  end

  test "a widget can be created and read back" do
    widget = Widget.create!(name: "gadget")

    assert_equal "gadget", Widget.find(widget.id).name
    assert_equal "widget-v1", widget.shape
  end
end

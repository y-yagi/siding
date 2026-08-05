# frozen_string_literal: true

# An autoloaded, reloadable class backed by a real table.
#
# It is the fixture's `scope: reloadable` case: editing this file must be picked up by the next
# invocation without rebooting the application, which is the opposite requirement
# from lib/boot_marker.rb and config/initializers/fixture_marker.rb. The staleness matrix
# needs both sides to tell a working classifier from one that simply reboots on everything.
#
# It is backed by a table rather than being a plain class because forking a process that holds
# live database connections is the classic preloader corruption, and the suite needs something that
# actually opens one.
class Widget < ApplicationRecord
  # Edited by tests to assert reload behaviour. If a stale copy is ever served, the old string
  # is how the test sees it.
  SHAPE = "widget-v1"

  def shape
    SHAPE
  end
end

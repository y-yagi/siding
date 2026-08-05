# frozen_string_literal: true

# Boots the application the same way `bin/rails` does. An unaccelerated `bundle exec rspec` has
# nothing else that would load it, and an accelerated `siding rspec` needs this to be a no-op --
# which it is, since the worker forks from a server that already required this file.
require_relative "../config/environment"

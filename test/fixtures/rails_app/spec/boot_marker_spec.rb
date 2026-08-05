# frozen_string_literal: true

# The trivial spec the integration suite runs through the tool via `rspec`.
#
# Its job is not to test BootMarker. Its job is to be a command with an observable, deterministic
# result in an application that is already booted, so tests of the *tool* can assert that rspec is
# served by the same warm application as every other accelerated executable -- and, like
# test/models/widget_test.rb does for `siding test`, needs nothing from a spec_helper to do it.
RSpec.describe BootMarker do
  it "is present in the booted application" do
    expect(BootMarker::VALUE).to eq("boot-marker-v1")
  end
end

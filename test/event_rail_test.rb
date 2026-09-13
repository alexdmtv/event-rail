require "test_helper"

class EventRailTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert EventRail::VERSION
  end

  test "implementation constants are private and namespaced" do
    assert_raises(NameError) { EventRail::Internal }

    %i[AttributeRecord PortableValue Timestamp Types].each do |constant_name|
      refute EventRail.const_defined?(constant_name, false)
    end

    internal = EventRail.const_get(:Internal, false)
    %i[AttributeRecord ContractIndex PortableValue Timestamp Types].each do |constant_name|
      assert internal.const_defined?(constant_name, false)
    end
  end
end

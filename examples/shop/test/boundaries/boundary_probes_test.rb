require "test_helper"
require "open3"

# The README's structural claims, as tests. Each probe plants a file that breaks one rule into
# a copy of the application, packwerk checks the copy, and the test asserts the rule caught
# it. The real application must stay clean; CI runs packwerk on it separately.
class BoundaryProbesTest < ActiveSupport::TestCase
  PROBES = {
    # Orders may call Catalog, but not reach past its public API.
    private_access: [ "engines/orders/app/models/orders/probe_private_access.rb", <<~RUBY ],
      module Orders
        module ProbePrivateAccess
          def self.call = Catalog::Product.first
        end
      end
    RUBY

    # Catalog never declared Orders.
    undeclared_dependency: [ "engines/catalog/app/models/catalog/probe_undeclared_dependency.rb", <<~RUBY ],
      module Catalog
        module ProbeUndeclaredDependency
          def self.call = Orders::Api.recent
        end
      end
    RUBY

    # Simulation depends on Orders, and Orders on Payments -- which gives Simulation nothing.
    non_transitive: [ "engines/simulation/app/models/simulation/probe_non_transitive.rb", <<~RUBY ],
      module Simulation
        module ProbeNonTransitive
          def self.call = Payments::Api.payment("x")
        end
      end
    RUBY

    # Payments sits below Orders and must not call up into it.
    upward_call: [ "engines/payments/app/models/payments/probe_upward_call.rb", <<~RUBY ],
      module Payments
        module ProbeUpwardCall
          def self.call = Orders::Api.recent
        end
      end
    RUBY

    # A published event is a separate package that depends on nothing, not even its module.
    event_reaching_in: [ "engines/orders/app/public/orders/events/probe_reaching_in.rb", <<~RUBY ],
      module Orders
        module Events
          module ProbeReachingIn
            def self.call = Orders::Order.first
          end
        end
      end
    RUBY

    # An event outside a module's public folder is internal to it...
    internal_event: [ "engines/orders/app/events/orders/probe_internal_event.rb", <<~RUBY ],
      module Orders
        class ProbeInternalEvent < EventRail::Event
          event_type "orders.probe_internal_event"
          version 1
          default_source "shop.orders"
          attribute :order_id, :string
        end
      end
    RUBY

    # ...so another module cannot subscribe to it.
    eavesdropping: [ "engines/notifications/app/jobs/notifications/probe_eavesdrop_job.rb", <<~RUBY ]
      module Notifications
        class ProbeEavesdropJob < ApplicationJob
          subscribes_to Orders::ProbeInternalEvent

          def perform(event) = nil
        end
      end
    RUBY
  }.freeze

  Violation = Data.define(:path, :message)

  class << self
    def copy
      @copy ||= Dir.mktmpdir("shop-boundaries").tap do |dir|
        Rails.root.children.reject { |child| %w[tmp log storage .bundle].include?(child.basename.to_s) }.each { |child| FileUtils.cp_r(child, dir) }
        PROBES.each_value do |path, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), source)
        end
        Minitest.after_run { FileUtils.rm_rf(dir) }
      end
    end

    def violations
      @violations ||= packwerk("check").scan(/^(\S+\.rb):\d+:\d+\n(.+)$/).map { |path, message| Violation.new(path: path, message: message) }
    end

    def packwerk(command)
      output, = Open3.capture2e({ "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s }, RbConfig.ruby, "bin/packwerk", command, chdir: copy)
      output.gsub(/\e\[[0-9;]*m/, "")
    end
  end

  test "private access is reported" do
    assert_violation :private_access, "Privacy violation: '::Catalog::Product' is private to 'engines/catalog'"
  end

  test "an undeclared dependency is reported" do
    assert_violation :undeclared_dependency, "Dependency violation: ::Orders::Api belongs to 'engines/orders', but 'engines/catalog' does not specify a dependency"
  end

  test "dependencies are not transitive" do
    assert_violation :non_transitive, "Dependency violation: ::Payments::Api belongs to 'engines/payments', but 'engines/simulation' does not specify a dependency"
  end

  test "a lower module cannot call upward" do
    assert_violation :upward_call, "Dependency violation: ::Orders::Api belongs to 'engines/orders', but 'engines/payments' does not specify a dependency"
  end

  test "a published event cannot reach into its own module" do
    assert_violation :event_reaching_in, "Privacy violation: '::Orders::Order' is private to 'engines/orders'"
    assert_violation :event_reaching_in, "Dependency violation: ::Orders::Order belongs to 'engines/orders', but 'engines/orders/app/public/orders/events'"
  end

  test "another module cannot subscribe to an internal event" do
    assert_violation :eavesdropping, "Privacy violation: '::Orders::ProbeInternalEvent' is private to 'engines/orders'"
  end

  test "only the probes are reported" do
    assert_equal PROBES.values.map(&:first).sort & self.class.violations.map(&:path), self.class.violations.map(&:path).uniq.sort
  end

  test "a declared cycle is rejected" do
    package = File.join(self.class.copy, "engines/payments/package.yml")
    original = File.read(package)
    File.write(package, original + "  - engines/orders\n")

    output = self.class.packwerk("validate")
    assert_match "circular dependencies", output
    cycle = output[/^\s*- (engines\/.+)$/, 1].to_s.split(" → ")
    assert_equal %w[ engines/orders engines/payments ], cycle.uniq.sort
  ensure
    File.write(package, original) if original
  end

  private
    def assert_violation(probe, message)
      path = PROBES.fetch(probe).first
      assert self.class.violations.any? { |violation| violation.path == path && violation.message.start_with?(message) },
        "expected #{path} to be reported with: #{message}\nreported: #{self.class.violations.map { |violation| "#{violation.path}: #{violation.message}" }.join("\n")}"
    end
end

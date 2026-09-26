require "test_helper"
require "open3"

# Each module ships its own bin/rails, so Rails' generators run inside a module write into
# that module: its namespace, its folders, its table prefix. Run in a copy of the
# application, so nothing generated lands in the real one.
class ModuleGeneratorsTest < ActiveSupport::TestCase
  test "a model generated inside a module lands in the module under its namespace" do
    Dir.mktmpdir("shop-generators") do |copy|
      Rails.root.children.reject { |child| %w[tmp log storage .bundle].include?(child.basename.to_s) }.each { |child| FileUtils.cp_r(child, copy) }
      FileUtils.mkdir_p([ File.join(copy, "tmp"), File.join(copy, "log") ])
      engine = File.join(copy, "engines/payments")

      output, status = Open3.capture2e({ "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s, "RAILS_ENV" => "development" },
        RbConfig.ruby, "bin/rails", "generate", "model", "Probe", "name:string", chdir: engine)

      assert status.success?, output
      assert_match(/module Payments\n  class Probe < ApplicationRecord/, File.read(File.join(engine, "app/models/payments/probe.rb")))
      migration = Dir[File.join(engine, "db/migrate/*_create_payments_probes.rb")].sole
      assert_match(/create_table :payments_probes/, File.read(migration))
      assert_not File.exist?(File.join(copy, "app/models/probe.rb")), "nothing is generated into the host"
    end
  end
end

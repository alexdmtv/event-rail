require "test_helper"
require "prism"

# Tests keep to the modules' boundaries as the code does, so a module can change inside without
# breaking anyone else's tests. Packwerk can't check this: test support sits outside the load
# paths, and a job or a table named in a string is no constant. These checks read the tests with
# Ruby's own parser. They catch a boundary crossed by accident, not one crossed on purpose:
# `send`, `const_get`, `constantize` and names built from pieces get past them.
class TestBoundaries
  DRAINS = %i[ perform_enqueued_jobs work_off_queue ].freeze

  def initialize(root)
    @root = Pathname(root)
    @trees = {}
    @jobs = {}
  end

  def modules = @modules ||= Dir[@root.join("engines/*/package.yml")].map { |path| File.basename(File.dirname(path)) }.sort

  # A module's tests use the test support only of modules it depends on.
  def test_support
    modules.flat_map do |name|
      allowed = [ name, *dependencies(name) ].map(&:camelize)
      module_files(name).flat_map do |file|
        constants(file).filter_map { |constant| constant[/\A(\w+)::TestSupport\b/, 1] }.uniq
          .select { |owner| modules.include?(owner.underscore) && allowed.exclude?(owner) }
          .map { |owner| "#{relative(file)} uses #{owner}::TestSupport, but #{name} doesn't depend on #{owner.underscore}" }
      end
    end
  end

  # A module's test-only classes, and anything inside them, serve its own tests alone.
  def test_only_classes
    modules.flat_map do |name|
      private_names = test_only_class_names(name)
      files_outside(name).flat_map do |file|
        constants(file).select { |constant| private_names.any? { |private_name| constant == private_name || constant.start_with?("#{private_name}::") } }
          .uniq.map { |constant| "#{relative(file)} uses #{constant}" }
      end
    end
  end

  # A module's jobs are named only in its own tests, and in a flow test that makes one fail on
  # purpose: as the job given to failing_runs, and in that test, to check the fault's effect.
  def job_names
    modules.excluding("platform").flat_map do |name|
      short_names = jobs(name).map(&:demodulize)
      files_outside(name).flat_map do |file|
        others = short_names - owner(file).then { |owner| owner ? jobs(owner).map(&:demodulize) : [] }
        named = strings(file).flat_map do |string|
          string.scan(/\b#{name.camelize}::\w*Job\b/) + others.select { |short| string.match?(/(?<!::)\b#{short}\b/) }
        end
        named.uniq.map { |job| "#{relative(file)} names #{job}" }
      end
    end
  end

  # A module's fixtures, and its tables in SQL, are used by its own tests alone. Platform's table
  # is everyone's.
  def fixtures_and_tables
    modules.flat_map do |name|
      accessors = fixture_accessors(name)
      own_tables = name == "platform" ? [] : tables.select { |table| table.start_with?("#{name}_") }
      files_outside(name).flat_map do |file|
        fixtures = calls(file).map(&:name).select { |called| accessors.include?(called) }
        sql = strings(file, exempt_faults: false).flat_map { |string| own_tables.select { |table| string.match?(/\b#{table}\b/) } }
        (fixtures + sql).map(&:to_s).uniq.map { |used| "#{relative(file)} uses #{used}" }
      end
    end
  end

  # Outside the flows, a test runs only the jobs it names, and names at least one: never the whole
  # queue, so another module's subscriber can't run in it. Platform's own tests run the jobs they
  # define.
  def drains
    files = modules.excluding("platform").flat_map { |name| module_files(name) } +
      Dir[@root.join("test/**/*.rb")].sort.reject { |file| flow_test?(file) }
    files.flat_map do |file|
      calls(file).select { |call| DRAINS.include?(call.name) && !names_jobs?(call) }
        .map { |call| "#{relative(file)}:#{call.location.start_line} runs #{call.name} without naming its jobs" }
    end
  end

  private
    def dependencies(name)
      Array(YAML.load_file(@root.join("engines", name, "package.yml"))["dependencies"]).filter_map { |path| path[%r{\Aengines/(\w+)\z}, 1] }
    end

    def module_files(name) = Dir[@root.join("engines", name, "test/**/*.rb")].sort
    def files_outside(name) = Dir[@root.join("test/**/*.rb")].sort + modules.excluding(name).flat_map { |other| module_files(other) }
    def owner(file) = file[%r{/engines/(\w+)/}, 1]
    def flow_test?(file) = file.start_with?(@root.join("test/flows/").to_s)
    def relative(file) = Pathname(file).relative_path_from(@root).to_s

    def jobs(name)
      @jobs[name] ||= Dir[@root.join("engines", name, "app/jobs/**/*.rb")].flat_map { |file| declarations(file) }.grep(/Job\z/) - [ "#{name.camelize}::ApplicationJob" ]
    end

    def tables = @tables ||= @root.join("db/schema.rb").then { |schema| schema.exist? ? schema.read.scan(/create_table "(\w+)"/).flatten : [] }

    # Classes, modules and constants a module's test support declares beside TestSupport, such as
    # a fake, by their full names. What sits inside TestSupport is part of it.
    def test_only_class_names(name)
      Dir[@root.join("engines", name, "test/support/**/*.rb")].flat_map { |file| declarations(file) }.uniq
        .select { |declared| declared.start_with?("#{name.camelize}::") }
        .reject { |declared| declared.match?(/(\A|::)TestSupport(::|\z)/) }
    end

    def fixture_accessors(name)
      root = @root.join("engines", name, "test/fixtures")
      Dir[root.join("**/*.yml")].map { |file| Pathname(file).relative_path_from(root).sub_ext("").to_s.tr("/", "_").to_sym }
    end

    # only: given, and neither nil nor an empty list; a splat (**options) can't be read, so it doesn't count.
    def names_jobs?(call)
      keywords = call.arguments&.arguments.to_a.grep(Prism::KeywordHashNode).flat_map(&:elements)
      only = keywords.grep(Prism::AssocNode).find { |element| element.key.try(:unescaped) == "only" }
      only && !only.value.is_a?(Prism::NilNode) && !(only.value.is_a?(Prism::ArrayNode) && only.value.elements.empty?)
    end

    def tree(file) = @trees[file] ||= Prism.parse_file(file).value
    def nodes(node) = [ node ] + node.compact_child_nodes.flat_map { |child| nodes(child) }
    def calls(file) = nodes(tree(file)).grep(Prism::CallNode)

    # Constant references by full name, without a leading ::, the lexical namespace included, so
    # `ScriptedGateway` inside a reopened `module Payments` is Payments::ScriptedGateway.
    def constants(file, node = tree(file), namespace = [])
      case node
      when Prism::ClassNode, Prism::ModuleNode
        inner = namespace + [ full_name(node.constant_path) ]
        constants(file, node.constant_path, namespace) + node.compact_child_nodes.flat_map { |child| constants(file, child, inner) }
      when Prism::ConstantPathNode
        [ full_name(node) ]
      when Prism::ConstantReadNode
        (0..namespace.size).map { |depth| [ *namespace.first(depth), node.name ].join("::") }
      else
        node.compact_child_nodes.flat_map { |child| constants(file, child, namespace) }
      end
    end

    def declarations(file, node = tree(file), namespace = [])
      case node
      when Prism::ClassNode, Prism::ModuleNode
        inner = namespace + [ full_name(node.constant_path) ]
        [ inner.join("::") ] + node.compact_child_nodes.flat_map { |child| declarations(file, child, inner) }
      when Prism::ConstantWriteNode then [ [ *namespace, node.name ].join("::") ]
      when Prism::ConstantPathWriteNode then [ [ *namespace, full_name(node.target) ].join("::") ]
      else node.compact_child_nodes.flat_map { |child| declarations(file, child, namespace) }
      end
    end

    def full_name(node)
      node.full_name.delete_prefix("::")
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      ""
    end

    # Every string the file writes, however quoted: "…", '…', %w[…], heredocs, symbols, regexps,
    # and the fixed parts of an interpolated one. In a flow test, the job given to failing_runs,
    # and strings equal to it in that test, are left out unless exempt_faults is false.
    def strings(file, exempt_faults: flow_test?(file))
      exemptions = exempt_faults ? fault_exemptions(tree(file)) : { arguments: [], tests: {} }
      collect_strings(tree(file), exemptions, [])
    end

    def collect_strings(node, exemptions, allowed)
      return [] if exemptions[:arguments].include?(node)

      allowed += exemptions[:tests].fetch(node, [])
      own = case node
      when Prism::StringNode, Prism::SymbolNode, Prism::RegularExpressionNode, Prism::XStringNode then [ node.unescaped ]
      when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode, Prism::InterpolatedRegularExpressionNode
        [ node.parts.map { |part| part.respond_to?(:unescaped) ? part.unescaped : "" }.join ]
      else []
      end
      own.select(&:valid_encoding?).reject { |string| allowed.include?(string) } + node.compact_child_nodes.flat_map { |child| collect_strings(child, exemptions, allowed) }
    end

    # The literal jobs given to failing_runs, wherever the call is, and per test, the names that
    # test may repeat. A test that picks the job at run time names none.
    def fault_exemptions(root)
      faults = nodes(root).grep(Prism::CallNode).select { |call| call.name == :failing_runs && call.arguments&.arguments&.first.is_a?(Prism::StringNode) }
      tests = nodes(root).grep(Prism::CallNode).select { |call| call.name == :test && call.receiver.nil? && call.block }
      {
        arguments: faults.map { |call| call.arguments.arguments.first },
        tests: tests.to_h { |test| [ test.block, faults.select { |call| nodes(test.block).include?(call) }.map { |call| call.arguments.arguments.first.unescaped } ] }
      }
    end
end

class TestBoundariesTest < ActiveSupport::TestCase
  %i[ test_support test_only_classes job_names fixtures_and_tables drains ].each do |check|
    test "the shop's tests keep to the boundaries: #{check.to_s.humanize(capitalize: false)}" do
      assert_empty TestBoundaries.new(Rails.root).public_send(check)
    end
  end

  # Each check, run on a small planted tree, reports what it should: a check that can't fail
  # proves nothing.
  test "every check reports what was planted to break it" do
    Dir.mktmpdir do |root|
      plant(root)
      boundaries = TestBoundaries.new(root)

      assert_equal [ "engines/gamma/test/gamma/probe_test.rb uses Alpha::TestSupport, but gamma doesn't depend on alpha" ], boundaries.test_support
      assert_equal %w[ Alpha::Fake Alpha::Fake::Part Alpha::Helper ].map { |constant| "engines/gamma/test/gamma/probe_test.rb uses #{constant}" }, boundaries.test_only_classes.sort
      assert_equal [ "engines/gamma/test/gamma/probe_test.rb names Alpha::ShipJob", "engines/gamma/test/gamma/probe_test.rb names ShipJob", "test/flows/probe_test.rb names Alpha::PackJob" ],
        boundaries.job_names.sort
      assert_equal [ "engines/gamma/test/gamma/probe_test.rb uses alpha_items" ], boundaries.fixtures_and_tables
      assert_equal [ "engines/gamma/test/gamma/probe_test.rb:9", "engines/gamma/test/gamma/probe_test.rb:10", "engines/gamma/test/gamma/probe_test.rb:11", "test/probe_test.rb:1" ],
        boundaries.drains.map { |offence| offence[/\A\S+:\d+/] }
    end
  end

  private
    def plant(root)
      write = ->(path, content) { FileUtils.mkdir_p(File.dirname(File.join(root, path))); File.write(File.join(root, path), content) }
      write.("engines/platform/package.yml", "dependencies: []\n")
      write.("engines/alpha/package.yml", "dependencies:\n  - engines/platform\n")
      write.("engines/gamma/package.yml", "dependencies:\n  - engines/platform\n")
      write.("db/schema.rb", %(create_table "alpha_items", force: :cascade do |t|\nend\n))
      write.("engines/alpha/app/jobs/alpha/ship_job.rb", "module Alpha\n  class ShipJob < ApplicationJob\n  end\nend\n")
      write.("engines/alpha/app/jobs/alpha/pack_job.rb", "class Alpha::PackJob < Alpha::ApplicationJob\nend\n")
      write.("engines/alpha/test/fixtures/alpha/items.yml", "one:\n  name: one\n")
      write.("engines/alpha/test/support/alpha/test_support.rb", <<~RUBY)
        module Alpha
          module TestSupport
            Inner = 1
          end
          Helper = Data.define(:value)
        end
        class Alpha::Fake
          class Part; end
        end
      RUBY
      write.("engines/gamma/test/gamma/probe_test.rb", <<~RUBY)
        Alpha::TestSupport.one
        ::Alpha::Fake.new
        Alpha::Helper.new(value: 1)
        Alpha::Fake::Part
        Alpha::TestSupport::Inner
        names = %w[ Alpha::ShipJob ]
        name = "ShipJob"
        alpha_items(:one); sql = "SELECT * FROM alpha_items"
        work_off_queue
        perform_enqueued_jobs(only: [])
        perform_enqueued_jobs(**options)
        perform_enqueued_jobs(only: Gamma::OwnJob)
      RUBY
      write.("test/flows/probe_test.rb", <<~RUBY)
        class ProbeTest
          test "a fault" do
            failing_runs("Alpha::ShipJob", 1) { assert_equal [ "Alpha::ShipJob" ], [] }
          end

          test 'a fault chosen at run time' do
            failing_runs(job, 1) { "Alpha::PackJob" }
          end
        end
      RUBY
      write.("test/probe_test.rb", "work_off_queue\n")
    end
end

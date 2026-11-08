require "test_helper"
require "prism"

# Tests keep to the modules' boundaries as the code does, so a module can change inside without
# breaking anyone else's tests. Packwerk can't check this: test support sits outside the load
# paths, and a job named in a string is no constant. These checks read the tests with Ruby's own
# parser. They catch a boundary crossed by accident, not one crossed on purpose: `send`,
# `const_get` and `constantize` get past them.
class TestBoundariesTest < ActiveSupport::TestCase
  MODULES = Dir[Rails.root.join("engines/*/package.yml")].map { |path| File.basename(File.dirname(path)) }.sort
  DRAINS = %i[ perform_enqueued_jobs work_off_queue perform_due_jobs ].freeze

  test "a module's tests use the test support only of modules it depends on" do
    offences = MODULES.flat_map do |name|
      allowed = [ name, *dependencies(name) ].map(&:camelize)
      module_files(name).flat_map do |file|
        constants(file).filter_map { |constant| constant[/\A(\w+)::TestSupport\b/, 1] }.uniq
          .select { |owner| MODULES.include?(owner.underscore) && allowed.exclude?(owner) }
          .map { |owner| "#{relative(file)} uses #{owner}::TestSupport, but #{name} doesn't depend on #{owner.underscore}" }
      end
    end

    assert_empty offences
  end

  test "a module's test-only classes are used by its own tests alone" do
    offences = MODULES.flat_map do |name|
      private_names = test_only_classes(name)
      next [] if private_names.empty?

      files_outside(name).flat_map do |file|
        constants(file).select { |constant| private_names.include?(constant) }.uniq.map { |constant| "#{relative(file)} uses #{constant}" }
      end
    end

    assert_empty offences
  end

  test "a module's jobs are named only in its own tests, and in a flow test that makes one fail on purpose" do
    offences = MODULES.excluding("platform").flat_map do |name|
      job_name = /\b#{name.camelize}::\w*Job\b/
      files_outside(name).flat_map do |file|
        strings(file, outside_faults: flow_test?(file)).flat_map { |string| string.valid_encoding? ? string.scan(job_name) : [] }.uniq.map { |job| "#{relative(file)} names #{job}" }
      end
    end

    assert_empty offences
  end

  test "a module's fixtures are used by its own tests alone" do
    offences = MODULES.flat_map do |name|
      accessors = fixture_accessors(name)
      next [] if accessors.empty?

      files_outside(name).flat_map do |file|
        calls(file).map(&:name).select { |called| accessors.include?(called) }.uniq.map { |called| "#{relative(file)} uses #{called}" }
      end
    end

    assert_empty offences
  end

  # Platform is the exception: it depends on nothing, and its tests' jobs are its own.
  test "a module's tests run only the jobs they name" do
    offences = MODULES.excluding("platform").flat_map do |name|
      Dir[Rails.root.join("engines", name, "test/**/*_test.rb")].sort.flat_map do |file|
        calls(file).select { |call| DRAINS.include?(call.name) && !names_jobs?(call) }
          .map { |call| "#{relative(file)}:#{call.location.start_line} runs #{call.name} without naming the jobs (only:)" }
      end
    end

    assert_empty offences
  end

  private
    def dependencies(name)
      Array(YAML.load_file(Rails.root.join("engines", name, "package.yml"))["dependencies"])
        .filter_map { |path| path[%r{\Aengines/(\w+)\z}, 1] }
    end

    def module_files(name) = Dir[Rails.root.join("engines", name, "test/**/*.rb")].sort
    def files_outside(name) = Dir[Rails.root.join("test/**/*.rb")].sort + MODULES.excluding(name).flat_map { |other| module_files(other) }
    def flow_test?(file) = file.start_with?(Rails.root.join("test/flows/").to_s)

    # Classes and modules a module's test support declares beside TestSupport, such as a fake, by
    # their full names. What sits inside TestSupport is part of it.
    def test_only_classes(name)
      Dir[Rails.root.join("engines", name, "test/support/**/*.rb")].flat_map { |file| declarations(file) }.uniq
        .reject { |declared| declared.match?(/(\A|::)TestSupport(::|\z)/) || declared == name.camelize }
    end

    # Fixture accessors a module's fixtures give every test: catalog/products.yml is catalog_products.
    def fixture_accessors(name)
      root = Rails.root.join("engines", name, "test/fixtures")
      Dir[root.join("**/*.yml")].map { |file| Pathname(file).relative_path_from(root).sub_ext("").to_s.tr("/", "_").to_sym }
    end

    def names_jobs?(call) = call.arguments&.arguments.to_a.any? { |argument| argument.is_a?(Prism::KeywordHashNode) && argument.elements.any? { |element| element.key.try(:unescaped) == "only" } }

    def tree(file) = Prism.parse_file(file).value

    def calls(file) = nodes(tree(file)).grep(Prism::CallNode)

    # Constant references by full name, the lexical namespace included, so `ScriptedGateway` inside
    # a reopened `module Payments` is Payments::ScriptedGateway.
    def constants(file, node = tree(file), namespace = [])
      case node
      when Prism::ClassNode, Prism::ModuleNode
        inner = namespace + [ node.constant_path.full_name ]
        constants(file, node.constant_path, namespace) + node.compact_child_nodes.flat_map { |child| constants(file, child, inner) }
      when Prism::ConstantPathNode
        [ node.full_name ]
      when Prism::ConstantReadNode
        (0..namespace.size).map { |depth| [ *namespace.first(depth), node.name ].join("::") }
      else
        node.compact_child_nodes.flat_map { |child| constants(file, child, namespace) }
      end
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      []
    end

    def declarations(file, node = tree(file), namespace = [])
      return node.compact_child_nodes.flat_map { |child| declarations(file, child, namespace) } unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

      inner = namespace + [ node.constant_path.full_name ]
      [ inner.join("::") ] + node.compact_child_nodes.flat_map { |child| declarations(file, child, inner) }
    end

    # Every string the file writes, however quoted: "…", '…', %w[…], heredocs, symbols, regexps.
    # An interpolated one counts when its fixed parts already say a module and a job
    # ("Orders::#{x}Job"). outside_faults leaves out, in a test that calls failing_runs, the job it
    # makes fail; all of them when the test picks the job at run time.
    def strings(file, outside_faults: false, node: tree(file), allowed: [])
      if outside_faults && fault_test?(node)
        targets = fault_targets(node)
        return [] if targets.nil?

        allowed += targets
      end

      own = case node
      when Prism::StringNode, Prism::SymbolNode, Prism::RegularExpressionNode, Prism::XStringNode then [ node.unescaped ]
      when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode, Prism::InterpolatedRegularExpressionNode
        [ node.parts.map { |part| part.respond_to?(:unescaped) ? part.unescaped : "" }.join ]
      else []
      end
      own.reject { |string| allowed.include?(string) } + node.compact_child_nodes.flat_map { |child| strings(file, outside_faults:, node: child, allowed:) }
    end

    def fault_test?(node) = node.is_a?(Prism::CallNode) && node.name == :test && node.receiver.nil? && node.block && fault_calls(node).any?
    def fault_calls(test) = nodes(test.block).select { |inner| inner.is_a?(Prism::CallNode) && inner.name == :failing_runs }

    # The jobs a fault test names in failing_runs, or nil when one is chosen at run time.
    def fault_targets(test)
      first_arguments = fault_calls(test).map { |call| call.arguments&.arguments&.first }
      first_arguments.all?(Prism::StringNode) ? first_arguments.map(&:unescaped) : nil
    end

    def nodes(node) = [ node ] + node.compact_child_nodes.flat_map { |child| nodes(child) }

    def relative(file) = Pathname(file).relative_path_from(Rails.root).to_s
end

require "test_helper"

# Tests keep to the modules' boundaries as the code does, so a module can change inside without
# breaking anyone else's tests. Packwerk can't check this: test support sits outside the load
# paths, and a job named in a string is no constant.
class TestBoundariesTest < ActiveSupport::TestCase
  MODULES = Dir[Rails.root.join("engines/*/package.yml")].map { |path| File.basename(File.dirname(path)) }.sort

  test "a module's tests use the test support only of modules it depends on" do
    offences = MODULES.flat_map do |name|
      allowed = [ name, *dependencies(name) ]
      test_files(Rails.root.join("engines", name, "test")).flat_map do |file|
        File.read(file).scan(/\b(#{module_names})::TestSupport\b/).flatten.uniq.map(&:underscore)
          .reject { |used| allowed.include?(used) }
          .map { |used| "#{relative(file)} uses #{used.camelize}::TestSupport, but #{name} doesn't depend on #{used}" }
      end
    end

    assert_empty offences
  end

  test "a module's test-only classes are used by its own tests alone" do
    offences = MODULES.flat_map do |name|
      private_names = test_only_classes(name).map { |constant| "#{name.camelize}::#{constant}" }
      next [] if private_names.empty?

      (test_files(Rails.root.join("test")) + MODULES.excluding(name).flat_map { |other| test_files(Rails.root.join("engines", other, "test")) }).flat_map do |file|
        File.read(file).scan(/\b(?:#{private_names.map { |constant| Regexp.escape(constant) }.join("|")})\b/).uniq.map { |used| "#{relative(file)} uses #{used}" }
      end
    end

    assert_empty offences
  end

  # A flow test may name one to make it fail on purpose, with Platform's fault helpers.
  test "a module's jobs are named only in its own tests and in flow tests" do
    offences = MODULES.flat_map do |name|
      others = test_files(Rails.root.join("test")).reject { |file| file.start_with?(Rails.root.join("test/flows").to_s) } +
        MODULES.excluding(name).flat_map { |other| test_files(Rails.root.join("engines", other, "test")) }
      others.flat_map do |file|
        File.read(file).scan(/["']#{name.camelize}::\w+Job["']/).uniq.map { |job| "#{relative(file)} names #{job}" }
      end
    end

    assert_empty offences
  end

  private
    def module_names = MODULES.map(&:camelize).join("|")

    def dependencies(name)
      Array(YAML.load_file(Rails.root.join("engines", name, "package.yml"))["dependencies"])
        .filter_map { |path| path[%r{\Aengines/(\w+)\z}, 1] }
    end

    def test_files(directory) = Dir[File.join(directory, "**/*.rb")].sort

    # Classes and modules a module's test support defines beside TestSupport, such as a fake.
    def test_only_classes(name)
      Dir[Rails.root.join("engines", name, "test/support/**/*.rb")]
        .flat_map { |file| File.read(file).scan(/^  (?:class|module) (\w+)/).flatten }
        .uniq - [ "TestSupport" ]
    end

    def relative(file) = Pathname(file).relative_path_from(Rails.root).to_s
end

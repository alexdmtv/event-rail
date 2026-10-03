module Platform
  # Every violation at once. A field is in the caller's terms and Active Model's notation
  # (items[1].quantity); a code is stable for clients to act on.
  class InvalidInput < StandardError
    include InvalidArgument

    Violation = Data.define(:field, :code, :message)

    attr_reader :violations

    # Takes the attribute names of the validation's errors as the fields.
    def self.from(errors)
      new(errors.map { |error| Violation.new(field: error.attribute.to_s, code: error.type.to_s, message: error.message) })
    end

    def initialize(violations)
      @violations = violations
      super(violations.map { |violation| "#{violation.field} #{violation.message}" }.join("; "))
    end
  end
end

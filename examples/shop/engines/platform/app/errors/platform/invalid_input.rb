module Platform
  # Input refused, with every reason at once: each violation names the field it concerns, in the
  # caller's own terms (customer.email, items.MUG -- a dot between the levels of the input), with
  # a stable code a client can act on and a message a person can read. A module raises it for
  # input it checks as a whole, so a form hears about all its mistakes in one answer, not one at
  # a time.
  class InvalidInput < StandardError
    include InvalidArgument

    Violation = Data.define(:field, :code, :message)

    attr_reader :violations

    # From the errors of an ActiveModel validation, whose attribute names are the fields.
    def self.from(errors)
      new(errors.map { |error| Violation.new(field: error.attribute.to_s, code: error.type.to_s, message: error.message) })
    end

    def initialize(violations)
      @violations = violations
      super(violations.map { |violation| "#{violation.field} #{violation.message}" }.join("; "))
    end
  end
end

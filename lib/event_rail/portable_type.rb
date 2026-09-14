module EventRail
  # Opt-in contract for a custom Active Model type used as an EventRail attribute
  # type.
  #
  # Rails already defines `serialize` and `deserialize`, so this adds no vocabulary.
  # What it adds is a stricter target: `ActiveModel::Type::Value#serialize` is
  # documented as producing a value "usable by the database", and database drivers
  # accept Date, Time, and BigDecimal objects. A queue is not a database. Active Job
  # does not recurse into a custom serializer's output, so a Ruby object left there
  # reaches the adapter raw, where a JSON-native adapter rejects the job and a JSON
  # column stringifies it and loses precision.
  #
  # A type therefore promises that `serialize` returns a JSON primitive, array, or
  # string-keyed hash, and that `deserialize` reconstructs the identical cast value
  # from it. `portable_examples` is what makes the promise checkable: EventRail
  # round-trips every example through JSON when the attribute is declared, so a type
  # that cannot hold up fails at class definition instead of at the first enqueue.
  #
  #   class MoneyType < ActiveModel::Type::Value
  #     include EventRail::PortableType
  #
  #     def cast(value) = value.is_a?(Money) ? value : Money.parse(value)
  #     def serialize(value) = value&.to_s
  #     def deserialize(value) = value && Money.parse(value)
  #     def portable_examples = [ Money.new(0, "USD"), Money.new(1250, "EUR") ]
  #   end
  module PortableType
    # Cast values covering every written shape the type can produce. At least one
    # is required, and each must survive serialize, a JSON encoding cycle, and
    # deserialize while comparing equal to the value it started as.
    def portable_examples
      raise NotImplementedError, "#{self.class} must define portable_examples"
    end
  end
end

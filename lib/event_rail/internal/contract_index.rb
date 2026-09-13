module EventRail
  module Internal
    class ContractIndex
      def self.build(event_classes)
        index = {}

        event_classes.each do |event_class|
          unless event_class.is_a?(Class) && event_class < EventRail::Event
            raise InvalidContract, "#{event_class.inspect} is not an EventRail::Event class"
          end

          key = event_class.contract_key
          if index.key?(key)
            raise DuplicateContractError.new(
              event_type: key.first,
              version: key.last,
              event_classes: [ index.fetch(key), event_class ]
            )
          end

          index[key] = event_class
        end

        index.freeze
      end
    end
  end
end

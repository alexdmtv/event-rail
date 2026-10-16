module Payments
  # Answers each call with the next scripted step for its method; unscripted calls succeed.
  # :ok and :refuse answer; :timeout fails before the provider acts; :lost acts, then loses the
  # answer on the way back. Like a real provider, a key it has answered gets the same answer again
  # without acting twice.
  class ScriptedGateway
    # calls counts requests, applied counts what the provider actually did.
    attr_reader :calls, :applied

    def initialize(**script)
      @script = script.transform_values(&:dup)
      @calls = Hash.new(0)
      @applied = Hash.new(0)
      @answers = {}
    end

    %i[ authorize capture void refund ].each do |method_name|
      define_method(method_name) do |idempotency_key:, **|
        @calls[method_name] += 1
        act(method_name, idempotency_key) unless @answers.key?(idempotency_key)

        answer = @answers.fetch(idempotency_key)
        raise Gateway::Refused, "refused by the script" if answer == :refuse

        answer
      end
    end

    private
      def act(method_name, idempotency_key)
        step = @script.fetch(method_name, []).shift
        raise Gateway::TemporaryFailure, "timed out by the script" if step == :timeout

        @applied[method_name] += 1
        @answers[idempotency_key] = step == :refuse ? :refuse : ("auth_scripted" if method_name == :authorize)
        raise Gateway::TemporaryFailure, "answer lost by the script" if step == :lost
      end
  end
end

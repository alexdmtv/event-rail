module Payments
  # Answers each call with the next scripted step for its method; unscripted calls succeed.
  # :ok and :refuse answer; :timeout fails before the provider acts; :lost acts, then loses the
  # answer on the way back. A method can also stop answering altogether until it answers again.
  # Like a real provider, a key it has answered gets the same answer again without acting twice.
  class ScriptedGateway
    # calls counts requests, applied counts what the provider actually did.
    attr_reader :calls, :applied

    def initialize(**script)
      @script = script.transform_values(&:dup)
      @calls = Hash.new(0)
      @applied = Hash.new(0)
      @answers = {}
      @unanswering = {}
    end

    # Adds steps to a method's script.
    def script(method_name, *steps) = (@script[method_name] ||= []).concat(steps)

    # Every call to the method times out, without the provider acting, until it answers again.
    def stop_answering(method_name) = @unanswering[method_name] = 0
    def answer_again(method_name) = @unanswering.delete(method_name)

    # What was set up and never happened: steps no call used, and a method set to stop answering
    # that nobody called. A test that sets a fault and never meets it proves nothing.
    def unused
      @script.reject { |_, steps| steps.empty? }.transform_values(&:dup)
        .merge(@unanswering.select { |_, timed_out| timed_out.zero? }.transform_values { [ :stop_answering ] })
    end

    %i[ authorize capture void refund ].each do |method_name|
      define_method(method_name) do |idempotency_key:, **|
        @calls[method_name] += 1
        if @unanswering.key?(method_name)
          @unanswering[method_name] += 1
          raise Gateway::TemporaryFailure, "not answering, by the script"
        end
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

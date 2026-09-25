# A payment provider whose answers a test scripts in advance, one per call and per method:
# :ok, :refuse or :timeout. Unscripted calls succeed.
class ScriptedGateway
  attr_reader :calls

  def initialize(**script)
    @script = script.transform_values(&:dup)
    @calls = Hash.new(0)
  end

  %i[ authorize capture void refund ].each do |method_name|
    define_method(method_name) do |**|
      @calls[method_name] += 1
      case @script.fetch(method_name, []).shift
      when :refuse then raise Payments::Gateway::Refused, "refused by the script"
      when :timeout then raise Payments::Gateway::TemporaryFailure, "timed out by the script"
      end
      "auth_scripted" if method_name == :authorize
    end
  end
end

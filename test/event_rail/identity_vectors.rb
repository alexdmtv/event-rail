require "bigdecimal"
require "date"

# The published derivation vectors: for each, the inputs, the exact name string that is
# hashed, and the event ID. They are compatibility state, not test scaffolding. Every one
# changing means every future publication derives a different ID for an unchanged fact,
# so a change here is a breaking release. The README prints the same table for
# implementations in other languages; a test keeps the two identical.
module IdentityVectors
  Vector = Data.define(:name, :rule, :inputs, :encoded, :id)

  FACT = { source: "acme.orders", event_type: "orders.order_placed" }.freeze
  EXECUTION = { source: "acme.orders", job_class: "Orders::PlaceOrderJob", event_type: "orders.order_placed", version: 1 }.freeze
  FACT_PREFIX = "s4:facts11:acme.orderss19:orders.order_placed".freeze
  EXECUTION_PREFIX = "s9:executions11:acme.orderss21:Orders::PlaceOrderJob".freeze
  EXECUTION_SUFFIX = "s19:orders.order_placedi1:1*0:".freeze

  def self.fact(name, identity, encoded_identity, id)
    Vector.new(name: name, rule: :fact, inputs: FACT.merge(identity: identity), encoded: FACT_PREFIX + encoded_identity, id: id)
  end

  def self.execution(name, scope, encoded_scope, id)
    Vector.new(name: name, rule: :execution, inputs: EXECUTION.merge(scope: scope), encoded: EXECUTION_PREFIX + encoded_scope + EXECUTION_SUFFIX, id: id)
  end

  ALL = [
    fact("a string", [ "o-1" ], "L8:1:s3:o-1", "13b2cda9-e1f7-57b6-ba1d-bb12a7553655"),
    fact("a non-ASCII string", [ "Zürich" ], "L12:1:s7:Zürich".b, "8ad8bbf8-3e10-5162-97da-53cb6752973f"),
    fact("an integer", [ 42 ], "L7:1:i2:42", "43230f76-4e80-55d0-bfaf-beab63ac76b9"),
    fact("a negative integer", [ -7 ], "L7:1:i2:-7", "4feffb91-0dec-5a7b-a5a0-67968abbe971"),
    fact("true", [ true ], "L9:1:b4:true", "b1a75e27-6aa2-5f7e-9159-fb429bddc17f"),
    fact("false", [ false ], "L10:1:b5:false", "631f1712-795b-59fa-b497-103b5f951306"),
    fact("a decimal", [ BigDecimal("12.50") ], "L9:1:d4:12.5", "fc8e4be7-4912-5702-b22b-92d63d710e01"),
    fact("an integral decimal", [ BigDecimal("100") ], "L10:1:d5:100.0", "4ab51db7-7864-591d-8e1a-b1f5d9567169"),
    fact("a zero decimal", [ BigDecimal("0") ], "L8:1:d3:0.0", "0a066901-77e5-55e3-99c4-a973b5018500"),
    fact("a negative zero decimal", [ BigDecimal("-0") ], "L9:1:d4:-0.0", "784aef76-53c9-517c-ba3f-732053cd537d"),
    fact("a float", [ 0.1 ], "L25:1:f19:0.10000000000000001", "cc223477-2cb1-5a6d-8d0f-6b25aaf989b7"),
    fact("an integral float", [ 1.0 ], "L6:1:f1:1", "901836d7-5477-5780-8e6b-dd39ed49d272"),
    fact("a large float", [ 1e22 ], "L10:1:f5:1e+22", "d4e88ebb-fdaa-5cc4-9dbe-c576abae6f36"),
    fact("a small float", [ 1e-7 ], "L28:1:f22:9.9999999999999995e-08", "83b232ee-36bc-53dc-a455-5a9e31a003a2"),
    fact("negative zero", [ -0.0 ], "L7:1:f2:-0", "7cab07fc-874c-59ff-a946-76d00585d229"),
    fact("a date", [ Date.new(2026, 9, 1) ], "L16:1:D10:2026-09-01", "84aaf8b3-7dc1-5446-880d-a002bfe8cab6"),
    fact("a timestamp", [ Time.utc(2026, 9, 1, 10, 30, Rational(123_456, 1_000_000)) ], "L33:1:T27:2026-09-01T10:30:00.123456Z",
      "874e797f-7b0c-5742-b8e2-6b05ae3f738a"),
    fact("a timestamp with an offset and sub-microsecond digits",
      [ Time.new(2026, 9, 1, 12, 30, Rational(1_234_567_891, 1_000_000_000), "+02:00") ], "L33:1:T27:2026-09-01T10:30:01.234567Z",
      "7fcd39f5-1a94-5ad2-b899-22ac849d510d"),
    fact("several values", [ "o-1", 2 ], "L12:2:s3:o-1i1:2", "fe61e6d0-cbb6-5db0-96a4-1fd78d86dab9"),
    execution("a regular job's scope", "job-1", "s5:job-1", "e3c5921d-a9bf-5816-b9a7-f36f426cb998"),
    execution("a subscriber's scope", [ "acme.payments", "0b1e2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d" ],
      "L59:2:s13:acme.paymentss36:0b1e2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "a3a31754-e302-5c23-a4a7-ea353accfeb6")
  ].freeze
end

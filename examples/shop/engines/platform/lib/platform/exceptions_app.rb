module Platform
  # For errors no controller answered: problem details without a detail, so a client learns
  # nothing of the failure.
  class ExceptionsApp
    def self.call(env)
      status = env["PATH_INFO"].delete_prefix("/").to_i
      body = { title: Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Error"), status: status }
      [ status, { "content-type" => "application/problem+json" }, [ body.to_json ] ]
    end
  end
end

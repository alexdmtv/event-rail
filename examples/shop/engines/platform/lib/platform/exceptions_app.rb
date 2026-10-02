module Platform
  # Rails' exceptions app, for the errors no controller answered: an unknown route, or a bug.
  # It answers with the same problem details as Platform::ApplicationController, without a
  # detail, so a client parses one shape for every error and learns nothing of the failure.
  class ExceptionsApp
    def self.call(env)
      status = env["PATH_INFO"].delete_prefix("/").to_i
      body = { title: Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Error"), status: status }
      [ status, { "content-type" => "application/problem+json" }, [ body.to_json ] ]
    end
  end
end

# frozen_string_literal: true

module TypeSafe
  module Resources
    # GET /v1/models: the models and aliases available to your account.
    class Models
      def initialize(client)
        @client = client
      end

      # @return [ModelList]
      def list(timeout: nil, retry_policy: nil, extra_headers: nil)
        @client.request(:get, "/v1/models", timeout: timeout, retry_policy: retry_policy,
                                            extra_headers: extra_headers) do |raw, headers|
          ModelList.new(raw, headers: headers)
        end
      end
    end
  end
end

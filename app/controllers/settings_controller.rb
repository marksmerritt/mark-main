class SettingsController < ApplicationController
  def index
    @connections = []

    @connections << check_connection(
      name: "Trading Journal",
      token_present: api_token.present?,
      base_url: ENV.fetch("TRADING_JOURNAL_URL", "http://localhost:3001"),
      test_proc: -> { api_client.overview }
    )

    @connections << check_connection(
      name: "Notes API",
      token_present: notes_api_token.present?,
      base_url: ENV.fetch("NOTES_API_URL", "http://localhost:3002"),
      test_proc: -> { notes_client.stats }
    )

    @connections << check_connection(
      name: "Budget API",
      token_present: budget_api_token.present?,
      base_url: ENV.fetch("BUDGET_API_URL", "http://localhost:3003"),
      test_proc: -> { budget_client.current_budget }
    )
  end

  private

  def check_connection(name:, token_present:, base_url:, test_proc:)
    status = if !token_present
      "no_token"
    else
      begin
        result = test_proc.call
        if result.is_a?(Hash) && (result["error"] == "connection_failed" || result["error"] == "401")
          result["error"] == "connection_failed" ? "unreachable" : "auth_failed"
        else
          "connected"
        end
      rescue => e
        "error"
      end
    end

    { name: name, base_url: base_url, token_present: token_present, status: status }
  end
end

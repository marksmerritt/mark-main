module ApiConnected
  extend ActiveSupport::Concern

  included do
    helper_method :api_token, :cached_tags, :notes_api_token, :cached_notes_tags, :budget_api_token, :unread_alerts_count
  end

  private

  # -- Trading Journal API --

  def api_client
    @api_client ||= TradingJournalClient.new(api_token)
  end

  def api_token
    ENV["TRADING_JOURNAL_TOKEN"]
  end

  def require_api_connection
    redirect_to root_path, alert: "Trading Journal is not connected." unless api_token.present?
  end

  def cached_tags
    @cached_tags ||= api_client.tags
  end

  # -- Notes API --

  def notes_client
    @notes_client ||= NotesApiClient.new(notes_api_token)
  end

  def notes_api_token
    ENV["NOTES_API_TOKEN"]
  end

  def require_notes_connection
    redirect_to root_path, alert: "Notes API is not connected." unless notes_api_token.present?
  end

  def cached_notes_tags
    @cached_notes_tags ||= notes_client.tags
  end

  # -- Budget API --

  def budget_client
    @budget_client ||= BudgetApiClient.new(budget_api_token)
  end

  def budget_api_token
    ENV["BUDGET_API_TOKEN"]
  end

  def require_budget_connection
    redirect_to root_path, alert: "Budget API is not connected." unless budget_api_token.present?
  end

  def unread_alerts_count
    return @unread_alerts_count if defined?(@unread_alerts_count)
    @unread_alerts_count = if budget_api_token.present?
      result = budget_client.alerts(status: "unread")
      alerts = result.is_a?(Hash) ? (result["alerts"] || []) : Array(result)
      alerts.count
    else
      0
    end
  rescue
    @unread_alerts_count = 0
  end
end

class HomeController < ApplicationController
  def index
    if api_token.present?
      threads = {}
      threads[:stats]    = Thread.new { api_client.overview }
      threads[:streaks]  = Thread.new { api_client.streaks }
      threads[:trades]   = Thread.new { api_client.trades(per_page: 10) }
      threads[:tags]     = Thread.new { cached_tags }
      threads[:journal]  = Thread.new { api_client.journal_entries(per_page: 5) }
      threads[:equity]   = Thread.new { api_client.equity_curve rescue {} }
      threads[:watchlists] = Thread.new { api_client.watchlists rescue [] }

      @stats = threads[:stats].value
      @streaks = threads[:streaks].value
      result = threads[:trades].value
      @recent_trades = result["trades"] || result
      @tags = threads[:tags].value
      journal_result = threads[:journal].value
      @recent_journal = journal_result.is_a?(Hash) ? (journal_result["journal_entries"] || []) : (journal_result || [])
      equity_result = threads[:equity].value
      @equity_curve = equity_result.is_a?(Hash) ? (equity_result["equity_curve"] || []) : []
      watchlists_result = threads[:watchlists].value
      @watchlists = watchlists_result.is_a?(Array) ? watchlists_result : (watchlists_result.is_a?(Hash) ? (watchlists_result["watchlists"] || []) : [])
    end

    if notes_api_token.present?
      notes_threads = {}
      notes_threads[:stats] = Thread.new { notes_client.stats }
      notes_threads[:notes] = Thread.new { notes_client.notes(per_page: 5) }
      notes_threads[:pinned] = Thread.new { notes_client.notes(pinned: true, per_page: 6) }

      @notes_stats = notes_threads[:stats].value
      result = notes_threads[:notes].value
      @recent_notes = result["notes"] || result
      pinned_result = notes_threads[:pinned].value
      @pinned_notes = pinned_result.is_a?(Hash) ? (pinned_result["notes"] || []) : Array(pinned_result)
    end

    if budget_api_token.present?
      budget_threads = {}
      budget_threads[:overview] = Thread.new { budget_client.budget_overview }
      budget_threads[:forecast] = Thread.new { budget_client.forecast }
      budget_threads[:recurring] = Thread.new { budget_client.recurring_summary rescue {} }
      budget_threads[:goals] = Thread.new { budget_client.goals(status: "active") rescue [] }
      budget_threads[:debt] = Thread.new { budget_client.debt_overview rescue {} }
      budget_threads[:trends] = Thread.new { budget_client.spending_trends(months: 6) rescue [] }
      budget_threads[:challenges] = Thread.new { budget_client.savings_challenges(status: "active") rescue [] }
      budget_threads[:alerts] = Thread.new { budget_client.alerts(status: "unread") rescue {} }

      @budget_overview = budget_threads[:overview].value
      @budget_forecast = budget_threads[:forecast].value
      @recurring_summary = budget_threads[:recurring].value
      goals_result = budget_threads[:goals].value
      @active_goals = goals_result.is_a?(Array) ? goals_result : (goals_result.is_a?(Hash) ? (goals_result["goals"] || []) : [])
      @debt_overview = budget_threads[:debt].value
      @spending_trends = budget_threads[:trends].value
      challenges_result = budget_threads[:challenges].value
      @active_challenges = challenges_result.is_a?(Array) ? challenges_result : (challenges_result.is_a?(Hash) ? (challenges_result["challenges"] || []) : [])
      alerts_result = budget_threads[:alerts].value
      @budget_alerts = alerts_result.is_a?(Hash) ? (alerts_result["alerts"] || []) : Array(alerts_result)
    end

    # Review stats
    if api_token.present?
      review_threads = {}
      review_threads[:queue] = Thread.new { api_client.review_queue rescue {} }
      review_threads[:stats] = Thread.new { api_client.review_stats rescue {} }
      queue_result = review_threads[:queue].value
      @unreviewed_count = queue_result.is_a?(Hash) ? (queue_result["count"] || 0) : 0
      @review_stats = review_threads[:stats].value
      @review_stats = {} unless @review_stats.is_a?(Hash)
    end

    @health_score = financial_health_score(
      stats: @stats,
      streaks: @streaks,
      budget: @budget_overview,
      notes_stats: @notes_stats
    )

    build_activity_feed
  end

  private

  def build_activity_feed
    @activity = []

    Array.wrap(@recent_trades).first(8).each do |trade|
      next unless trade.is_a?(Hash) && trade["entry_time"]
      @activity << {
        type: "trade",
        time: trade["entry_time"],
        icon: trade["pnl"].to_f >= 0 ? "trending_up" : "trending_down",
        title: "#{trade["side"]&.capitalize} #{trade["symbol"]}",
        detail: trade["status"] == "closed" ? number_to_currency(trade["pnl"]) : "Open",
        css: trade["pnl"].to_f >= 0 ? "positive" : "negative",
        path: "/trades/#{trade["id"]}"
      }
    end

    Array.wrap(@recent_journal).first(5).each do |entry|
      next unless entry.is_a?(Hash) && entry["date"]
      @activity << {
        type: "journal",
        time: entry["date"],
        icon: "auto_stories",
        title: "Journal Entry",
        detail: entry["mood"].presence || entry["date"],
        css: "",
        path: "/journal_entries/#{entry["id"]}"
      }
    end

    Array.wrap(@recent_notes).first(5).each do |note|
      next unless note.is_a?(Hash) && note["updated_at"]
      @activity << {
        type: "note",
        time: note["updated_at"],
        icon: "description",
        title: note["title"].presence || "Untitled",
        detail: note.dig("notebook", "name") || "Note",
        css: "",
        path: "/notes/#{note["id"]}"
      }
    end

    @activity.sort_by! { |a| a[:time] || "" }.reverse!
    @activity = @activity.first(12)
  end

  include ActionView::Helpers::NumberHelper
  include InsightsHelper
end

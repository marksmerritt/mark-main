class PreMarketController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    @date = Date.current
    threads = {}

    threads[:overview] = Thread.new { api_client.overview rescue {} }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }
    threads[:open_trades] = Thread.new {
      result = api_client.trades(status: "open", per_page: 50)
      result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
    }
    threads[:recent] = Thread.new {
      result = api_client.trades(
        status: "closed",
        start_date: 5.days.ago.to_date.to_s,
        end_date: @date.to_s,
        per_page: 50
      )
      result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
    }
    threads[:watchlists] = Thread.new { api_client.watchlists rescue [] }
    threads[:plans] = Thread.new {
      result = api_client.trade_plans rescue []
      plans = result.is_a?(Hash) ? (result["trade_plans"] || []) : Array(result)
      plans.select { |p| p["status"] == "pending" || p["status"] == "active" }
    }
    threads[:journal_today] = Thread.new {
      result = api_client.journal_entries(start_date: @date.to_s, end_date: @date.to_s)
      entries = result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      entries.first
    }
    threads[:review_queue] = Thread.new { api_client.review_queue rescue {} }

    @overview = threads[:overview].value || {}
    @streaks = threads[:streaks].value || {}
    @open_trades = threads[:open_trades].value
    @recent_trades = threads[:recent].value
    @watchlists = threads[:watchlists].value
    @watchlists = @watchlists.is_a?(Array) ? @watchlists : (@watchlists.is_a?(Hash) ? (@watchlists["watchlists"] || []) : [])
    @active_plans = threads[:plans].value
    @journal_today = threads[:journal_today].value
    review_result = threads[:review_queue].value || {}
    @unreviewed_count = review_result.is_a?(Hash) ? (review_result["count"] || 0) : 0

    # Recent performance summary
    @recent_pnl = @recent_trades.sum { |t| t["pnl"].to_f }
    @recent_wins = @recent_trades.count { |t| t["pnl"].to_f > 0 }
    @recent_losses = @recent_trades.count { |t| t["pnl"].to_f < 0 }
    @recent_win_rate = @recent_trades.any? ? (@recent_wins.to_f / @recent_trades.count * 100).round(1) : 0

    # Current streak info
    cs = @streaks.is_a?(Hash) ? @streaks["current_streak"] : nil
    @current_streak = cs.is_a?(Hash) ? cs["count"].to_i : cs.to_i
    @streak_type = cs.is_a?(Hash) ? cs["type"] : (@streaks.is_a?(Hash) ? @streaks["streak_type"] : nil)
    @journal_streak = @streaks.is_a?(Hash) ? (@streaks["journal_entry_streak"] || 0) : 0

    # Open position risk
    @positions_with_stops = @open_trades.count { |t| t["stop_loss"].to_f > 0 }
    @total_open_risk = @open_trades.sum { |t|
      stop = t["stop_loss"]&.to_f
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_i
      stop && stop > 0 ? (entry - stop).abs * qty : 0
    }
    @unrealized_pnl = @open_trades.sum { |t| t["pnl"].to_f }

    # Build readiness checklist
    build_checklist

    # Yesterday's best/worst
    yesterday_trades = @recent_trades.select { |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      date == (@date - 1.day).to_s
    }
    @yesterday_pnl = yesterday_trades.sum { |t| t["pnl"].to_f }
    @yesterday_count = yesterday_trades.count
    @yesterday_best = yesterday_trades.max_by { |t| t["pnl"].to_f }
    @yesterday_worst = yesterday_trades.min_by { |t| t["pnl"].to_f }
  end

  private

  def build_checklist
    @checklist = []

    @checklist << {
      label: "Review overnight positions",
      done: @open_trades.empty?,
      icon: "visibility",
      hint: @open_trades.any? ? "#{@open_trades.count} positions open" : "No open positions",
      action_path: @open_trades.any? ? exposure_path : nil
    }

    @checklist << {
      label: "Write pre-market journal",
      done: @journal_today.present?,
      icon: "auto_stories",
      hint: @journal_today ? "Entry recorded" : "Capture your plan for today",
      action_path: @journal_today ? nil : new_journal_entry_path
    }

    @checklist << {
      label: "Review unreviewed trades",
      done: @unreviewed_count == 0,
      icon: "rate_review",
      hint: @unreviewed_count > 0 ? "#{@unreviewed_count} trades need review" : "All caught up",
      action_path: @unreviewed_count > 0 ? review_trades_path : nil
    }

    @checklist << {
      label: "Set stop losses on all positions",
      done: @open_trades.empty? || @positions_with_stops == @open_trades.count,
      icon: "shield",
      hint: @open_trades.any? ? "#{@positions_with_stops}/#{@open_trades.count} have stops" : "No positions",
      action_path: nil
    }

    @checklist << {
      label: "Review active trade plans",
      done: @active_plans.empty?,
      icon: "assignment",
      hint: @active_plans.any? ? "#{@active_plans.count} pending plans" : "No pending plans",
      action_path: @active_plans.any? ? trade_plans_path : nil
    }

    @checklist << {
      label: "Check watchlist",
      done: false,
      icon: "remove_red_eye",
      hint: @watchlists.any? ? "#{@watchlists.count} watchlists" : "No watchlists set up",
      action_path: watchlists_path
    }
  end
end

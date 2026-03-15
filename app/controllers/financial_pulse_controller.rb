class FinancialPulseController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    @signals = []

    # Parallel fetch from all three APIs
    threads = {}

    if api_token.present?
      threads[:overview] = Thread.new { api_client.overview rescue {} }
      threads[:streaks] = Thread.new { api_client.streaks rescue {} }
      threads[:open_trades] = Thread.new {
        result = api_client.trades(status: "open", per_page: 50) rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:recent_trades] = Thread.new {
        result = api_client.trades(per_page: 10, status: "closed") rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
    end

    if budget_api_token.present?
      threads[:budget] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:debt] = Thread.new { budget_client.debt_overview rescue {} }
      threads[:alerts] = Thread.new {
        result = budget_client.alerts(status: "unread") rescue {}
        result.is_a?(Hash) ? (result["alerts"] || []) : []
      }
      threads[:goals] = Thread.new {
        result = budget_client.goals(status: "active") rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
    end

    if notes_api_token.present?
      threads[:notes_stats] = Thread.new { notes_client.stats rescue {} }
    end

    # Collect results
    overview = threads[:overview]&.value || {}
    streaks = threads[:streaks]&.value || {}
    open_trades = threads[:open_trades]&.value || []
    recent_trades = threads[:recent_trades]&.value || []
    budget = threads[:budget]&.value || {}
    debt = threads[:debt]&.value || {}
    alerts = threads[:alerts]&.value || []
    goals = threads[:goals]&.value || []
    notes_stats = threads[:notes_stats]&.value || {}

    # Trading Signals
    if api_token.present?
      total_pnl = overview.is_a?(Hash) ? overview["total_pnl"].to_f : 0
      win_rate = overview.is_a?(Hash) ? overview["win_rate"].to_f : 0
      open_count = open_trades.count
      unrealized = open_trades.sum { |t| t["unrealized_pnl"].to_f }

      # Recent performance (last 5 trades)
      last_5_pnl = recent_trades.first(5).sum { |t| t["pnl"].to_f }
      cs = streaks.is_a?(Hash) ? streaks["current_streak"] : nil
      winning_streak = cs.is_a?(Hash) ? cs["count"].to_i : cs.to_i
      streak_type = cs.is_a?(Hash) ? cs["type"] : (streaks.is_a?(Hash) ? streaks["streak_type"] : nil)

      @signals << { category: "Trading", icon: "show_chart", color: "var(--primary)",
        status: last_5_pnl >= 0 ? :positive : :negative,
        headline: last_5_pnl >= 0 ? "Trading is going well" : "Trading needs attention",
        metrics: [
          { label: "Open Positions", value: open_count.to_s },
          { label: "Unrealized P&L", value: number_to_currency(unrealized), color: unrealized >= 0 ? "var(--positive)" : "var(--negative)" },
          { label: "Last 5 Trades", value: "#{last_5_pnl >= 0 ? '+' : ''}#{number_to_currency(last_5_pnl)}", color: last_5_pnl >= 0 ? "var(--positive)" : "var(--negative)" },
          { label: "Win Rate", value: "#{win_rate}%", color: win_rate >= 50 ? "var(--positive)" : "var(--negative)" },
          { label: "Streak", value: "#{winning_streak}#{streak_type == 'win' ? 'W' : 'L'}", color: streak_type == "win" ? "var(--positive)" : "var(--negative)" }
        ],
        alerts: [
          (open_trades.any? { |t| t["stop_loss"].to_f == 0 } ? { severity: :warning, text: "#{open_trades.count { |t| t["stop_loss"].to_f == 0 }} open trades without stop losses" } : nil),
          (winning_streak >= 5 && streak_type == "win" ? { severity: :success, text: "#{winning_streak}-trade winning streak!" } : nil),
          (winning_streak >= 3 && streak_type != "win" ? { severity: :danger, text: "#{winning_streak}-trade losing streak. Consider pausing." } : nil)
        ].compact
      }
    end

    # Budget Signals
    if budget_api_token.present?
      budget_spent = budget.is_a?(Hash) ? budget["total_spent"].to_f : 0
      budget_limit = budget.is_a?(Hash) ? budget["total_budgeted"].to_f : 0
      budget_pct = budget_limit > 0 ? (budget_spent / budget_limit * 100).round(1) : 0

      debts = debt.is_a?(Hash) ? (debt["debts"] || debt["debt_accounts"] || []) : []
      total_debt = debts.is_a?(Array) ? debts.sum { |d| d.is_a?(Hash) ? d["current_balance"].to_f : 0 } : 0

      active_goals = goals.select { |g| g.is_a?(Hash) }
      goals_on_track = active_goals.count { |g| g["percentage_complete"].to_f >= 50 }

      @signals << { category: "Budget", icon: "account_balance_wallet", color: "#0d904f",
        status: budget_pct <= 100 ? :positive : :negative,
        headline: budget_pct <= 85 ? "Budget on track" : budget_pct <= 100 ? "Budget getting tight" : "Over budget",
        metrics: [
          { label: "Budget Used", value: "#{budget_pct}%", color: budget_pct <= 100 ? "var(--positive)" : "var(--negative)" },
          { label: "Spent", value: number_to_currency(budget_spent) },
          { label: "Total Debt", value: number_to_currency(total_debt), color: total_debt > 0 ? "var(--negative)" : "var(--positive)" },
          { label: "Active Goals", value: active_goals.count.to_s },
          { label: "Unread Alerts", value: alerts.count.to_s, color: alerts.count > 0 ? "var(--negative)" : "var(--text-secondary)" }
        ],
        alerts: [
          (budget_pct > 90 && budget_pct <= 100 ? { severity: :warning, text: "#{budget_pct}% of budget used — approaching limit" } : nil),
          (budget_pct > 100 ? { severity: :danger, text: "Over budget by #{number_to_currency(budget_spent - budget_limit)}" } : nil),
          (alerts.count > 3 ? { severity: :warning, text: "#{alerts.count} unread budget alerts" } : nil),
          (budget_pct <= 80 ? { severity: :success, text: "Budget well under control at #{budget_pct}%" } : nil)
        ].compact
      }
    end

    # Notes Signals
    if notes_api_token.present?
      total_notes = notes_stats.is_a?(Hash) ? (notes_stats["total_notes"] || notes_stats["count"] || 0).to_i : 0
      recent_count = notes_stats.is_a?(Hash) ? (notes_stats["this_week"] || notes_stats["recent_count"] || 0).to_i : 0

      @signals << { category: "Notes", icon: "edit_note", color: "#9c27b0",
        status: :neutral,
        headline: recent_count > 0 ? "Active note-taking" : "Notes quiet lately",
        metrics: [
          { label: "Total Notes", value: total_notes.to_s },
          { label: "Recent Activity", value: "#{recent_count} this week" }
        ],
        alerts: []
      }
    end

    # Overall health
    positive_count = @signals.count { |s| s[:status] == :positive }
    negative_count = @signals.count { |s| s[:status] == :negative }
    @overall_status = if negative_count > 0 then :attention
                      elsif positive_count == @signals.count then :great
                      else :okay
                      end
  end
end

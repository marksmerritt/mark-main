class SmartAlertsController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    @alerts = []
    @all_clear = []
    threads = {}

    # Parallel fetch from all APIs
    if api_token.present?
      threads[:overview] = Thread.new { api_client.overview rescue {} }
      threads[:streaks] = Thread.new { api_client.streaks rescue {} }
      threads[:recent_trades] = Thread.new {
        result = api_client.trades(per_page: 30, status: "closed") rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:open_trades] = Thread.new {
        result = api_client.trades(status: "open", per_page: 50) rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
    end

    if budget_api_token.present?
      threads[:budget] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:budget_alerts] = Thread.new {
        result = budget_client.alerts(status: "unread") rescue {}
        result.is_a?(Hash) ? (result["alerts"] || []) : []
      }
      threads[:recent_transactions] = Thread.new {
        result = budget_client.transactions(per_page: 30) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:goals] = Thread.new {
        result = budget_client.goals(status: "active") rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
      threads[:recurring] = Thread.new { budget_client.recurring_summary rescue {} }
    end

    if notes_api_token.present?
      threads[:notes_stats] = Thread.new { notes_client.stats rescue {} }
    end

    # Collect results
    overview = threads[:overview]&.value || {}
    streaks = threads[:streaks]&.value || {}
    recent_trades = threads[:recent_trades]&.value || []
    open_trades = threads[:open_trades]&.value || []
    budget = threads[:budget]&.value || {}
    budget_alerts = threads[:budget_alerts]&.value || []
    recent_transactions = threads[:recent_transactions]&.value || []
    goals = threads[:goals]&.value || []
    recurring = threads[:recurring]&.value || {}
    notes_stats = threads[:notes_stats]&.value || {}

    # ── Risk Alerts (red) ──

    if api_token.present?
      # Losing streak >= 3 trades
      cs = streaks.is_a?(Hash) ? streaks["current_streak"] : nil
      streak_count = cs.is_a?(Hash) ? cs["count"].to_i : cs.to_i
      streak_type = cs.is_a?(Hash) ? cs["type"] : (streaks.is_a?(Hash) ? streaks["streak_type"] : nil)
      losing_day_streak = streaks.is_a?(Hash) ? streaks["current_losing_day_streak"].to_i : 0

      if streak_count >= 3 && streak_type != "win"
        @alerts << {
          severity: "critical", category: "trending_down", title: "Losing Streak Active",
          message: "You're on a #{streak_count}-trade losing streak. Consider pausing to review your strategy.",
          action_text: "Review Trades", action_path: "/trades/review"
        }
      elsif losing_day_streak >= 3
        @alerts << {
          severity: "critical", category: "trending_down", title: "#{losing_day_streak}-Day Losing Streak",
          message: "You've had #{losing_day_streak} consecutive losing days. Step back and reassess.",
          action_text: "View Streaks", action_path: "/reports/streak_analysis"
        }
      else
        @all_clear << { icon: "trending_up", text: "No active losing streak" }
      end

      # Max daily loss exceeded (> 3% of total P&L)
      total_pnl = overview.is_a?(Hash) ? overview["total_pnl"].to_f : 0
      max_daily_loss = overview.is_a?(Hash) ? (overview["max_daily_loss"] || overview["worst_day"]).to_f.abs : 0
      if total_pnl > 0 && max_daily_loss > (total_pnl * 0.03)
        @alerts << {
          severity: "critical", category: "dangerous", title: "Max Daily Loss Exceeded",
          message: "Your worst daily loss (#{number_to_currency(max_daily_loss)}) exceeds 3% of total P&L (#{number_to_currency(total_pnl)}).",
          action_text: "Risk Analysis", action_path: "/reports/risk_analysis"
        }
      elsif total_pnl > 0
        @all_clear << { icon: "shield", text: "Daily losses within acceptable limits" }
      end

      # Open position without stop loss
      no_stop = open_trades.select { |t| t.is_a?(Hash) && t["stop_loss"].to_f == 0 }
      if no_stop.any?
        @alerts << {
          severity: "critical", category: "gpp_bad", title: "#{no_stop.count} Open Trade#{'s' if no_stop.count != 1} Without Stop Loss",
          message: "Unprotected positions: #{no_stop.first(3).map { |t| t["symbol"] }.compact.join(', ')}#{no_stop.count > 3 ? '...' : ''}",
          action_text: "View Open Trades", action_path: "/trades?status=open"
        }
      elsif open_trades.any?
        @all_clear << { icon: "verified_user", text: "All open positions have stop losses" }
      end

      # Over-concentrated in one symbol (>50% of open positions)
      if open_trades.count >= 2
        symbol_counts = open_trades.select { |t| t.is_a?(Hash) }.group_by { |t| t["symbol"] }
        symbol_counts.each do |symbol, trades_for_symbol|
          pct = (trades_for_symbol.count.to_f / open_trades.count * 100).round(0)
          if pct > 50
            @alerts << {
              severity: "critical", category: "pie_chart", title: "Over-Concentrated in #{symbol}",
              message: "#{pct}% of your open positions (#{trades_for_symbol.count}/#{open_trades.count}) are in #{symbol}.",
              action_text: "View Exposure", action_path: "/exposure"
            }
          end
        end
      end
      if open_trades.count >= 2 && !@alerts.any? { |a| a[:title]&.start_with?("Over-Concentrated") }
        @all_clear << { icon: "donut_large", text: "Position concentration is diversified" }
      end

      # ── Performance Alerts (yellow) ──

      # Win rate declining (recent 20 vs overall)
      overall_win_rate = overview.is_a?(Hash) ? overview["win_rate"].to_f : 0
      recent_20 = recent_trades.first(20).select { |t| t.is_a?(Hash) }
      if recent_20.count >= 5
        recent_wins = recent_20.count { |t| t["pnl"].to_f > 0 }
        recent_win_rate = (recent_wins.to_f / recent_20.count * 100).round(1)
        if overall_win_rate > 0 && recent_win_rate < (overall_win_rate - 10)
          @alerts << {
            severity: "warning", category: "speed", title: "Win Rate Declining",
            message: "Recent win rate #{recent_win_rate}% is below your overall #{overall_win_rate}% (last #{recent_20.count} trades).",
            action_text: "View Reports", action_path: "/reports/overview"
          }
        else
          @all_clear << { icon: "equalizer", text: "Win rate is holding steady" }
        end
      end

      # Average hold time increasing significantly
      if recent_trades.count >= 10
        recent_10 = recent_trades.first(10).select { |t| t.is_a?(Hash) && t["hold_time"].to_f > 0 }
        older_10 = recent_trades[10..19]&.select { |t| t.is_a?(Hash) && t["hold_time"].to_f > 0 } || []
        if recent_10.count >= 3 && older_10.count >= 3
          recent_avg_hold = recent_10.sum { |t| t["hold_time"].to_f } / recent_10.count
          older_avg_hold = older_10.sum { |t| t["hold_time"].to_f } / older_10.count
          if older_avg_hold > 0 && recent_avg_hold > (older_avg_hold * 1.5)
            @alerts << {
              severity: "warning", category: "schedule", title: "Hold Time Increasing",
              message: "Your average hold time has increased significantly compared to previous trades.",
              action_text: "Duration Report", action_path: "/reports/by_duration"
            }
          else
            @all_clear << { icon: "timer", text: "Hold times are consistent" }
          end
        end
      end

      # Largest loss in last 10 trades exceeds 2x average loss
      last_10 = recent_trades.first(10).select { |t| t.is_a?(Hash) }
      losses = last_10.select { |t| t["pnl"].to_f < 0 }
      if losses.count >= 2
        avg_loss = losses.sum { |t| t["pnl"].to_f.abs } / losses.count
        max_loss = losses.map { |t| t["pnl"].to_f.abs }.max
        if max_loss > (avg_loss * 2)
          @alerts << {
            severity: "warning", category: "report_problem", title: "Outsized Loss Detected",
            message: "Largest recent loss (#{number_to_currency(max_loss)}) is #{(max_loss / avg_loss).round(1)}x your average loss (#{number_to_currency(avg_loss)}).",
            action_text: "View Distribution", action_path: "/reports/distribution"
          }
        else
          @all_clear << { icon: "balance", text: "Losses are within normal range" }
        end
      end

      # P&L negative for current month
      monthly_pnl = overview.is_a?(Hash) ? (overview["monthly_pnl"] || overview["this_month_pnl"]).to_f : 0
      if monthly_pnl < 0
        @alerts << {
          severity: "warning", category: "calendar_today", title: "Negative Month",
          message: "Current month P&L is #{number_to_currency(monthly_pnl)}.",
          action_text: "Monthly Report", action_path: "/monthly_report"
        }
      elsif api_token.present? && recent_trades.any?
        @all_clear << { icon: "event_available", text: "Month is profitable so far" }
      end

      # ── Opportunity Alerts (green) ──

      # Winning streak >= 3
      if streak_count >= 3 && streak_type == "win"
        @alerts << {
          severity: "success", category: "local_fire_department", title: "#{streak_count}-Trade Winning Streak!",
          message: "You're on fire! Keep the momentum going but stay disciplined.",
          action_text: "View Streaks", action_path: "/reports/streak_analysis"
        }
      end

      # New monthly P&L record
      best_month = overview.is_a?(Hash) ? (overview["best_month_pnl"] || overview["best_month"]).to_f : 0
      if monthly_pnl > 0 && best_month > 0 && monthly_pnl >= best_month
        @alerts << {
          severity: "success", category: "emoji_events", title: "New Monthly P&L Record!",
          message: "This month's P&L of #{number_to_currency(monthly_pnl)} is your best month ever!",
          action_text: "Monthly Performance", action_path: "/reports/monthly_performance"
        }
      end

      # Win rate above 60% in last 20 trades
      if recent_20.count >= 10
        recent_wins_20 = recent_20.count { |t| t["pnl"].to_f > 0 }
        recent_wr_20 = (recent_wins_20.to_f / recent_20.count * 100).round(1)
        if recent_wr_20 >= 60
          @alerts << {
            severity: "success", category: "military_tech", title: "High Win Rate: #{recent_wr_20}%",
            message: "Your last #{recent_20.count} trades have a #{recent_wr_20}% win rate. Excellent accuracy!",
            action_text: "View Performance", action_path: "/reports/overview"
          }
        end
      end

      # Successfully reviewed all trades for the week
      review_result = begin api_client.review_queue rescue {} end
      review_count = review_result.is_a?(Hash) ? (review_result["count"] || (review_result["trades"]&.count) || 0) : 0
      if review_count == 0 && recent_trades.any?
        @alerts << {
          severity: "success", category: "fact_check", title: "All Trades Reviewed",
          message: "You're caught up on all trade reviews. Great discipline!",
          action_text: "View Reviews", action_path: "/trades/review"
        }
      end
    end

    # ── Budget Alerts (blue) ──

    if budget_api_token.present?
      budget_spent = budget.is_a?(Hash) ? budget["total_spent"].to_f : 0
      budget_limit = budget.is_a?(Hash) ? budget["total_budgeted"].to_f : 0
      budget_pct = budget_limit > 0 ? (budget_spent / budget_limit * 100).round(1) : 0

      # Spending exceeding budget by >10%
      if budget_pct > 110
        @alerts << {
          severity: "warning", category: "account_balance_wallet", title: "Over Budget by #{(budget_pct - 100).round(0)}%",
          message: "You've spent #{number_to_currency(budget_spent)} of your #{number_to_currency(budget_limit)} budget (#{budget_pct}%).",
          action_text: "View Budget", action_path: "/budget"
        }
      elsif budget_limit > 0
        @all_clear << { icon: "savings", text: "Spending is within budget" }
      end

      # Goal deadline approaching with insufficient progress
      active_goals = goals.select { |g| g.is_a?(Hash) }
      active_goals.each do |goal|
        target_date = Date.parse(goal["target_date"] || goal["deadline"] || "") rescue nil
        next unless target_date
        days_left = (target_date - Date.current).to_i
        pct_complete = goal["percentage_complete"].to_f
        if days_left.between?(1, 30) && pct_complete < 75
          @alerts << {
            severity: "warning", category: "flag", title: "Goal at Risk: #{goal["name"] || goal["title"]}",
            message: "#{days_left} days left but only #{pct_complete.round(0)}% complete.",
            action_text: "View Goals", action_path: "/budget/goals"
          }
        end
      end
      if active_goals.any? && !@alerts.any? { |a| a[:title]&.start_with?("Goal at Risk") }
        @all_clear << { icon: "flag", text: "All goals are on track" }
      end

      # Recurring bill due in next 3 days
      upcoming = recurring.is_a?(Hash) ? (recurring["upcoming"] || []) : []
      upcoming_bills = []
      upcoming.each do |bill|
        due_date = Date.parse(bill["next_date"] || bill["next_due_date"] || "") rescue nil
        next unless due_date
        days_until = (due_date - Date.current).to_i
        if days_until.between?(0, 3)
          upcoming_bills << { name: bill["description"] || bill["name"], amount: bill["amount"].to_f, days: days_until }
        end
      end
      if upcoming_bills.any?
        bill_list = upcoming_bills.first(3).map { |b| "#{b[:name]} (#{number_to_currency(b[:amount])})" }.join(", ")
        @alerts << {
          severity: "info", category: "receipt_long", title: "#{upcoming_bills.count} Bill#{'s' if upcoming_bills.count != 1} Due Soon",
          message: bill_list,
          action_text: "View Recurring", action_path: "/budget/recurring"
        }
      else
        @all_clear << { icon: "receipt", text: "No bills due in the next 3 days" }
      end

      # Savings rate below 10%
      income = budget.is_a?(Hash) ? (budget["total_income"] || budget["income"]).to_f : 0
      savings = income > 0 ? ((income - budget_spent) / income * 100).round(1) : 0
      if income > 0 && savings < 10
        @alerts << {
          severity: "warning", category: "savings", title: "Low Savings Rate: #{savings}%",
          message: "Your savings rate is below the recommended 10% minimum. Consider cutting discretionary spending.",
          action_text: "Budget Overview", action_path: "/budget"
        }
      elsif income > 0
        @all_clear << { icon: "savings", text: "Savings rate is healthy at #{savings}%" }
      end
    end

    # ── Discipline Alerts (purple) ──

    if api_token.present?
      # No journal entry today
      journal_result = begin api_client.journal_entries(date: Date.current.to_s) rescue {} end
      today_entries = if journal_result.is_a?(Hash)
        (journal_result["journal_entries"] || [])
      elsif journal_result.is_a?(Array)
        journal_result
      else
        []
      end
      if today_entries.empty?
        @alerts << {
          severity: "info", category: "edit_note", title: "No Journal Entry Today",
          message: "Take a moment to reflect on today's trading or plans.",
          action_text: "Write Entry", action_path: "/journal_entries/new"
        }
      else
        @all_clear << { icon: "edit_note", text: "Journal entry written today" }
      end

      # No trade review in 5+ days
      review_stats_result = begin api_client.review_stats rescue {} end
      last_review_date = review_stats_result.is_a?(Hash) ? (review_stats_result["last_review_date"] || review_stats_result["last_reviewed_at"]) : nil
      if last_review_date.present?
        days_since_review = (Date.current - Date.parse(last_review_date.to_s)).to_i rescue nil
        if days_since_review && days_since_review >= 5
          @alerts << {
            severity: "info", category: "rate_review", title: "No Trade Review in #{days_since_review} Days",
            message: "Regular reviews help you learn from your trades and improve.",
            action_text: "Start Review", action_path: "/trades/review"
          }
        elsif days_since_review
          @all_clear << { icon: "rate_review", text: "Trade reviews are up to date" }
        end
      end

      # Trading on weekend
      if Date.current.saturday? || Date.current.sunday?
        today_trades = recent_trades.select { |t| t.is_a?(Hash) && t["entry_date"].to_s.start_with?(Date.current.to_s) }
        if today_trades.any?
          @alerts << {
            severity: "info", category: "weekend", title: "Trading on Weekend",
            message: "You have trades placed today. Weekend trading can carry different risks.",
            action_text: "View Today's Trades", action_path: "/trades?date=#{Date.current}"
          }
        end
      end
    end

    if notes_api_token.present?
      # No notes written in 3+ days
      last_note_date = notes_stats.is_a?(Hash) ? (notes_stats["last_note_date"] || notes_stats["last_created_at"]) : nil
      if last_note_date.present?
        days_since_note = (Date.current - Date.parse(last_note_date.to_s)).to_i rescue nil
        if days_since_note && days_since_note >= 3
          @alerts << {
            severity: "info", category: "note_add", title: "No Notes in #{days_since_note} Days",
            message: "Writing regularly helps organize your thoughts and track ideas.",
            action_text: "Write Note", action_path: "/notes/new"
          }
        else
          @all_clear << { icon: "description", text: "Notes are active and up to date" }
        end
      end
    end

    # Sort alerts: critical first, then warning, info, success
    severity_order = { "critical" => 0, "warning" => 1, "info" => 2, "success" => 3 }
    @alerts.sort_by! { |a| severity_order[a[:severity]] || 99 }

    @summary = {
      total: @alerts.count,
      critical: @alerts.count { |a| a[:severity] == "critical" },
      warning: @alerts.count { |a| a[:severity] == "warning" },
      info: @alerts.count { |a| a[:severity] == "info" },
      success: @alerts.count { |a| a[:severity] == "success" }
    }
  end
end

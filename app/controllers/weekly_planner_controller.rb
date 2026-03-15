class WeeklyPlannerController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    @week_offset = params[:week_offset].to_i
    @week_start = Date.current.beginning_of_week(:monday) + @week_offset.weeks
    @week_end = @week_start + 6.days
    @is_current_week = @week_start == Date.current.beginning_of_week(:monday)

    threads = {}

    # ---- Trading API ----
    if api_token.present?
      threads[:trades] = Thread.new {
        result = api_client.trades(
          start_date: @week_start.to_s,
          end_date: (@week_end + 1.day).to_s,
          per_page: 200
        ) rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:journal] = Thread.new {
        result = api_client.journal_entries(
          start_date: @week_start.to_s,
          end_date: @week_end.to_s,
          per_page: 50
        ) rescue {}
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      }
      threads[:trade_plans] = Thread.new {
        result = api_client.trade_plans rescue []
        plans = result.is_a?(Hash) ? (result["trade_plans"] || []) : Array(result)
        plans.select { |p| p["status"] == "planned" || p["status"] == "active" }
      }
    end

    # ---- Budget API ----
    if budget_api_token.present?
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: @week_start.to_s,
          end_date: @week_end.to_s,
          per_page: 200
        ) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:recurring] = Thread.new {
        budget_client.recurring_summary rescue {}
      }
      threads[:budget_overview] = Thread.new {
        budget_client.budget_overview(
          month: @week_start.month,
          year: @week_start.year
        ) rescue {}
      }
    end

    # ---- Notes API ----
    if notes_api_token.present?
      threads[:notes] = Thread.new {
        result = notes_client.notes(per_page: 200, sort: "updated_at_desc") rescue {}
        all = result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
        all.select { |n|
          updated = n["updated_at"] || n["created_at"]
          next false unless updated
          date = Date.parse(updated.to_s) rescue nil
          date && date >= @week_start && date <= @week_end
        }
      }
      threads[:reminders] = Thread.new {
        result = notes_client.reminders rescue {}
        all = result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["reminders"] || []) : [])
        all.select { |r|
          due = r["remind_at"] || r["due_date"]
          next false unless due
          date = Date.parse(due.to_s) rescue nil
          date && date >= @week_start && date <= @week_end
        }
      }
    end

    # Collect results
    @trades = threads[:trades]&.value || []
    @journal_entries = threads[:journal]&.value || []
    @trade_plans = threads[:trade_plans]&.value || []
    @transactions = threads[:transactions]&.value || []
    recurring_result = threads[:recurring]&.value || {}
    @upcoming_bills = recurring_result.is_a?(Hash) ? (recurring_result["upcoming"] || []) : []
    @budget_overview = threads[:budget_overview]&.value || {}
    @notes = threads[:notes]&.value || []
    @reminders = threads[:reminders]&.value || []

    build_daily_view
    compute_weekly_stats
    compute_goals
  end

  private

  def build_daily_view
    @days = []
    (@week_start..@week_end).each do |date|
      date_str = date.to_s

      day_trades = @trades.select { |t|
        d = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
        d == date_str
      }

      day_journal = @journal_entries.select { |j|
        (j["date"])&.to_s&.slice(0, 10) == date_str
      }

      day_notes = @notes.select { |n|
        d = (n["updated_at"] || n["created_at"])&.to_s&.slice(0, 10)
        d == date_str
      }

      day_transactions = @transactions.select { |t|
        (t["transaction_date"])&.to_s&.slice(0, 10) == date_str
      }

      day_reminders = @reminders.select { |r|
        due = r["remind_at"] || r["due_date"]
        due && due.to_s.slice(0, 10) == date_str
      }

      day_bills = @upcoming_bills.select { |b|
        due = Date.parse(b["next_date"] || b["next_due_date"]) rescue nil
        due && due == date
      }

      total_pnl = day_trades.sum { |t| t["pnl"].to_f }

      @days << {
        date: date,
        day_name: date.strftime("%A"),
        short_day: date.strftime("%a"),
        trades: day_trades,
        journal: day_journal,
        notes: day_notes,
        transactions: day_transactions,
        reminders: day_reminders,
        bills: day_bills,
        total_pnl: total_pnl,
        is_today: date == Date.current,
        is_past: date < Date.current,
        is_future: date > Date.current
      }
    end
  end

  def compute_weekly_stats
    @total_pnl = @trades.sum { |t| t["pnl"].to_f }
    @trade_count = @trades.count
    @trade_wins = @trades.count { |t| t["pnl"].to_f > 0 }
    @trade_losses = @trades.count { |t| t["pnl"].to_f < 0 }
    @win_rate = @trade_count > 0 ? (@trade_wins.to_f / @trade_count * 100).round(1) : 0
    @journal_count = @journal_entries.count
    @notes_count = @notes.count
    @reminders_count = @reminders.count

    @income = @transactions.select { |t| t["transaction_type"] == "income" }.sum { |t| t["amount"].to_f }
    @spending = @transactions.select { |t| t["transaction_type"] != "income" }.sum { |t| t["amount"].to_f }
    @transaction_count = @transactions.count

    # Active days
    @active_days = @days.count { |d|
      d[:trades].any? || d[:journal].any? || d[:notes].any? || d[:transactions].any?
    }
  end

  def compute_goals
    @goals = []

    # Trading goals
    if api_token.present?
      if @trade_count > 0 && @win_rate < 50
        @goals << {
          icon: "show_chart",
          color: "var(--primary)",
          text: "Focus on quality setups to improve win rate (currently #{@win_rate}%)"
        }
      elsif @trade_count == 0
        @goals << {
          icon: "show_chart",
          color: "var(--primary)",
          text: "Look for trading opportunities this week"
        }
      end

      if @journal_count < @days.count { |d| d[:trades].any? }
        @goals << {
          icon: "auto_stories",
          color: "#ff8f00",
          text: "Journal every trading day for better pattern recognition"
        }
      end

      if @trade_plans.any?
        @goals << {
          icon: "playlist_add_check",
          color: "#5c6bc0",
          text: "#{@trade_plans.count} active trade plan#{'s' if @trade_plans.count != 1} to execute"
        }
      end
    end

    # Budget goals
    if budget_api_token.present?
      if @spending > @income && @income > 0
        @goals << {
          icon: "savings",
          color: "#0d904f",
          text: "Reduce spending to stay within income (#{number_to_currency(@spending - @income)} over)"
        }
      elsif @spending > 0
        @goals << {
          icon: "account_balance_wallet",
          color: "#0d904f",
          text: "Keep tracking expenses to stay on budget"
        }
      end
    end

    # Notes goals
    if notes_api_token.present?
      writing_days = @days.count { |d| d[:notes].any? }
      if writing_days < 3 && !@is_current_week
        @goals << {
          icon: "edit_note",
          color: "#9c27b0",
          text: "Write notes on at least 3 days next week"
        }
      elsif @notes_count == 0
        @goals << {
          icon: "edit_note",
          color: "#9c27b0",
          text: "Start capturing ideas and reflections in notes"
        }
      end

      if @reminders_count > 0
        pending = @reminders.count
        @goals << {
          icon: "alarm",
          color: "#e53935",
          text: "#{pending} reminder#{'s' if pending != 1} due this week"
        }
      end
    end

    # General
    if @active_days < 3 && !@is_current_week
      @goals << {
        icon: "event_available",
        color: "#5c6bc0",
        text: "Be active on more days — aim for at least 5 days next week"
      }
    end
  end
end

class TradeCalendarController < ApplicationController
  include ApiConnected

  def show
    @year = (params[:year] || Date.current.year).to_i
    @month = (params[:month] || Date.current.month).to_i

    # Clamp month/year to valid range
    if @month < 1
      @month = 12
      @year -= 1
    elsif @month > 12
      @month = 1
      @year += 1
    end

    @target_date = Date.new(@year, @month, 1)
    @month_start = @target_date.beginning_of_month
    @month_end = @target_date.end_of_month

    trades = []
    journal_entries = []

    if api_token.present?
      threads = {}

      threads[:trades] = Thread.new do
        begin
          result = api_client.trades(per_page: 200, sort: "closed_at", direction: "desc")
          raw = result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
          raw.select { |t| t.is_a?(Hash) }
        rescue => e
          Rails.logger.error("TradeCalendar trades fetch error: #{e.message}")
          []
        end
      end

      threads[:journal] = Thread.new do
        begin
          result = api_client.journal_entries(per_page: 500)
          raw = result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
          raw.select { |e| e.is_a?(Hash) }
        rescue => e
          Rails.logger.error("TradeCalendar journal fetch error: #{e.message}")
          []
        end
      end

      begin
        trades = threads[:trades].value || []
      rescue => e
        Rails.logger.error("TradeCalendar trades thread error: #{e.message}")
        trades = []
      end

      begin
        journal_entries = threads[:journal].value || []
      rescue => e
        Rails.logger.error("TradeCalendar journal thread error: #{e.message}")
        journal_entries = []
      end
    end

    # Filter trades to the current month by closed_at or created_at
    month_trades = trades.select do |t|
      date_str = (t["closed_at"] || t["exit_time"] || t["entry_time"] || t["created_at"]).to_s.slice(0, 10)
      next false if date_str.blank?
      begin
        d = Date.parse(date_str)
        d >= @month_start && d <= @month_end
      rescue
        false
      end
    end

    # Group trades by date
    @trades_by_date = {}
    month_trades.each do |trade|
      date_str = (trade["closed_at"] || trade["exit_time"] || trade["entry_time"] || trade["created_at"]).to_s.slice(0, 10)
      next if date_str.blank?
      @trades_by_date[date_str] ||= []
      @trades_by_date[date_str] << trade
    end

    # Build daily summaries
    @daily_data = {}
    @trades_by_date.each do |date_str, day_trades|
      total_pnl = day_trades.sum { |t| t["pnl"].to_f }
      wins = day_trades.count { |t| t["pnl"].to_f > 0 }
      losses = day_trades.count { |t| t["pnl"].to_f <= 0 }

      @daily_data[date_str] = {
        trades: day_trades,
        trade_count: day_trades.count,
        total_pnl: total_pnl.round(2),
        wins: wins,
        losses: losses
      }
    end

    # Journal entries grouped by date
    @journal_dates = {}
    journal_entries.each do |entry|
      date_str = (entry["date"] || entry["created_at"]).to_s.slice(0, 10)
      next if date_str.blank?
      begin
        d = Date.parse(date_str)
        if d >= @month_start && d <= @month_end
          @journal_dates[date_str] = true
        end
      rescue
        next
      end
    end

    # Month-level summary stats
    @month_pnl = month_trades.sum { |t| t["pnl"].to_f }.round(2)
    @month_trade_count = month_trades.count
    @month_wins = month_trades.count { |t| t["pnl"].to_f > 0 }
    @month_losses = month_trades.count { |t| t["pnl"].to_f <= 0 }
    @month_win_rate = @month_trade_count > 0 ? (@month_wins.to_f / @month_trade_count * 100).round(1) : 0.0

    # Best and worst days
    if @daily_data.any?
      @best_day = @daily_data.max_by { |_, d| d[:total_pnl] }
      @worst_day = @daily_data.min_by { |_, d| d[:total_pnl] }
    end

    # Max absolute daily P&L for intensity scaling
    @max_abs_pnl = @daily_data.values.map { |d| d[:total_pnl].abs }.max.to_f
    @max_abs_pnl = 1 if @max_abs_pnl == 0

    # Previous/next month navigation
    prev_date = @target_date - 1.month
    next_date = @target_date + 1.month
    @prev_month = prev_date.month
    @prev_year = prev_date.year
    @next_month = next_date.month
    @next_year = next_date.year
    @can_go_next = next_date.beginning_of_month <= Date.current.end_of_month
  end
end

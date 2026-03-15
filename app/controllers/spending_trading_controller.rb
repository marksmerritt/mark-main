class SpendingTradingController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    trading_thread = Thread.new do
      api_client.overview
    rescue => e
      Rails.logger.error("spending_trading trading: #{e.message}")
      {}
    end

    budget_thread = Thread.new do
      budget_client.transactions(per_page: 500)
    rescue => e
      Rails.logger.error("spending_trading budget: #{e.message}")
      {}
    end

    overview = trading_thread.value || {}
    overview = {} unless overview.is_a?(Hash)

    txn_result = budget_thread.value || {}
    transactions = txn_result.is_a?(Hash) ? (txn_result["transactions"] || []) : Array(txn_result)
    transactions = transactions.is_a?(Array) ? transactions.select { |t| t.is_a?(Hash) } : []

    # Build daily P&L from trading overview
    raw_pnl = overview["daily_pnl"]
    @daily_pnl = case raw_pnl
                 when Array then raw_pnl.to_h
                 when Hash then raw_pnl
                 else {}
                 end

    # Build daily spending from budget transactions
    @daily_spending = {}
    transactions.each do |t|
      next unless t["transaction_type"] == "expense"
      date = (t["transaction_date"] || t["date"])&.to_s&.slice(0, 10)
      next unless date
      @daily_spending[date] ||= 0.0
      @daily_spending[date] += t["amount"].to_f.abs
    end

    @range_start = Date.today - 89
    @range_end = Date.today

    # Build aligned daily data for the 90-day window
    @days = (@range_start..@range_end).map do |date|
      ds = date.to_s
      {
        date: date,
        pnl: @daily_pnl[ds].to_f,
        spending: @daily_spending[ds].to_f
      }
    end

    compute_correlation
    compute_insights
    compute_spending_after_losses
    compute_trading_after_spending
    compute_monthly_comparison
  end

  private

  def compute_correlation
    pnl_values = @days.map { |d| d[:pnl] }
    spending_values = @days.map { |d| d[:spending] }

    @correlation = pearson(pnl_values, spending_values)
  end

  def pearson(xs, ys)
    n = xs.size
    return 0.0 if n < 3

    mean_x = xs.sum / n.to_f
    mean_y = ys.sum / n.to_f

    num = xs.zip(ys).sum { |x, y| (x - mean_x) * (y - mean_y) }
    den_x = Math.sqrt(xs.sum { |x| (x - mean_x)**2 })
    den_y = Math.sqrt(ys.sum { |y| (y - mean_y)**2 })

    return 0.0 if den_x == 0 || den_y == 0
    (num / (den_x * den_y)).round(3)
  end

  def compute_insights
    @insights = []

    # Post-loss spending ("retail therapy" detection)
    loss_days = @days.select { |d| d[:pnl] < 0 }
    win_days = @days.select { |d| d[:pnl] > 0 }

    post_loss_spending = []
    post_win_spending = []

    @days.each_with_index do |day, i|
      next if i == 0
      prev = @days[i - 1]
      if prev[:pnl] < 0
        post_loss_spending << day[:spending]
      elsif prev[:pnl] > 0
        post_win_spending << day[:spending]
      end
    end

    if post_loss_spending.any? && post_win_spending.any?
      avg_post_loss = post_loss_spending.sum / post_loss_spending.size.to_f
      avg_post_win = post_win_spending.sum / post_win_spending.size.to_f

      if avg_post_win > 0 && avg_post_loss > avg_post_win
        pct = ((avg_post_loss / avg_post_win - 1) * 100).round(0)
        if pct > 5
          @insights << {
            icon: "shopping_bag",
            color: "var(--negative)",
            title: "Retail Therapy Detected",
            text: "You spend #{pct}% more on days after a trading loss (#{number_to_currency(avg_post_loss.round(2))} vs #{number_to_currency(avg_post_win.round(2))} after wins)."
          }
        end
      end

      if avg_post_win > 0 && avg_post_win > avg_post_loss
        pct = ((avg_post_win / [avg_post_loss, 1].max - 1) * 100).round(0)
        if pct > 5
          @insights << {
            icon: "celebration",
            color: "#f9a825",
            title: "Celebration Spending",
            text: "You spend #{pct}% more after trading wins — celebration purchases may be eating into profits."
          }
        end
      end
    end

    # Weekend spending vs Monday trading
    mondays = @days.select { |d| d[:date].wday == 1 && d[:pnl] != 0 }
    if mondays.size >= 3
      high_weekend_mondays = []
      low_weekend_mondays = []

      weekend_spends = @days.select { |d| [0, 6].include?(d[:date].wday) }.map { |d| d[:spending] }
      median_weekend = weekend_spends.any? ? weekend_spends.sort[weekend_spends.size / 2] : 0

      mondays.each do |monday|
        sat = @days.find { |d| d[:date] == monday[:date] - 2 }
        sun = @days.find { |d| d[:date] == monday[:date] - 1 }
        weekend_total = (sat&.dig(:spending) || 0) + (sun&.dig(:spending) || 0)
        if weekend_total > median_weekend * 2
          high_weekend_mondays << monday[:pnl]
        else
          low_weekend_mondays << monday[:pnl]
        end
      end

      if high_weekend_mondays.size >= 2 && low_weekend_mondays.size >= 2
        avg_hw = high_weekend_mondays.sum / high_weekend_mondays.size.to_f
        avg_lw = low_weekend_mondays.sum / low_weekend_mondays.size.to_f

        if avg_lw > avg_hw
          @insights << {
            icon: "weekend",
            color: "var(--positive)",
            title: "Low-Spend Weekends = Better Mondays",
            text: "Your best Monday trading follows low-spending weekends (#{number_to_currency(avg_lw.round(2))} avg vs #{number_to_currency(avg_hw.round(2))} after high-spend weekends)."
          }
        else
          @insights << {
            icon: "weekend",
            color: "#f9a825",
            title: "Weekend Spending & Monday Trading",
            text: "High-spending weekends don't seem to hurt Monday performance (#{number_to_currency(avg_hw.round(2))} avg P&L)."
          }
        end
      end
    end

    # High spending days and trading P&L correlation
    trading_days = @days.select { |d| d[:pnl] != 0 && d[:spending] > 0 }
    if trading_days.size >= 5
      median_spend = trading_days.map { |d| d[:spending] }.sort[trading_days.size / 2]
      high_spend_trading = trading_days.select { |d| d[:spending] > median_spend }
      low_spend_trading = trading_days.select { |d| d[:spending] <= median_spend }

      if high_spend_trading.any? && low_spend_trading.any?
        hs_avg = high_spend_trading.sum { |d| d[:pnl] } / high_spend_trading.size.to_f
        ls_avg = low_spend_trading.sum { |d| d[:pnl] } / low_spend_trading.size.to_f

        if ls_avg > hs_avg && hs_avg < 0
          @insights << {
            icon: "warning",
            color: "var(--negative)",
            title: "High Spending = Emotional Trading",
            text: "High spending days correlate with negative trading P&L (#{number_to_currency(hs_avg.round(2))} avg). Emotional state may carry over to trading decisions."
          }
        elsif hs_avg > ls_avg
          @insights << {
            icon: "thumb_up",
            color: "var(--positive)",
            title: "Spending Doesn't Hurt Trading",
            text: "High-spending days actually correlate with better trading performance (#{number_to_currency(hs_avg.round(2))} avg)."
          }
        end
      end
    end

    # Correlation strength insight
    if @correlation.abs > 0.3
      direction = @correlation > 0 ? "positive" : "negative"
      strength = @correlation.abs > 0.6 ? "strong" : "moderate"
      @insights << {
        icon: "analytics",
        color: @correlation > 0 ? "var(--negative)" : "var(--positive)",
        title: "#{strength.capitalize} #{direction.capitalize} Correlation",
        text: "There is a #{strength} #{direction} correlation (#{@correlation}) between your daily spending and trading P&L. #{@correlation > 0 ? 'Higher spending tends to coincide with higher P&L days.' : 'Lower spending days tend to produce better trading results.'}"
      }
    end

    # Add a default insight if none found
    if @insights.empty?
      @insights << {
        icon: "info",
        color: "var(--primary)",
        title: "Not Enough Data Yet",
        text: "Keep trading and tracking spending — patterns will emerge as more data accumulates over the 90-day window."
      }
    end
  end

  def compute_spending_after_losses
    post_loss_spending = []
    post_win_spending = []
    neutral_spending = []

    @days.each_with_index do |day, i|
      next if i == 0
      prev = @days[i - 1]
      if prev[:pnl] < 0
        post_loss_spending << day[:spending]
      elsif prev[:pnl] > 0
        post_win_spending << day[:spending]
      else
        neutral_spending << day[:spending]
      end
    end

    @spending_after = {
      post_loss: {
        avg: post_loss_spending.any? ? (post_loss_spending.sum / post_loss_spending.size.to_f).round(2) : 0,
        count: post_loss_spending.size
      },
      post_win: {
        avg: post_win_spending.any? ? (post_win_spending.sum / post_win_spending.size.to_f).round(2) : 0,
        count: post_win_spending.size
      },
      neutral: {
        avg: neutral_spending.any? ? (neutral_spending.sum / neutral_spending.size.to_f).round(2) : 0,
        count: neutral_spending.size
      }
    }
  end

  def compute_trading_after_spending
    all_spending = @days.map { |d| d[:spending] }.select { |s| s > 0 }
    threshold = if all_spending.size >= 5
                  all_spending.sort[all_spending.size * 3 / 4] # 75th percentile
                else
                  all_spending.any? ? all_spending.sum / all_spending.size.to_f : 0
                end

    post_high_spend_pnl = []
    post_low_spend_pnl = []

    @days.each_with_index do |day, i|
      next if i == 0
      next if day[:pnl] == 0
      prev = @days[i - 1]
      if prev[:spending] >= threshold && threshold > 0
        post_high_spend_pnl << day[:pnl]
      elsif prev[:spending] > 0
        post_low_spend_pnl << day[:pnl]
      end
    end

    @trading_after_spending = {
      high_spend_threshold: threshold.round(2),
      post_high: {
        avg_pnl: post_high_spend_pnl.any? ? (post_high_spend_pnl.sum / post_high_spend_pnl.size.to_f).round(2) : 0,
        win_rate: post_high_spend_pnl.any? ? (post_high_spend_pnl.count { |p| p > 0 }.to_f / post_high_spend_pnl.size * 100).round(1) : 0,
        count: post_high_spend_pnl.size
      },
      post_low: {
        avg_pnl: post_low_spend_pnl.any? ? (post_low_spend_pnl.sum / post_low_spend_pnl.size.to_f).round(2) : 0,
        win_rate: post_low_spend_pnl.any? ? (post_low_spend_pnl.count { |p| p > 0 }.to_f / post_low_spend_pnl.size * 100).round(1) : 0,
        count: post_low_spend_pnl.size
      }
    }
  end

  def compute_monthly_comparison
    @monthly = {}
    @days.each do |day|
      month_key = day[:date].strftime("%Y-%m")
      @monthly[month_key] ||= { pnl: 0.0, spending: 0.0, trading_days: 0, spending_days: 0 }
      @monthly[month_key][:pnl] += day[:pnl]
      @monthly[month_key][:spending] += day[:spending]
      @monthly[month_key][:trading_days] += 1 if day[:pnl] != 0
      @monthly[month_key][:spending_days] += 1 if day[:spending] > 0
    end
  end
end

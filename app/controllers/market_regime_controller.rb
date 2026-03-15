class MarketRegimeController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = api_client.trades(per_page: 1000)
    all_trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    all_trades = all_trades.select { |t| t.is_a?(Hash) }
    @trades = all_trades.select { |t|
      t["status"]&.downcase == "closed" &&
      (t["exit_time"] || t["entry_time"]) &&
      t["pnl"]
    }

    return if @trades.empty?

    sorted_trades = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    # === Group trades by month ===
    monthly_groups = {}
    sorted_trades.each do |t|
      date_str = (t["exit_time"] || t["entry_time"]).to_s.slice(0, 7)
      next unless date_str.match?(/\A\d{4}-\d{2}\z/)
      monthly_groups[date_str] ||= []
      monthly_groups[date_str] << t
    end

    return if monthly_groups.empty?

    # === Analyze each month ===
    @monthly_regimes = {}
    monthly_groups.sort_by { |k, _| k }.each do |month, trades|
      pnls = trades.map { |t| t["pnl"].to_f }
      wins = trades.count { |t| t["pnl"].to_f > 0 }
      total = trades.count
      win_rate = total > 0 ? (wins.to_f / total * 100).round(1) : 0
      avg_pnl = total > 0 ? (pnls.sum / total).round(2) : 0
      total_pnl = pnls.sum.round(2)

      # Volatility: standard deviation of P&L
      mean = pnls.sum / [pnls.count, 1].max.to_f
      variance = pnls.map { |p| (p - mean) ** 2 }.sum / [pnls.count, 1].max.to_f
      std_dev = Math.sqrt(variance).round(2)

      # Direction analysis: check trade sides
      longs = trades.count { |t| t["side"]&.downcase == "long" }
      shorts = trades.count { |t| t["side"]&.downcase == "short" }
      long_pct = total > 0 ? (longs.to_f / total * 100).round(1) : 50
      short_pct = total > 0 ? (shorts.to_f / total * 100).round(1) : 50

      # Determine if trending or ranging
      if long_pct >= 70
        direction = "trending_up"
      elsif short_pct >= 70
        direction = "trending_down"
      else
        direction = "ranging"
      end

      # Position sizing (avg notional)
      position_sizes = trades.filter_map { |t|
        entry = t["entry_price"].to_f
        qty = t["quantity"].to_f
        entry > 0 && qty > 0 ? (entry * qty).round(2) : nil
      }
      avg_position_size = position_sizes.any? ? (position_sizes.sum / position_sizes.count).round(2) : 0

      # Profit factor
      gross_profit = trades.select { |t| t["pnl"].to_f > 0 }.sum { |t| t["pnl"].to_f }
      gross_loss = trades.select { |t| t["pnl"].to_f < 0 }.sum { |t| t["pnl"].to_f.abs }
      profit_factor = gross_loss > 0 ? (gross_profit / gross_loss).round(2) : (gross_profit > 0 ? 99.0 : 0.0)

      # Max drawdown for this month
      running = 0
      peak = 0
      max_dd = 0
      trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }.each do |t|
        running += t["pnl"].to_f
        peak = running if running > peak
        dd = peak - running
        max_dd = dd if dd > max_dd
      end

      @monthly_regimes[month] = {
        trades: total,
        wins: wins,
        win_rate: win_rate,
        avg_pnl: avg_pnl,
        total_pnl: total_pnl,
        std_dev: std_dev,
        direction: direction,
        long_pct: long_pct,
        short_pct: short_pct,
        avg_position_size: avg_position_size,
        profit_factor: profit_factor,
        max_drawdown: max_dd.round(2)
      }
    end

    # === Classify volatility (relative to all months) ===
    all_std_devs = @monthly_regimes.values.map { |r| r[:std_dev] }
    vol_sorted = all_std_devs.sort
    low_thresh = vol_sorted[vol_sorted.length / 3] || 0
    high_thresh = vol_sorted[(vol_sorted.length * 2 / 3)] || low_thresh

    @monthly_regimes.each do |month, data|
      vol_class = if data[:std_dev] <= low_thresh
                    "low_vol"
                  elsif data[:std_dev] >= high_thresh
                    "high_vol"
                  else
                    "medium_vol"
                  end
      data[:volatility] = vol_class

      # Combined regime label
      data[:regime] = if vol_class == "high_vol"
                        "high_volatility"
                      else
                        data[:direction]
                      end
    end

    # === Performance by regime ===
    regime_types = @monthly_regimes.values.map { |r| r[:regime] }.uniq.sort
    @regime_performance = {}
    regime_types.each do |regime|
      months = @monthly_regimes.select { |_, r| r[:regime] == regime }
      all_regime_trades = months.values.sum { |r| r[:trades] }
      all_regime_wins = months.values.sum { |r| r[:wins] }
      regime_win_rate = all_regime_trades > 0 ? (all_regime_wins.to_f / all_regime_trades * 100).round(1) : 0
      regime_avg_pnl = all_regime_trades > 0 ? (months.values.sum { |r| r[:total_pnl] } / all_regime_trades).round(2) : 0
      regime_total_pnl = months.values.sum { |r| r[:total_pnl] }.round(2)
      regime_max_dd = months.values.map { |r| r[:max_drawdown] }.max || 0

      # Profit factor across all months of this regime
      regime_gross_profit = months.values.sum { |r| r[:total_pnl] > 0 ? r[:total_pnl] : 0 }
      regime_gross_loss = months.values.sum { |r| r[:total_pnl] < 0 ? r[:total_pnl].abs : 0 }
      regime_pf = regime_gross_loss > 0 ? (regime_gross_profit / regime_gross_loss).round(2) : (regime_gross_profit > 0 ? 99.0 : 0.0)

      avg_position = months.values.select { |r| r[:avg_position_size] > 0 }.map { |r| r[:avg_position_size] }
      avg_pos = avg_position.any? ? (avg_position.sum / avg_position.count).round(2) : 0

      @regime_performance[regime] = {
        months: months.count,
        trades: all_regime_trades,
        win_rate: regime_win_rate,
        avg_pnl: regime_avg_pnl,
        total_pnl: regime_total_pnl,
        profit_factor: regime_pf,
        max_drawdown: regime_max_dd,
        avg_position_size: avg_pos
      }
    end

    # === Best / Worst regime ===
    if @regime_performance.any?
      @best_regime = @regime_performance.max_by { |_, v| v[:avg_pnl] }
      @worst_regime = @regime_performance.min_by { |_, v| v[:avg_pnl] }
    end

    # === Adaptation Score ===
    # Measures how much the trader adjusts position sizing between regimes
    regime_sizes = @regime_performance.values.map { |r| r[:avg_position_size] }.select { |s| s > 0 }
    if regime_sizes.length >= 2
      size_range = regime_sizes.max - regime_sizes.min
      size_mean = regime_sizes.sum / regime_sizes.count.to_f
      # Higher variation = better adaptation (they adjust sizing)
      adaptation_cv = size_mean > 0 ? (size_range / size_mean * 100).round(1) : 0
      @adaptation_score = [adaptation_cv, 100].min.round(0)
    else
      @adaptation_score = 0
    end

    # === Current Regime Estimate ===
    recent_trades = sorted_trades.last(20)
    if recent_trades.any?
      recent_pnls = recent_trades.map { |t| t["pnl"].to_f }
      recent_mean = recent_pnls.sum / recent_pnls.count.to_f
      recent_var = recent_pnls.map { |p| (p - recent_mean) ** 2 }.sum / recent_pnls.count.to_f
      recent_std = Math.sqrt(recent_var)

      recent_longs = recent_trades.count { |t| t["side"]&.downcase == "long" }
      recent_long_pct = (recent_longs.to_f / recent_trades.count * 100).round(1)

      # Compare recent std_dev to overall thresholds
      if recent_std >= high_thresh
        @current_regime = "high_volatility"
      elsif recent_long_pct >= 70
        @current_regime = "trending_up"
      elsif recent_long_pct <= 30
        @current_regime = "trending_down"
      else
        @current_regime = "ranging"
      end

      @current_regime_details = {
        trades: recent_trades.count,
        std_dev: recent_std.round(2),
        long_pct: recent_long_pct,
        win_rate: (recent_trades.count { |t| t["pnl"].to_f > 0 }.to_f / recent_trades.count * 100).round(1),
        avg_pnl: (recent_pnls.sum / recent_pnls.count).round(2)
      }
    else
      @current_regime = "unknown"
      @current_regime_details = {}
    end

    # === Months Analyzed ===
    @months_analyzed = @monthly_regimes.count

    # === Regime Timeline (sorted) ===
    @regime_timeline = @monthly_regimes.sort_by { |k, _| k }

    # === Trade frequency by regime ===
    @trade_frequency = @regime_performance.map { |regime, data|
      avg_per_month = data[:months] > 0 ? (data[:trades].to_f / data[:months]).round(1) : 0
      [regime, avg_per_month]
    }.to_h
  end

  private

  def regime_label(regime)
    case regime
    when "trending_up" then "Trending Up"
    when "trending_down" then "Trending Down"
    when "ranging" then "Ranging"
    when "high_volatility" then "High Volatility"
    else regime.to_s.titleize
    end
  end
  helper_method :regime_label

  def regime_color(regime)
    case regime
    when "trending_up" then "#4caf50"
    when "trending_down" then "#f44336"
    when "ranging" then "#ffc107"
    when "high_volatility" then "#ff9800"
    else "#9e9e9e"
    end
  end
  helper_method :regime_color

  def regime_icon(regime)
    case regime
    when "trending_up" then "trending_up"
    when "trending_down" then "trending_down"
    when "ranging" then "swap_horiz"
    when "high_volatility" then "bolt"
    else "help_outline"
    end
  end
  helper_method :regime_icon

  def regime_recommendation(regime, is_best)
    if is_best
      case regime
      when "trending_up"
        "You thrive when markets trend up. Consider increasing position sizes in confirmed uptrends and using trend-following entries."
      when "trending_down"
        "You perform best in downtrends. Your short-selling skills are strong -- lean into bearish setups when markets weaken."
      when "ranging"
        "Range-bound markets suit your style. Focus on mean-reversion strategies and well-defined support/resistance levels."
      when "high_volatility"
        "You capitalize on volatility. Keep using wide stops and quick profit-taking when vol spikes."
      else
        "Continue refining your approach in these conditions."
      end
    else
      case regime
      when "trending_up"
        "Uptrends challenge you. Try reducing size, using tighter stops, or waiting for pullbacks before entering."
      when "trending_down"
        "Bearish markets hurt your performance. Consider sitting out or hedging during confirmed downtrends."
      when "ranging"
        "Choppy markets erode your edge. Reduce trade frequency and wait for clearer setups in ranging conditions."
      when "high_volatility"
        "High volatility leads to larger losses. Cut position sizes by 30-50% and widen stops to avoid being stopped out."
      else
        "Review your strategy for these market conditions."
      end
    end
  end
  helper_method :regime_recommendation
end

class LossRecoveryController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  MONTE_CARLO_SIMS = 1000
  MONTE_CARLO_MAX_TRADES = 500

  def show
    trade_result = begin
      api_client.trades(per_page: 1000)
    rescue => e
      Rails.logger.error("LossRecovery: failed to fetch trades: #{e.message}")
      nil
    end

    all_trades = if trade_result.is_a?(Hash)
                   trade_result["trades"] || []
                 else
                   Array(trade_result)
                 end
    all_trades = all_trades.select { |t| t.is_a?(Hash) }

    @trades = all_trades
      .select { |t| t["status"]&.downcase == "closed" && t["pnl"].present? }
      .sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    return if @trades.empty?

    pnls = @trades.map { |t| t["pnl"].to_f }
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f < 0 }

    # === Equity curve and peak tracking ===
    cumulative = 0.0
    equity_curve = []
    @trades.each do |t|
      cumulative += t["pnl"].to_f
      equity_curve << cumulative.round(2)
    end
    @equity_curve = equity_curve

    peak = 0.0
    @equity_peak = 0.0
    equity_curve.each do |val|
      peak = val if val > peak
    end
    @equity_peak = peak

    # === Current drawdown ===
    @current_equity = equity_curve.last || 0.0
    @drawdown_amount = (@equity_peak - @current_equity).round(2)
    @drawdown_amount = 0.0 if @drawdown_amount < 0
    @drawdown_pct = @equity_peak > 0 ? (@drawdown_amount / @equity_peak * 100).round(2) : 0.0
    @in_drawdown = @drawdown_amount > 0

    # === Recovery needed % ===
    # If you lose X%, you need X/(100-X)*100 % to recover
    if @drawdown_pct > 0 && @drawdown_pct < 100
      @recovery_pct_needed = (@drawdown_pct / (100 - @drawdown_pct) * 100).round(2)
    elsif @drawdown_pct >= 100
      @recovery_pct_needed = Float::INFINITY
    else
      @recovery_pct_needed = 0.0
    end

    # === Core stats ===
    @total_trades = @trades.count
    @win_rate = @total_trades > 0 ? (wins.count.to_f / @total_trades * 100).round(1) : 0.0
    @avg_pnl = @total_trades > 0 ? (pnls.sum / @total_trades).round(2) : 0.0
    @avg_win = wins.any? ? (wins.sum { |t| t["pnl"].to_f } / wins.count).round(2) : 0.0
    @avg_loss = losses.any? ? (losses.sum { |t| t["pnl"].to_f.abs } / losses.count).round(2) : 0.0

    # === Estimated trades to recover at current expectancy ===
    @est_trades_to_recover = if @avg_pnl > 0 && @drawdown_amount > 0
                               (@drawdown_amount / @avg_pnl).ceil
                             else
                               nil
                             end

    # === Historical drawdowns ===
    compute_historical_drawdowns

    # === Recovery scenarios ===
    compute_recovery_scenarios

    # === Daily/weekly targets ===
    compute_recovery_targets

    # === Psychological checkpoints (milestones) ===
    compute_milestones

    # === Recovery rules ===
    @recovery_rules = build_recovery_rules

    # === Monte Carlo recovery probability ===
    compute_monte_carlo_probability(pnls)

    # === Breakeven analysis ===
    compute_breakeven_analysis

    # === Recovery path projection for SVG ===
    compute_recovery_projection
  end

  private

  def compute_historical_drawdowns
    @historical_drawdowns = []
    return if @equity_curve.empty?

    peak = 0.0
    in_dd = false
    dd_start_idx = 0
    dd_peak = 0.0

    @equity_curve.each_with_index do |val, i|
      if val > peak
        if in_dd
          # Recovered from drawdown
          dd_depth = dd_peak - @equity_curve[dd_start_idx..i].min
          dd_depth_pct = dd_peak > 0 ? (dd_depth / dd_peak * 100).round(1) : 0
          recovery_trades = i - dd_start_idx

          start_date = trade_date(@trades[dd_start_idx])
          end_date = trade_date(@trades[i])
          calendar_days = if start_date && end_date
                           (end_date - start_date).to_i
                         else
                           nil
                         end

          if dd_depth > 0
            @historical_drawdowns << {
              start_idx: dd_start_idx,
              depth: dd_depth.round(2),
              depth_pct: dd_depth_pct,
              recovery_trades: recovery_trades,
              calendar_days: calendar_days,
              start_date: start_date&.to_s,
              end_date: end_date&.to_s,
              recovered: true
            }
          end
          in_dd = false
        end
        peak = val
      elsif val < peak && !in_dd
        in_dd = true
        dd_start_idx = i
        dd_peak = peak
      end
    end

    # Current ongoing drawdown
    if in_dd
      dd_depth = dd_peak - @equity_curve[dd_start_idx..].min
      dd_depth_pct = dd_peak > 0 ? (dd_depth / dd_peak * 100).round(1) : 0
      start_date = trade_date(@trades[dd_start_idx])

      if dd_depth > 0
        @historical_drawdowns << {
          start_idx: dd_start_idx,
          depth: dd_depth.round(2),
          depth_pct: dd_depth_pct,
          recovery_trades: @equity_curve.length - dd_start_idx,
          calendar_days: start_date ? (Date.today - start_date).to_i : nil,
          start_date: start_date&.to_s,
          end_date: nil,
          recovered: false
        }
      end
    end

    @historical_drawdowns.sort_by! { |d| -(d[:depth]) }

    # Average recovery time
    recovered = @historical_drawdowns.select { |d| d[:recovered] }
    @avg_recovery_trades = if recovered.any?
                             (recovered.sum { |d| d[:recovery_trades] }.to_f / recovered.count).round(0)
                           else
                             nil
                           end
    @avg_recovery_days = if recovered.any? && recovered.all? { |d| d[:calendar_days] }
                           (recovered.sum { |d| d[:calendar_days] }.to_f / recovered.count).round(0)
                         else
                           nil
                         end
  end

  def compute_recovery_scenarios
    @recovery_scenarios = []
    return unless @drawdown_amount > 0

    avg_pnl_levels = []
    if @avg_pnl > 0
      avg_pnl_levels << { label: "Current Avg", value: @avg_pnl }
      avg_pnl_levels << { label: "+25%", value: (@avg_pnl * 1.25).round(2) }
      avg_pnl_levels << { label: "+50%", value: (@avg_pnl * 1.50).round(2) }
      avg_pnl_levels << { label: "+100%", value: (@avg_pnl * 2.0).round(2) }
    else
      # If currently negative expectancy, show hypothetical scenarios
      base = @avg_win > 0 ? (@avg_win * 0.3).round(2) : 50.0
      avg_pnl_levels << { label: "$#{number_with_delimiter(base.round(0))}/trade", value: base }
      avg_pnl_levels << { label: "$#{number_with_delimiter((base * 2).round(0))}/trade", value: base * 2 }
      avg_pnl_levels << { label: "$#{number_with_delimiter((base * 3).round(0))}/trade", value: base * 3 }
      avg_pnl_levels << { label: "$#{number_with_delimiter((base * 5).round(0))}/trade", value: base * 5 }
    end

    avg_pnl_levels.each do |level|
      trades_needed = (level[:value] > 0) ? (@drawdown_amount / level[:value]).ceil : nil
      @recovery_scenarios << {
        label: level[:label],
        avg_pnl: level[:value],
        trades_needed: trades_needed
      }
    end
  end

  def compute_recovery_targets
    @daily_target = nil
    @weekly_target = nil
    @monthly_target = nil
    return unless @drawdown_amount > 0

    # Compute average trading days per week from data
    trade_dates = @trades.filter_map { |t| trade_date(t) }.uniq.sort
    if trade_dates.length >= 2
      total_calendar_days = (trade_dates.last - trade_dates.first).to_i
      total_trading_days = trade_dates.length
      if total_calendar_days > 0
        trading_days_per_week = (total_trading_days.to_f / total_calendar_days * 7).round(1)
        trading_days_per_week = [trading_days_per_week, 5.0].min
      else
        trading_days_per_week = 5.0
      end
    else
      trading_days_per_week = 5.0
    end

    # Target: recover in 30 trading days
    recovery_days = 30
    @daily_target = (@drawdown_amount / recovery_days).round(2)
    @weekly_target = (@daily_target * trading_days_per_week).round(2)
    @monthly_target = (@daily_target * recovery_days).round(2)

    # Also a conservative target: recover in 60 trading days
    @daily_target_conservative = (@drawdown_amount / 60).round(2)
    @weekly_target_conservative = (@daily_target_conservative * trading_days_per_week).round(2)
  end

  def compute_milestones
    @milestones = []
    return unless @drawdown_amount > 0

    [25, 50, 75, 100].each do |pct|
      amount_recovered = (@drawdown_amount * pct / 100.0).round(2)
      equity_at_milestone = (@current_equity + amount_recovered).round(2)
      trades_est = if @avg_pnl > 0
                     (amount_recovered / @avg_pnl).ceil
                   else
                     nil
                   end

      @milestones << {
        pct: pct,
        amount: amount_recovered,
        equity_target: equity_at_milestone,
        trades_est: trades_est,
        label: pct == 100 ? "Full Recovery" : "#{pct}% Recovery"
      }
    end
  end

  def build_recovery_rules
    rules = []
    rules << {
      icon: "remove_circle_outline",
      title: "Reduce Position Size",
      description: "Cut position size by 25-50% during recovery. Smaller size reduces emotional pressure and limits further damage."
    }
    rules << {
      icon: "star",
      title: "A+ Setups Only",
      description: "Only trade your highest-conviction setups. Skip marginal opportunities. Quality over quantity drives recovery."
    }
    rules << {
      icon: "block",
      title: "No Revenge Trading",
      description: "Never increase size to \"make it back faster.\" Recovery is a marathon, not a sprint. Stick to the plan."
    }
    rules << {
      icon: "schedule",
      title: "Set Daily Loss Limits",
      description: "Cap daily losses at 50% of your daily target. Walk away if hit. Protect gains made during recovery."
    }
    rules << {
      icon: "edit_note",
      title: "Journal Every Trade",
      description: "Document every trade during recovery. Track what's working and cut what isn't. Data-driven recovery wins."
    }
    rules << {
      icon: "self_improvement",
      title: "Manage Your State",
      description: "Take breaks between trades. Avoid trading when anxious or frustrated. Mental clarity is your edge during recovery."
    }
    rules << {
      icon: "trending_up",
      title: "Focus on Process",
      description: "Track process metrics (followed rules, proper sizing) not just P&L. Good process leads to good results."
    }
    rules << {
      icon: "celebration",
      title: "Celebrate Milestones",
      description: "Acknowledge each 25% recovery checkpoint. Small wins build confidence and momentum for the full recovery."
    }
    rules
  end

  def compute_monte_carlo_probability(pnls)
    @mc_recovery_probs = []
    return unless @drawdown_amount > 0 && pnls.length >= 5

    trade_counts = [25, 50, 100, 150, 200, 300]
    srand(42) # Reproducible results

    trade_counts.each do |n_trades|
      next if n_trades > MONTE_CARLO_MAX_TRADES
      recoveries = 0

      MONTE_CARLO_SIMS.times do
        cumulative = 0.0
        recovered = false
        n_trades.times do
          cumulative += pnls.sample
          if cumulative >= @drawdown_amount
            recovered = true
            break
          end
        end
        recoveries += 1 if recovered
      end

      probability = (recoveries.to_f / MONTE_CARLO_SIMS * 100).round(1)
      @mc_recovery_probs << { trades: n_trades, probability: probability }
    end
  end

  def compute_breakeven_analysis
    @breakeven_rows = []
    return unless @drawdown_amount > 0

    avg_pnl_values = [10, 25, 50, 75, 100, 150, 200, 300, 500]
    avg_pnl_values.each do |avg|
      trades_needed = (@drawdown_amount / avg.to_f).ceil
      @breakeven_rows << { avg_pnl: avg, trades_needed: trades_needed }
    end
  end

  def compute_recovery_projection
    @projection_points = []
    return unless @drawdown_amount > 0

    # Project from current equity back to peak using avg_pnl
    proj_avg = @avg_pnl > 0 ? @avg_pnl : (@avg_win > 0 ? @avg_win * 0.3 : 50.0)
    proj_trades = ((@drawdown_amount / proj_avg).ceil + 5).clamp(10, 200)

    cumulative = @current_equity
    @projection_points << cumulative.round(2)
    proj_trades.times do
      cumulative += proj_avg
      @projection_points << [cumulative.round(2), @equity_peak].min
      break if cumulative >= @equity_peak
    end
  end

  def trade_date(trade)
    return nil unless trade
    date_str = (trade["exit_time"] || trade["entry_time"])&.to_s&.slice(0, 10)
    return nil unless date_str
    Date.parse(date_str)
  rescue
    nil
  end
end

class TradeSimulatorController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = begin
      api_client.trades(per_page: 1000)
    rescue => e
      Rails.logger.error("TradeSimulator: Failed to fetch trades: #{e.message}")
      nil
    end

    all_trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    all_trades = all_trades.select { |t| t.is_a?(Hash) }
    @trades = all_trades.select { |t| t["status"]&.downcase == "closed" && t["pnl"].present? }

    return if @trades.empty?

    # ── Baseline Stats ──
    pnls = @trades.map { |t| t["pnl"].to_f }
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f <= 0 }
    total_count = @trades.count
    total_pnl = pnls.sum

    @baseline = {
      total_pnl: total_pnl.round(2),
      trade_count: total_count,
      win_count: wins.count,
      loss_count: losses.count,
      win_rate: total_count > 0 ? (wins.count.to_f / total_count * 100).round(1) : 0,
      avg_win: wins.any? ? (wins.sum { |t| t["pnl"].to_f } / wins.count).round(2) : 0,
      avg_loss: losses.any? ? (losses.sum { |t| t["pnl"].to_f } / losses.count).round(2) : 0,
      avg_pnl: total_count > 0 ? (total_pnl / total_count).round(2) : 0,
      expectancy: 0,
      max_drawdown: 0
    }

    # Expectancy = (win_rate * avg_win) + (loss_rate * avg_loss)
    win_rate_dec = @baseline[:win_rate] / 100.0
    loss_rate_dec = 1.0 - win_rate_dec
    @baseline[:expectancy] = ((win_rate_dec * @baseline[:avg_win]) + (loss_rate_dec * @baseline[:avg_loss])).round(2)

    # Max drawdown
    @baseline[:max_drawdown] = compute_max_drawdown(pnls)

    # Total commissions
    total_fees = @trades.sum { |t| (t["commission"].to_f + t["fees"].to_f).abs }
    @baseline[:total_fees] = total_fees.round(2)

    # ── Build Scenarios ──
    @scenarios = []

    # --- Win Rate Improvement ---
    [5, 10].each do |pct|
      new_wr = [(@baseline[:win_rate] + pct), 100].min
      projected = project_pnl_for_win_rate(new_wr, @baseline, total_count)
      @scenarios << {
        name: "Win Rate +#{pct}%",
        category: "Win Rate",
        description: "What if your win rate improved by #{pct} percentage points (#{@baseline[:win_rate]}% -> #{new_wr}%)?",
        projected_pnl: projected[:pnl],
        projected_win_rate: new_wr,
        improvement_vs_baseline: projected[:pnl] - @baseline[:total_pnl],
        projected_drawdown: (projected[:drawdown_factor] * @baseline[:max_drawdown]).round(2),
        icon: "trending_up"
      }
    end

    # --- Better Risk/Reward ---
    # Bigger wins
    bigger_win_pnl = (wins.sum { |t| t["pnl"].to_f } * 1.2) + losses.sum { |t| t["pnl"].to_f }
    @scenarios << {
      name: "20% Larger Wins",
      category: "Risk/Reward",
      description: "What if your average winning trade was 20% larger (better exits)?",
      projected_pnl: bigger_win_pnl.round(2),
      projected_win_rate: @baseline[:win_rate],
      improvement_vs_baseline: (bigger_win_pnl - @baseline[:total_pnl]).round(2),
      projected_drawdown: @baseline[:max_drawdown],
      icon: "expand_less"
    }

    # Tighter stops
    tighter_loss_pnl = wins.sum { |t| t["pnl"].to_f } + (losses.sum { |t| t["pnl"].to_f } * 0.8)
    @scenarios << {
      name: "20% Smaller Losses",
      category: "Risk/Reward",
      description: "What if your average loss was 20% smaller (tighter stops)?",
      projected_pnl: tighter_loss_pnl.round(2),
      projected_win_rate: @baseline[:win_rate],
      improvement_vs_baseline: (tighter_loss_pnl - @baseline[:total_pnl]).round(2),
      projected_drawdown: (@baseline[:max_drawdown] * 0.8).round(2),
      icon: "compress"
    }

    # --- Position Sizing ---
    [1.5, 0.5].each do |factor|
      label = factor > 1 ? "50% Larger Positions" : "50% Smaller Positions"
      desc = factor > 1 ? "What if position sizes were 50% larger?" : "What if position sizes were 50% smaller (reduced risk)?"
      scaled_pnl = (@baseline[:total_pnl] * factor).round(2)
      scaled_dd = (@baseline[:max_drawdown] * factor).round(2)
      @scenarios << {
        name: label,
        category: "Position Sizing",
        description: desc,
        projected_pnl: scaled_pnl,
        projected_win_rate: @baseline[:win_rate],
        improvement_vs_baseline: (scaled_pnl - @baseline[:total_pnl]).round(2),
        projected_drawdown: scaled_dd,
        icon: factor > 1 ? "unfold_more" : "unfold_less"
      }
    end

    # --- Reduced Trading (Quality Filter) ---
    build_quality_filter_scenarios

    # --- Commission Reduction ---
    if total_fees > 0
      half_fee_pnl = (@baseline[:total_pnl] + total_fees * 0.5).round(2)
      @scenarios << {
        name: "50% Lower Fees",
        category: "Commissions",
        description: "What if commissions and fees were cut in half?",
        projected_pnl: half_fee_pnl,
        projected_win_rate: @baseline[:win_rate],
        improvement_vs_baseline: (total_fees * 0.5).round(2),
        projected_drawdown: @baseline[:max_drawdown],
        icon: "savings"
      }

      zero_fee_pnl = (@baseline[:total_pnl] + total_fees).round(2)
      @scenarios << {
        name: "Zero Fees",
        category: "Commissions",
        description: "What if there were no commissions or fees at all?",
        projected_pnl: zero_fee_pnl,
        projected_win_rate: @baseline[:win_rate],
        improvement_vs_baseline: total_fees.round(2),
        projected_drawdown: @baseline[:max_drawdown],
        icon: "money_off"
      }
    end

    # --- Compounding Projection ---
    @compounding = build_compounding_projection

    # --- Monte Carlo Simulation ---
    @monte_carlo = run_monte_carlo(pnls, 100)

    # Sort scenarios by improvement descending
    @scenarios.sort_by! { |s| -(s[:improvement_vs_baseline] || 0) }

    # Best scenario
    @best_scenario = @scenarios.first
    @scenarios_count = @scenarios.count

    # Highlight highest-impact
    @highest_impact = @scenarios.max_by { |s| s[:improvement_vs_baseline].to_f }

    # Actionable insights
    @insights = build_insights
  end

  private

  def project_pnl_for_win_rate(new_wr, baseline, count)
    new_wr_dec = new_wr / 100.0
    new_wins = (count * new_wr_dec).round
    new_losses = count - new_wins
    pnl = (new_wins * baseline[:avg_win]) + (new_losses * baseline[:avg_loss])
    # Drawdown roughly proportional to loss rate change
    old_loss_rate = 1.0 - (baseline[:win_rate] / 100.0)
    new_loss_rate = 1.0 - new_wr_dec
    dd_factor = old_loss_rate > 0 ? (new_loss_rate / old_loss_rate) : 1.0
    { pnl: pnl.round(2), drawdown_factor: dd_factor }
  end

  def compute_max_drawdown(pnls)
    peak = 0.0
    max_dd = 0.0
    running = 0.0
    pnls.each do |pnl|
      running += pnl
      peak = running if running > peak
      dd = peak - running
      max_dd = dd if dd > max_dd
    end
    max_dd.round(2)
  end

  def build_quality_filter_scenarios
    # Best symbol
    symbol_groups = @trades.group_by { |t| (t["symbol"] || "Unknown").upcase }
    best_symbol = nil
    best_symbol_wr = 0
    symbol_groups.each do |sym, trades|
      next if trades.count < 3
      wr = trades.count { |t| t["pnl"].to_f > 0 }.to_f / trades.count * 100
      if wr > best_symbol_wr
        best_symbol_wr = wr
        best_symbol = { name: sym, trades: trades, win_rate: wr.round(1) }
      end
    end

    if best_symbol && best_symbol[:trades].count >= 3
      sym_pnl = best_symbol[:trades].sum { |t| t["pnl"].to_f }
      sym_dd = compute_max_drawdown(best_symbol[:trades].map { |t| t["pnl"].to_f })
      # Project as if same number of trades but only best symbol
      projected = (sym_pnl.to_f / best_symbol[:trades].count * @baseline[:trade_count]).round(2)
      @scenarios << {
        name: "Only #{best_symbol[:name]}",
        category: "Quality Filter",
        description: "What if you only traded #{best_symbol[:name]}? (#{best_symbol[:win_rate]}% win rate, #{best_symbol[:trades].count} actual trades)",
        projected_pnl: projected,
        projected_win_rate: best_symbol[:win_rate],
        improvement_vs_baseline: (projected - @baseline[:total_pnl]).round(2),
        projected_drawdown: sym_dd,
        icon: "filter_alt"
      }
    end

    # Best time of day
    hour_groups = @trades.group_by { |t|
      time_str = t["entry_time"].to_s
      begin
        Time.parse(time_str).hour
      rescue
        nil
      end
    }.reject { |k, _| k.nil? }

    best_hour = nil
    best_hour_wr = 0
    hour_groups.each do |hr, trades|
      next if trades.count < 3
      wr = trades.count { |t| t["pnl"].to_f > 0 }.to_f / trades.count * 100
      if wr > best_hour_wr
        best_hour_wr = wr
        label = if hr == 0 then "12 AM"
                elsif hr < 12 then "#{hr} AM"
                elsif hr == 12 then "12 PM"
                else "#{hr - 12} PM"
                end
        best_hour = { name: label, trades: trades, win_rate: wr.round(1) }
      end
    end

    if best_hour && best_hour[:trades].count >= 3
      hr_pnl = best_hour[:trades].sum { |t| t["pnl"].to_f }
      hr_dd = compute_max_drawdown(best_hour[:trades].map { |t| t["pnl"].to_f })
      projected = (hr_pnl.to_f / best_hour[:trades].count * @baseline[:trade_count]).round(2)
      @scenarios << {
        name: "Only #{best_hour[:name]} Trades",
        category: "Quality Filter",
        description: "What if you only traded at #{best_hour[:name]}? (#{best_hour[:win_rate]}% win rate, #{best_hour[:trades].count} actual trades)",
        projected_pnl: projected,
        projected_win_rate: best_hour[:win_rate],
        improvement_vs_baseline: (projected - @baseline[:total_pnl]).round(2),
        projected_drawdown: hr_dd,
        icon: "schedule"
      }
    end

    # Remove losing trades scenario
    if @baseline[:loss_count] > 0
      winning_only_pnl = @trades.select { |t| t["pnl"].to_f > 0 }.sum { |t| t["pnl"].to_f }
      @scenarios << {
        name: "Eliminate Worst Trades",
        category: "Quality Filter",
        description: "What if you eliminated your #{@baseline[:loss_count]} losing trades entirely? (theoretical maximum)",
        projected_pnl: winning_only_pnl.round(2),
        projected_win_rate: 100.0,
        improvement_vs_baseline: (winning_only_pnl - @baseline[:total_pnl]).round(2),
        projected_drawdown: 0,
        icon: "block"
      }
    end
  end

  def build_compounding_projection
    return {} if @baseline[:trade_count] == 0

    # Average trades per month estimation
    dates = @trades.filter_map { |t|
      begin
        Date.parse((t["entry_time"] || t["exit_time"]).to_s.slice(0, 10))
      rescue
        nil
      end
    }
    return {} if dates.empty?

    date_range_days = [(dates.max - dates.min).to_i, 1].max
    trades_per_month = (@baseline[:trade_count].to_f / date_range_days * 30).round(1)
    trades_per_month = [trades_per_month, 1].max

    monthly_expectancy = @baseline[:expectancy] * trades_per_month

    # Project 1, 3, 5 years with compounding
    starting_capital = 10_000.0
    projections = {}
    [1, 3, 5].each do |years|
      months = years * 12
      balance = starting_capital
      curve = [balance.round(2)]
      months.times do
        monthly_return = monthly_expectancy / starting_capital
        balance *= (1 + monthly_return)
        balance = [balance, 0].max
        curve << balance.round(2)
      end
      projections[years] = {
        final_balance: balance.round(2),
        total_return: ((balance - starting_capital) / starting_capital * 100).round(1),
        curve: curve
      }
    end

    {
      starting_capital: starting_capital,
      trades_per_month: trades_per_month,
      monthly_expectancy: monthly_expectancy.round(2),
      projections: projections
    }
  end

  def run_monte_carlo(pnls, num_simulations)
    return {} if pnls.empty?

    rng = Random.new(42) # deterministic seed for reproducibility
    outcomes = []
    drawdowns = []

    num_simulations.times do
      # Resample trades with replacement
      resampled = Array.new(pnls.length) { pnls[rng.rand(pnls.length)] }
      total = resampled.sum
      dd = compute_max_drawdown(resampled)
      outcomes << total.round(2)
      drawdowns << dd.round(2)
    end

    outcomes.sort!
    drawdowns.sort!

    median_idx = outcomes.length / 2
    p5_idx = (outcomes.length * 0.05).to_i
    p95_idx = (outcomes.length * 0.95).to_i
    p25_idx = (outcomes.length * 0.25).to_i
    p75_idx = (outcomes.length * 0.75).to_i

    {
      outcomes: outcomes,
      drawdowns: drawdowns,
      median: outcomes[median_idx],
      mean: (outcomes.sum / outcomes.length).round(2),
      p5: outcomes[p5_idx],
      p95: outcomes[p95_idx],
      p25: outcomes[p25_idx],
      p75: outcomes[p75_idx],
      best: outcomes.last,
      worst: outcomes.first,
      positive_pct: (outcomes.count { |o| o > 0 }.to_f / outcomes.length * 100).round(1),
      median_drawdown: drawdowns[median_idx],
      worst_drawdown: drawdowns.last
    }
  end

  def build_insights
    insights = []

    return insights if @scenarios.empty?

    # Highest impact scenario
    best = @scenarios.max_by { |s| s[:improvement_vs_baseline].to_f }
    if best && best[:improvement_vs_baseline].to_f > 0
      insights << {
        icon: "emoji_objects",
        color: "#00897b",
        title: "Biggest Opportunity",
        text: "\"#{best[:name]}\" would add #{number_to_currency(best[:improvement_vs_baseline])} to your P&L. #{best[:description]}"
      }
    end

    # Win rate insight
    wr_scenarios = @scenarios.select { |s| s[:category] == "Win Rate" }
    if wr_scenarios.any?
      best_wr = wr_scenarios.max_by { |s| s[:improvement_vs_baseline].to_f }
      if best_wr
        insights << {
          icon: "speed",
          color: "#1976d2",
          title: "Win Rate Impact",
          text: "Improving your win rate to #{best_wr[:projected_win_rate]}% would increase total P&L by #{number_to_currency(best_wr[:improvement_vs_baseline])}."
        }
      end
    end

    # Risk/reward insight
    rr_scenarios = @scenarios.select { |s| s[:category] == "Risk/Reward" }
    if rr_scenarios.any?
      best_rr = rr_scenarios.max_by { |s| s[:improvement_vs_baseline].to_f }
      if best_rr
        insights << {
          icon: "balance",
          color: "#e65100",
          title: "Risk/Reward Optimization",
          text: "#{best_rr[:name]}: #{number_to_currency(best_rr[:improvement_vs_baseline])} improvement. Focus on #{best_rr[:name].downcase.include?('win') ? 'holding winners longer' : 'cutting losses faster'}."
        }
      end
    end

    # Drawdown insight
    dd_scenarios = @scenarios.select { |s| s[:projected_drawdown] < @baseline[:max_drawdown] && s[:improvement_vs_baseline].to_f > 0 }
    if dd_scenarios.any?
      best_dd = dd_scenarios.min_by { |s| s[:projected_drawdown] }
      if best_dd
        reduction = @baseline[:max_drawdown] - best_dd[:projected_drawdown]
        insights << {
          icon: "shield",
          color: "#2e7d32",
          title: "Drawdown Reduction",
          text: "\"#{best_dd[:name]}\" could reduce your max drawdown by #{number_to_currency(reduction)} while also improving P&L."
        }
      end
    end

    # Monte Carlo insight
    if @monte_carlo.is_a?(Hash) && @monte_carlo[:positive_pct]
      insights << {
        icon: "casino",
        color: "#7b1fa2",
        title: "Monte Carlo Confidence",
        text: "#{@monte_carlo[:positive_pct]}% of 100 simulated trade sequences were profitable. Median outcome: #{number_to_currency(@monte_carlo[:median])}."
      }
    end

    insights
  end
end

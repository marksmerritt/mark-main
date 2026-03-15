class RrOptimizerController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = begin
      api_client.trades(per_page: 1000)
    rescue => e
      Rails.logger.error("RrOptimizer: failed to fetch trades: #{e.message}")
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

    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f < 0 }
    @total_trades = @trades.count
    @win_rate = @total_trades > 0 ? (wins.count.to_f / @total_trades * 100).round(1) : 0.0
    @avg_win = wins.any? ? (wins.sum { |t| t["pnl"].to_f } / wins.count).round(2) : 0.0
    @avg_loss = losses.any? ? (losses.sum { |t| t["pnl"].to_f.abs } / losses.count).round(2) : 0.0

    # ── Compute R:R for each trade ──
    compute_trade_rr_data

    # ── R:R Distribution histogram ──
    compute_rr_distribution

    # ── Win rate by R:R bucket ──
    compute_win_rate_by_rr

    # ── Expectancy curve ──
    compute_expectancy_curve

    # ── Stop distance analysis ──
    compute_stop_analysis

    # ── Target distance analysis ──
    compute_target_analysis

    # ── Premature exits ──
    compute_premature_exits

    # ── Stop outs ──
    compute_stop_outs

    # ── R-multiple distribution ──
    compute_r_multiple_distribution

    # ── Kelly Criterion ──
    compute_kelly_criterion

    # ── Recommendations ──
    compute_recommendations
  end

  private

  def compute_trade_rr_data
    @rr_trades = @trades.filter_map do |t|
      entry = t["entry_price"].to_f
      stop = t["stop_loss"].to_f
      target = t["take_profit"].to_f
      exit_price = t["exit_price"].to_f
      pnl = t["pnl"].to_f
      qty = t["quantity"].to_f

      next nil unless entry > 0

      risk_per_share = stop > 0 ? (entry - stop).abs : nil
      reward_per_share = target > 0 ? (target - entry).abs : nil
      planned_rr = (risk_per_share && risk_per_share > 0 && reward_per_share) ? (reward_per_share / risk_per_share).round(2) : nil

      # Actual R:R achieved (using exit vs entry / risk)
      actual_move = exit_price > 0 ? (exit_price - entry).abs : nil
      actual_rr = (actual_move && risk_per_share && risk_per_share > 0) ? (actual_move / risk_per_share).round(2) : nil

      # R-multiple: P&L in terms of initial risk
      initial_risk_dollars = (risk_per_share && qty > 0) ? (risk_per_share * qty) : nil
      r_multiple = (initial_risk_dollars && initial_risk_dollars > 0) ? (pnl / initial_risk_dollars).round(2) : nil

      # Stop distance
      stop_distance_pct = (stop > 0 && entry > 0) ? ((entry - stop).abs / entry * 100).round(2) : nil
      stop_distance_dollars = (stop > 0) ? (entry - stop).abs.round(2) : nil

      # Target distance
      target_distance_pct = (target > 0 && entry > 0) ? ((target - entry).abs / entry * 100).round(2) : nil
      target_distance_dollars = (target > 0) ? (target - entry).abs.round(2) : nil

      {
        trade: t,
        entry: entry,
        stop: stop,
        target: target,
        exit_price: exit_price,
        pnl: pnl,
        qty: qty,
        risk_per_share: risk_per_share,
        reward_per_share: reward_per_share,
        planned_rr: planned_rr,
        actual_rr: actual_rr,
        r_multiple: r_multiple,
        initial_risk_dollars: initial_risk_dollars,
        stop_distance_pct: stop_distance_pct,
        stop_distance_dollars: stop_distance_dollars,
        target_distance_pct: target_distance_pct,
        target_distance_dollars: target_distance_dollars,
        win: pnl > 0
      }
    end
  end

  def compute_rr_distribution
    trades_with_rr = @rr_trades.select { |t| t[:planned_rr] }
    @rr_distribution = {}
    buckets = [[0, 0.5], [0.5, 1.0], [1.0, 1.5], [1.5, 2.0], [2.0, 2.5], [2.5, 3.0], [3.0, 4.0], [4.0, Float::INFINITY]]
    bucket_labels = ["<0.5", "0.5-1", "1-1.5", "1.5-2", "2-2.5", "2.5-3", "3-4", "4+"]

    buckets.each_with_index do |(low, high), i|
      matching = trades_with_rr.select { |t| t[:planned_rr] >= low && t[:planned_rr] < high }
      @rr_distribution[bucket_labels[i]] = matching.count
    end

    avg_rr_trades = trades_with_rr.select { |t| t[:planned_rr] }
    @avg_rr = avg_rr_trades.any? ? (avg_rr_trades.sum { |t| t[:planned_rr] } / avg_rr_trades.count).round(2) : 0.0
  end

  def compute_win_rate_by_rr
    trades_with_rr = @rr_trades.select { |t| t[:planned_rr] }
    @win_rate_by_rr = {}

    rr_buckets = {
      "1:1" => [0.8, 1.2],
      "1.5:1" => [1.2, 1.8],
      "2:1" => [1.8, 2.2],
      "2.5:1" => [2.2, 2.8],
      "3:1+" => [2.8, Float::INFINITY]
    }

    rr_buckets.each do |label, (low, high)|
      matching = trades_with_rr.select { |t| t[:planned_rr] >= low && t[:planned_rr] < high }
      if matching.any?
        w = matching.count { |t| t[:win] }
        wr = (w.to_f / matching.count * 100).round(1)
        avg_pnl = (matching.sum { |t| t[:pnl] } / matching.count).round(2)
        @win_rate_by_rr[label] = { win_rate: wr, count: matching.count, avg_pnl: avg_pnl }
      else
        @win_rate_by_rr[label] = { win_rate: 0, count: 0, avg_pnl: 0 }
      end
    end

    # Best R:R bucket
    active_buckets = @win_rate_by_rr.select { |_, v| v[:count] >= 3 }
    @best_rr_bucket = active_buckets.any? ? active_buckets.max_by { |_, v| v[:avg_pnl] }&.first : nil
    best_data = @best_rr_bucket ? @win_rate_by_rr[@best_rr_bucket] : nil
    @best_rr_win_rate = best_data ? best_data[:win_rate] : 0.0
  end

  def compute_expectancy_curve
    trades_with_rr = @rr_trades.select { |t| t[:planned_rr] }
    @expectancy_points = []
    @optimal_rr = nil
    @optimal_expectancy = -Float::INFINITY

    rr_levels = (0.5..5.0).step(0.25).to_a
    rr_levels.each do |rr_level|
      # Trades near this R:R level (within 0.5)
      matching = trades_with_rr.select { |t| (t[:planned_rr] - rr_level).abs <= 0.5 }
      next unless matching.count >= 2

      w = matching.count { |t| t[:win] }
      l = matching.count - w
      wr = w.to_f / matching.count
      lr = l.to_f / matching.count
      avg_w = w > 0 ? (matching.select { |t| t[:win] }.sum { |t| t[:pnl] } / w) : 0
      avg_l = l > 0 ? (matching.reject { |t| t[:win] }.sum { |t| t[:pnl].abs } / l) : 0

      expectancy = (wr * avg_w - lr * avg_l).round(2)

      @expectancy_points << { rr: rr_level, expectancy: expectancy, count: matching.count }

      if expectancy > @optimal_expectancy
        @optimal_expectancy = expectancy
        @optimal_rr = rr_level
      end
    end

    @optimal_expectancy = @optimal_expectancy == -Float::INFINITY ? 0.0 : @optimal_expectancy.round(2)
  end

  def compute_stop_analysis
    with_stops = @rr_trades.select { |t| t[:stop_distance_pct] && t[:stop_distance_pct] > 0 }
    @stop_analysis = []

    pct_buckets = {
      "< 1%" => [0, 1.0],
      "1-2%" => [1.0, 2.0],
      "2-3%" => [2.0, 3.0],
      "3-5%" => [3.0, 5.0],
      "5%+" => [5.0, Float::INFINITY]
    }

    pct_buckets.each do |label, (low, high)|
      matching = with_stops.select { |t| t[:stop_distance_pct] >= low && t[:stop_distance_pct] < high }
      if matching.any?
        w = matching.count { |t| t[:win] }
        wr = (w.to_f / matching.count * 100).round(1)
        avg_pnl = (matching.sum { |t| t[:pnl] } / matching.count).round(2)
        avg_dist = (matching.sum { |t| t[:stop_distance_pct] } / matching.count).round(2)
        @stop_analysis << { label: label, win_rate: wr, avg_pnl: avg_pnl, count: matching.count, avg_distance: avg_dist }
      end
    end

    @avg_stop_distance_pct = with_stops.any? ? (with_stops.sum { |t| t[:stop_distance_pct] } / with_stops.count).round(2) : 0.0
    @avg_stop_distance_dollars = with_stops.any? ? (with_stops.sum { |t| t[:stop_distance_dollars] } / with_stops.count).round(2) : 0.0
  end

  def compute_target_analysis
    with_targets = @rr_trades.select { |t| t[:target_distance_pct] && t[:target_distance_pct] > 0 }
    @target_analysis = []

    pct_buckets = {
      "< 2%" => [0, 2.0],
      "2-4%" => [2.0, 4.0],
      "4-6%" => [4.0, 6.0],
      "6-10%" => [6.0, 10.0],
      "10%+" => [10.0, Float::INFINITY]
    }

    pct_buckets.each do |label, (low, high)|
      matching = with_targets.select { |t| t[:target_distance_pct] >= low && t[:target_distance_pct] < high }
      if matching.any?
        w = matching.count { |t| t[:win] }
        wr = (w.to_f / matching.count * 100).round(1)
        avg_pnl = (matching.sum { |t| t[:pnl] } / matching.count).round(2)
        hit_rate = matching.any? ? (matching.count { |t|
          exit_p = t[:exit_price]
          target = t[:target]
          entry = t[:entry]
          next false unless exit_p > 0 && target > 0 && entry > 0
          side = (t[:trade]["side"] || t[:trade]["direction"] || "").downcase
          if side.include?("short")
            exit_p <= target
          else
            exit_p >= target
          end
        }.to_f / matching.count * 100).round(1) : 0.0
        @target_analysis << { label: label, win_rate: wr, avg_pnl: avg_pnl, count: matching.count, hit_rate: hit_rate }
      end
    end

    @avg_target_distance_pct = with_targets.any? ? (with_targets.sum { |t| t[:target_distance_pct] } / with_targets.count).round(2) : 0.0
  end

  def compute_premature_exits
    @premature_exits = []
    @premature_exit_count = 0

    @rr_trades.each do |t|
      trade = t[:trade]
      exit_p = t[:exit_price]
      target = t[:target]
      entry = t[:entry]
      pnl = t[:pnl]
      high_after = trade["high_after_exit"].to_f
      low_after = trade["low_after_exit"].to_f

      next unless exit_p > 0 && pnl > 0 # Only winning trades that exited early

      side = (trade["side"] || trade["direction"] || "").downcase
      is_long = side.include?("long") || side.include?("buy")
      is_short = side.include?("short") || side.include?("sell")

      # Check if price continued favorably after exit
      if is_long && target > 0 && exit_p < target && high_after > exit_p
        missed_gain = high_after - exit_p
        missed_pct = (missed_gain / entry * 100).round(2)
        if missed_pct > 0.5 # At least 0.5% left on table
          @premature_exit_count += 1
          @premature_exits << {
            symbol: trade["symbol"],
            exit_price: exit_p,
            target: target,
            high_after: high_after,
            missed_dollars: (missed_gain * t[:qty]).round(2),
            missed_pct: missed_pct
          } if @premature_exits.count < 10
        end
      elsif is_short && target > 0 && exit_p > target && low_after > 0 && low_after < exit_p
        missed_gain = exit_p - low_after
        missed_pct = (missed_gain / entry * 100).round(2)
        if missed_pct > 0.5
          @premature_exit_count += 1
          @premature_exits << {
            symbol: trade["symbol"],
            exit_price: exit_p,
            target: target,
            low_after: low_after,
            missed_dollars: (missed_gain * t[:qty]).round(2),
            missed_pct: missed_pct
          } if @premature_exits.count < 10
        end
      end
    end
  end

  def compute_stop_outs
    @stop_outs = []
    @stop_out_count = 0
    @tight_stop_count = 0

    @rr_trades.each do |t|
      trade = t[:trade]
      pnl = t[:pnl]
      stop = t[:stop]
      exit_p = t[:exit_price]
      entry = t[:entry]

      next unless pnl < 0 && stop > 0 && exit_p > 0

      side = (trade["side"] || trade["direction"] || "").downcase
      is_long = side.include?("long") || side.include?("buy")
      is_short = side.include?("short") || side.include?("sell")

      # Was stop hit?
      stop_hit = false
      if is_long && exit_p <= stop * 1.005 # Within 0.5% of stop
        stop_hit = true
      elsif is_short && exit_p >= stop * 0.995
        stop_hit = true
      end

      next unless stop_hit
      @stop_out_count += 1

      # Did the trade reverse after hitting stop?
      high_after = trade["high_after_exit"].to_f
      low_after = trade["low_after_exit"].to_f

      reversed = false
      reversal_amount = 0.0
      if is_long && high_after > entry
        reversed = true
        reversal_amount = ((high_after - entry) / entry * 100).round(2)
        @tight_stop_count += 1
      elsif is_short && low_after > 0 && low_after < entry
        reversed = true
        reversal_amount = ((entry - low_after) / entry * 100).round(2)
        @tight_stop_count += 1
      end

      @stop_outs << {
        symbol: trade["symbol"],
        stop: stop,
        exit_price: exit_p,
        entry: entry,
        reversed: reversed,
        reversal_pct: reversal_amount,
        stop_distance_pct: t[:stop_distance_pct]
      } if @stop_outs.count < 10
    end

    @tight_stop_pct = @stop_out_count > 0 ? (@tight_stop_count.to_f / @stop_out_count * 100).round(1) : 0.0
  end

  def compute_r_multiple_distribution
    with_r = @rr_trades.select { |t| t[:r_multiple] }
    @r_multiple_distribution = {}

    r_buckets = [
      ["-3+", -Float::INFINITY, -3.0],
      ["-3 to -2", -3.0, -2.0],
      ["-2 to -1", -2.0, -1.0],
      ["-1 to 0", -1.0, 0.0],
      ["0 to 1R", 0.0, 1.0],
      ["1R to 2R", 1.0, 2.0],
      ["2R to 3R", 2.0, 3.0],
      ["3R+", 3.0, Float::INFINITY]
    ]

    r_buckets.each do |label, low, high|
      matching = with_r.select { |t| t[:r_multiple] >= low && t[:r_multiple] < high }
      @r_multiple_distribution[label] = matching.count
    end

    @avg_r_multiple = with_r.any? ? (with_r.sum { |t| t[:r_multiple] } / with_r.count).round(2) : 0.0
    @median_r_multiple = if with_r.any?
                           sorted = with_r.map { |t| t[:r_multiple] }.sort
                           mid = sorted.length / 2
                           sorted.length.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(2)
                         else
                           0.0
                         end
  end

  def compute_kelly_criterion
    wins = @rr_trades.select { |t| t[:win] }
    losses = @rr_trades.reject { |t| t[:win] }

    if wins.any? && losses.any?
      win_prob = wins.count.to_f / @rr_trades.count
      avg_win_amount = wins.sum { |t| t[:pnl] } / wins.count
      avg_loss_amount = losses.sum { |t| t[:pnl].abs } / losses.count

      if avg_loss_amount > 0
        win_loss_ratio = avg_win_amount / avg_loss_amount
        # Kelly % = W - (1 - W) / R
        @kelly_pct = ((win_prob - (1.0 - win_prob) / win_loss_ratio) * 100).round(2)
        @kelly_pct = [[@kelly_pct, 0].max, 100].min
        @half_kelly = (@kelly_pct / 2.0).round(2)
        @quarter_kelly = (@kelly_pct / 4.0).round(2)
        @win_loss_ratio = win_loss_ratio.round(2)
      else
        @kelly_pct = 0.0
        @half_kelly = 0.0
        @quarter_kelly = 0.0
        @win_loss_ratio = 0.0
      end
    else
      @kelly_pct = 0.0
      @half_kelly = 0.0
      @quarter_kelly = 0.0
      @win_loss_ratio = 0.0
    end
  end

  def compute_recommendations
    @recommendations = []

    # 1. R:R recommendation
    if @optimal_rr && @optimal_rr > 0
      @recommendations << {
        icon: "balance",
        title: "Target #{@optimal_rr}:1 Risk/Reward",
        detail: "Your data shows the highest expectancy ($#{number_with_delimiter(@optimal_expectancy)}) at #{@optimal_rr}:1 R:R. Focus on setups that offer at least this ratio."
      }
    end

    # 2. Stop distance recommendation
    best_stop = @stop_analysis.select { |s| s[:count] >= 3 }.max_by { |s| s[:avg_pnl] } if @stop_analysis.any?
    if best_stop
      @recommendations << {
        icon: "shield",
        title: "Use #{best_stop[:label]} Stop Distances",
        detail: "Stops at #{best_stop[:label]} from entry produce #{best_stop[:win_rate]}% win rate and $#{number_with_delimiter(best_stop[:avg_pnl])} avg P&L across #{best_stop[:count]} trades."
      }
    end

    # 3. Tight stops warning
    if @tight_stop_pct > 30 && @stop_out_count >= 5
      @recommendations << {
        icon: "warning",
        title: "Widen Your Stops",
        detail: "#{@tight_stop_pct}% of stop-outs reversed back through your entry. Your stops may be too tight — consider giving trades more room to breathe."
      }
    end

    # 4. Premature exit warning
    if @premature_exit_count > 3
      total_missed = @premature_exits.sum { |e| e[:missed_dollars] }
      @recommendations << {
        icon: "trending_up",
        title: "Let Winners Run",
        detail: "#{@premature_exit_count} winning trades exited before target, leaving $#{number_with_delimiter(total_missed.round(0))} on the table. Consider trailing stops instead of early exits."
      }
    end

    # 5. Kelly position sizing
    if @kelly_pct > 0
      @recommendations << {
        icon: "tune",
        title: "Size Positions at #{@half_kelly}% (Half Kelly)",
        detail: "Full Kelly suggests #{@kelly_pct}% of account per trade, but half Kelly (#{@half_kelly}%) provides a smoother equity curve with ~75% of the growth rate."
      }
    end

    # 6. Best R:R bucket
    if @best_rr_bucket
      data = @win_rate_by_rr[@best_rr_bucket]
      if data && data[:count] >= 3
        @recommendations << {
          icon: "star",
          title: "Focus on #{@best_rr_bucket} Setups",
          detail: "Your #{@best_rr_bucket} R:R trades average $#{number_with_delimiter(data[:avg_pnl])} with a #{data[:win_rate]}% win rate across #{data[:count]} trades."
        }
      end
    end

    # Keep top 3
    @recommendations = @recommendations.first(3)
  end
end

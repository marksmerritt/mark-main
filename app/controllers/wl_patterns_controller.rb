class WlPatternsController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = begin
      api_client.trades(per_page: 1000)
    rescue => e
      Rails.logger.error("WlPatterns: failed to fetch trades: #{e.message}")
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

    return if @trades.length < 3

    pnls = @trades.map { |t| t["pnl"].to_f }
    @total_trades = @trades.count
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f <= 0 }
    @overall_win_rate = @total_trades > 0 ? (wins.count.to_f / @total_trades * 100).round(1) : 0

    # Build the W/L sequence
    @sequence = @trades.map { |t| t["pnl"].to_f > 0 ? "W" : "L" }

    # ── Streak Analysis ──
    compute_streaks

    # ── Conditional Probabilities ──
    compute_conditional_probabilities

    # ── After-Result Behavior ──
    compute_after_result_behavior

    # ── Pattern Detection ──
    compute_pattern_detection

    # ── Cluster Analysis & Runs Test ──
    compute_runs_test

    # ── Size Changes After Results ──
    compute_size_changes

    # ── Time Between Trades ──
    compute_time_gaps

    # ── Comeback Rate ──
    compute_comeback_rate
  end

  private

  def compute_streaks
    @win_streaks = []
    @loss_streaks = []
    current_type = nil
    current_length = 0

    @sequence.each do |result|
      if result == current_type
        current_length += 1
      else
        if current_type == "W" && current_length > 0
          @win_streaks << current_length
        elsif current_type == "L" && current_length > 0
          @loss_streaks << current_length
        end
        current_type = result
        current_length = 1
      end
    end
    # Capture last streak
    if current_type == "W" && current_length > 0
      @win_streaks << current_length
    elsif current_type == "L" && current_length > 0
      @loss_streaks << current_length
    end

    @max_win_streak = @win_streaks.any? ? @win_streaks.max : 0
    @max_loss_streak = @loss_streaks.any? ? @loss_streaks.max : 0
    @avg_win_streak = @win_streaks.any? ? (@win_streaks.sum.to_f / @win_streaks.count).round(1) : 0
    @avg_loss_streak = @loss_streaks.any? ? (@loss_streaks.sum.to_f / @loss_streaks.count).round(1) : 0

    # Streak length distribution (for chart)
    all_streaks = @win_streaks.map { |s| { type: "W", length: s } } +
                  @loss_streaks.map { |s| { type: "L", length: s } }
    max_len = all_streaks.any? ? all_streaks.map { |s| s[:length] }.max : 0
    @streak_distribution = (1..[max_len, 10].min).map { |len|
      {
        length: len,
        win_count: @win_streaks.count { |s| s == len },
        loss_count: @loss_streaks.count { |s| s == len }
      }
    }
  end

  def compute_conditional_probabilities
    # P(W|W): probability of a win given previous was a win
    after_win_results = []
    after_loss_results = []
    after_ww_results = []
    after_ll_results = []
    after_wl_results = []
    after_lw_results = []

    @sequence.each_with_index do |result, i|
      next if i == 0

      prev = @sequence[i - 1]
      if prev == "W"
        after_win_results << result
      else
        after_loss_results << result
      end

      next if i < 2
      prev2 = @sequence[i - 2]
      if prev2 == "W" && prev == "W"
        after_ww_results << result
      elsif prev2 == "L" && prev == "L"
        after_ll_results << result
      elsif prev2 == "W" && prev == "L"
        after_wl_results << result
      elsif prev2 == "L" && prev == "W"
        after_lw_results << result
      end
    end

    @p_win_after_win = after_win_results.any? ? (after_win_results.count("W").to_f / after_win_results.count * 100).round(1) : nil
    @p_win_after_loss = after_loss_results.any? ? (after_loss_results.count("W").to_f / after_loss_results.count * 100).round(1) : nil
    @p_win_after_ww = after_ww_results.any? ? (after_ww_results.count("W").to_f / after_ww_results.count * 100).round(1) : nil
    @p_win_after_ll = after_ll_results.any? ? (after_ll_results.count("W").to_f / after_ll_results.count * 100).round(1) : nil
    @p_win_after_wl = after_wl_results.any? ? (after_wl_results.count("W").to_f / after_wl_results.count * 100).round(1) : nil
    @p_win_after_lw = after_lw_results.any? ? (after_lw_results.count("W").to_f / after_lw_results.count * 100).round(1) : nil

    @after_win_count = after_win_results.count
    @after_loss_count = after_loss_results.count
    @after_ww_count = after_ww_results.count
    @after_ll_count = after_ll_results.count
  end

  def compute_after_result_behavior
    # Performance on the trade immediately after a win vs after a loss
    after_win_pnls = []
    after_loss_pnls = []

    @trades.each_with_index do |trade, i|
      next if i == 0
      prev_pnl = @trades[i - 1]["pnl"].to_f
      current_pnl = trade["pnl"].to_f

      if prev_pnl > 0
        after_win_pnls << current_pnl
      else
        after_loss_pnls << current_pnl
      end
    end

    @after_win_avg_pnl = after_win_pnls.any? ? (after_win_pnls.sum / after_win_pnls.count.to_f).round(2) : 0
    @after_loss_avg_pnl = after_loss_pnls.any? ? (after_loss_pnls.sum / after_loss_pnls.count.to_f).round(2) : 0
    @after_win_win_rate = after_win_pnls.any? ? (after_win_pnls.count { |p| p > 0 }.to_f / after_win_pnls.count * 100).round(1) : 0
    @after_loss_win_rate = after_loss_pnls.any? ? (after_loss_pnls.count { |p| p > 0 }.to_f / after_loss_pnls.count * 100).round(1) : 0
    @after_win_trade_count = after_win_pnls.count
    @after_loss_trade_count = after_loss_pnls.count

    # Best/worst after each
    @after_win_best = after_win_pnls.any? ? after_win_pnls.max.round(2) : 0
    @after_win_worst = after_win_pnls.any? ? after_win_pnls.min.round(2) : 0
    @after_loss_best = after_loss_pnls.any? ? after_loss_pnls.max.round(2) : 0
    @after_loss_worst = after_loss_pnls.any? ? after_loss_pnls.min.round(2) : 0
  end

  def compute_pattern_detection
    # Find common W/L subsequences of length 2-4 and check frequency vs expected
    @patterns = []
    n = @sequence.length
    win_prob = @sequence.count("W").to_f / n

    [2, 3, 4].each do |len|
      pattern_counts = Hash.new(0)
      (0..(n - len)).each do |i|
        pat = @sequence[i, len].join
        pattern_counts[pat] += 1
      end

      total_windows = n - len + 1
      pattern_counts.each do |pat, count|
        # Expected frequency assuming independence
        expected_prob = pat.chars.map { |c| c == "W" ? win_prob : (1 - win_prob) }.reduce(:*)
        expected_count = (expected_prob * total_windows).round(1)
        ratio = expected_count > 0 ? (count.to_f / expected_count).round(2) : 0

        next unless count >= 3 # Only show patterns with enough occurrences

        @patterns << {
          pattern: pat,
          count: count,
          expected: expected_count,
          ratio: ratio,
          length: len,
          above_chance: ratio > 1.3,
          below_chance: ratio < 0.7
        }
      end
    end

    @patterns.sort_by! { |p| [-p[:length], -p[:ratio]] }
  end

  def compute_runs_test
    # A "run" is a maximal sequence of identical elements
    n = @sequence.length
    n_w = @sequence.count("W")
    n_l = @sequence.count("L")

    # Count runs
    runs = 1
    (1...n).each do |i|
      runs += 1 if @sequence[i] != @sequence[i - 1]
    end
    @observed_runs = runs

    # Expected runs under independence
    if n_w > 0 && n_l > 0
      @expected_runs = ((2.0 * n_w * n_l) / n + 1).round(1)
      numerator = 2.0 * n_w * n_l * (2.0 * n_w * n_l - n)
      denominator = n * n * (n - 1).to_f
      if denominator > 0 && numerator > 0
        std_dev = Math.sqrt(numerator / denominator)
        @runs_z_score = std_dev > 0 ? ((@observed_runs - @expected_runs) / std_dev).round(2) : 0
      else
        @runs_z_score = 0
      end
    else
      @expected_runs = n.to_f
      @runs_z_score = 0
    end

    # Interpretation
    @runs_interpretation = if @runs_z_score.abs < 1.96
      "random"
    elsif @runs_z_score > 1.96
      "alternating" # More runs than expected = anti-clustering
    else
      "clustered" # Fewer runs than expected = clustering
    end

    @clustering_label = case @runs_interpretation
    when "clustered" then "Clustered"
    when "alternating" then "Anti-Clustered"
    else "Randomly Distributed"
    end
  end

  def compute_size_changes
    after_win_sizes = []
    after_loss_sizes = []

    @trades.each_with_index do |trade, i|
      next if i == 0
      prev_pnl = @trades[i - 1]["pnl"].to_f

      entry = trade["entry_price"].to_f
      qty = trade["quantity"].to_f
      size = entry > 0 && qty > 0 ? (entry * qty) : nil
      next unless size

      if prev_pnl > 0
        after_win_sizes << size
      else
        after_loss_sizes << size
      end
    end

    @avg_size_after_win = after_win_sizes.any? ? (after_win_sizes.sum / after_win_sizes.count.to_f).round(2) : nil
    @avg_size_after_loss = after_loss_sizes.any? ? (after_loss_sizes.sum / after_loss_sizes.count.to_f).round(2) : nil

    # Overall average for comparison
    all_sizes = @trades.filter_map { |t|
      e = t["entry_price"].to_f
      q = t["quantity"].to_f
      e > 0 && q > 0 ? e * q : nil
    }
    @avg_size_overall = all_sizes.any? ? (all_sizes.sum / all_sizes.count.to_f).round(2) : nil

    if @avg_size_after_win && @avg_size_after_loss && @avg_size_after_loss > 0
      @size_change_pct = ((@avg_size_after_win - @avg_size_after_loss) / @avg_size_after_loss * 100).round(1)
    else
      @size_change_pct = nil
    end

    @size_after_win_count = after_win_sizes.count
    @size_after_loss_count = after_loss_sizes.count
  end

  def compute_time_gaps
    after_win_gaps = []
    after_loss_gaps = []

    @trades.each_with_index do |trade, i|
      next if i == 0
      prev_trade = @trades[i - 1]
      prev_pnl = prev_trade["pnl"].to_f

      prev_exit = prev_trade["exit_time"].to_s
      curr_entry = trade["entry_time"].to_s
      next if prev_exit.empty? || curr_entry.empty?

      begin
        prev_t = Time.parse(prev_exit)
        curr_t = Time.parse(curr_entry)
        gap_hours = ((curr_t - prev_t) / 3600.0).abs
        # Only count reasonable gaps (not multi-day)
        next if gap_hours > 168 # skip gaps > 1 week

        if prev_pnl > 0
          after_win_gaps << gap_hours
        else
          after_loss_gaps << gap_hours
        end
      rescue
        next
      end
    end

    @avg_gap_after_win = after_win_gaps.any? ? (after_win_gaps.sum / after_win_gaps.count.to_f).round(1) : nil
    @avg_gap_after_loss = after_loss_gaps.any? ? (after_loss_gaps.sum / after_loss_gaps.count.to_f).round(1) : nil
    @gap_after_win_count = after_win_gaps.count
    @gap_after_loss_count = after_loss_gaps.count

    if @avg_gap_after_win && @avg_gap_after_loss && @avg_gap_after_win > 0
      @gap_ratio = (@avg_gap_after_loss / @avg_gap_after_win).round(2)
    else
      @gap_ratio = nil
    end
  end

  def compute_comeback_rate
    # Group trades into daily sessions, check how many sessions that went negative recovered to positive
    sessions = @trades.group_by { |t|
      date_str = (t["entry_time"] || t["exit_time"]).to_s.slice(0, 10)
      begin
        Date.parse(date_str)
      rescue
        nil
      end
    }.reject { |k, _| k.nil? }

    @session_count = sessions.count
    sessions_that_went_negative = 0
    sessions_that_recovered = 0

    sessions.each do |_date, day_trades|
      sorted = day_trades.sort_by { |t| t["entry_time"] || t["exit_time"] || "" }
      cumulative = 0.0
      was_negative = false
      ended_positive = false

      sorted.each do |t|
        cumulative += t["pnl"].to_f
        was_negative = true if cumulative < 0
      end
      ended_positive = cumulative > 0

      if was_negative
        sessions_that_went_negative += 1
        sessions_that_recovered += 1 if ended_positive
      end
    end

    @sessions_went_negative = sessions_that_went_negative
    @sessions_recovered = sessions_that_recovered
    @comeback_rate = sessions_that_went_negative > 0 ? (sessions_that_recovered.to_f / sessions_that_went_negative * 100).round(1) : nil
  end
end

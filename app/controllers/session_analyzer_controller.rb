class SessionAnalyzerController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = api_client.trades(per_page: 1000)
    all_trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    all_trades = all_trades.select { |t| t.is_a?(Hash) }
    @trades = all_trades.select { |t|
      t["status"]&.downcase == "closed" &&
        t["pnl"].present? &&
        (t["entry_time"].present? || t["exit_time"].present?)
    }

    return if @trades.empty?

    # ── Group trades into daily sessions ──
    @sessions = build_sessions(@trades)
    return if @sessions.empty?

    # ── Aggregate stats ──
    session_pnls = @sessions.map { |s| s[:total_pnl] }
    @total_sessions = @sessions.count
    @avg_session_pnl = (session_pnls.sum / @total_sessions.to_f).round(2)
    @best_session = @sessions.max_by { |s| s[:total_pnl] }
    @worst_session = @sessions.min_by { |s| s[:total_pnl] }
    @positive_sessions = @sessions.count { |s| s[:total_pnl] > 0 }
    @negative_sessions = @sessions.count { |s| s[:total_pnl] < 0 }
    @session_win_rate = (@positive_sessions.to_f / @total_sessions * 100).round(1)

    # Session streak (consecutive profitable sessions, most recent)
    @session_streak = compute_session_streak(@sessions)

    # ── Optimal session length ──
    @pnl_by_trade_count = compute_pnl_by_trade_count(@sessions)

    # ── First trade analysis ──
    @first_trade_stats = compute_first_trade_stats(@sessions)

    # ── Tilt detection ──
    @tilt_sessions = @sessions.select { |s| s[:tilt_detected] }

    # ── Session grade distribution ──
    @grade_distribution = %w[A B C D F].map { |g|
      { grade: g, count: @sessions.count { |s| s[:grade] == g } }
    }

    # Average session trades for overtrading threshold
    @avg_trades_per_session = (@sessions.sum { |s| s[:trade_count] } / @total_sessions.to_f).round(1)
  end

  private

  def build_sessions(trades)
    # Group by date (use entry_time or exit_time)
    grouped = trades.group_by { |t|
      date_str = (t["entry_time"] || t["exit_time"]).to_s.slice(0, 10)
      begin
        Date.parse(date_str)
      rescue
        nil
      end
    }.reject { |k, _| k.nil? }

    avg_trades = grouped.any? ? (grouped.values.sum { |ts| ts.count } / grouped.count.to_f) : 0

    grouped.sort_by { |date, _| date }.map { |date, day_trades|
      build_session(date, day_trades, avg_trades)
    }
  end

  def build_session(date, trades, avg_trades_per_day)
    pnls = trades.map { |t| t["pnl"].to_f }
    total_pnl = pnls.sum.round(2)
    wins = trades.count { |t| t["pnl"].to_f > 0 }
    losses = trades.count { |t| t["pnl"].to_f < 0 }
    trade_count = trades.count
    win_rate = trade_count > 0 ? (wins.to_f / trade_count * 100).round(1) : 0

    largest_win = pnls.select { |p| p > 0 }.max || 0
    largest_loss = pnls.select { |p| p < 0 }.min || 0

    # Duration: first entry to last exit
    times = trades.filter_map { |t|
      begin
        [
          t["entry_time"].present? ? Time.parse(t["entry_time"].to_s) : nil,
          t["exit_time"].present? ? Time.parse(t["exit_time"].to_s) : nil
        ]
      rescue
        nil
      end
    }.flatten.compact

    duration_minutes = if times.length >= 2
      ((times.max - times.min) / 60.0).round(0).to_i
    else
      0
    end

    # Net R-multiple
    r_multiples = trades.filter_map { |t|
      entry = t["entry_price"].to_f
      stop = t["stop_loss"].to_f
      pnl = t["pnl"].to_f
      qty = t["quantity"].to_f
      next nil unless entry > 0 && stop > 0 && qty > 0
      risk_per_share = (entry - stop).abs
      total_risk = risk_per_share * qty
      total_risk > 0 ? (pnl / total_risk).round(2) : nil
    }
    net_r = r_multiples.any? ? r_multiples.sum.round(2) : nil

    # Emotional progression: did P&L improve or deteriorate?
    sorted_trades = trades.sort_by { |t| t["entry_time"] || t["exit_time"] || "" }
    cumulative = []
    running = 0
    sorted_trades.each do |t|
      running += t["pnl"].to_f
      cumulative << running
    end

    progression = if cumulative.length >= 2
      first_half = cumulative[0...(cumulative.length / 2)]
      second_half = cumulative[(cumulative.length / 2)..]
      first_avg = first_half.any? ? first_half.last : 0
      second_trend = second_half.any? ? second_half.last - first_avg : 0
      if second_trend > 0
        :improving
      elsif second_trend < 0
        :deteriorating
      else
        :flat
      end
    else
      :flat
    end

    # Tilt detection: performance degraded after a loss
    tilt_detected = detect_tilt(sorted_trades)

    # Overtrading flag
    overtrading = avg_trades_per_day > 0 && trade_count > avg_trades_per_day * 1.5

    # Session grade
    grade = compute_session_grade(win_rate, total_pnl, trade_count, tilt_detected, overtrading, net_r)

    {
      date: date,
      trade_count: trade_count,
      total_pnl: total_pnl,
      win_rate: win_rate,
      wins: wins,
      losses: losses,
      largest_win: largest_win.round(2),
      largest_loss: largest_loss.round(2),
      duration_minutes: duration_minutes,
      net_r: net_r,
      progression: progression,
      tilt_detected: tilt_detected,
      overtrading: overtrading,
      grade: grade,
      cumulative_pnl: cumulative.map { |v| v.round(2) }
    }
  end

  def detect_tilt(sorted_trades)
    return false if sorted_trades.length < 3

    # Look for pattern: after a loss, subsequent trades also lose
    had_loss = false
    post_loss_results = []

    sorted_trades.each do |t|
      pnl = t["pnl"].to_f
      if had_loss
        post_loss_results << pnl
      end
      had_loss = true if pnl < 0
    end

    return false if post_loss_results.empty?

    # Tilt if majority of post-loss trades are also losses
    post_loss_losses = post_loss_results.count { |p| p < 0 }
    post_loss_losses.to_f / post_loss_results.count > 0.65
  end

  def compute_session_grade(win_rate, total_pnl, trade_count, tilt, overtrading, net_r)
    score = 50 # baseline

    # Win rate contribution
    score += case win_rate
             when 70.. then 20
             when 55..69.9 then 15
             when 45..54.9 then 5
             when 30..44.9 then -10
             else -20
             end

    # P&L contribution
    if total_pnl > 0
      score += 15
    elsif total_pnl < 0
      score -= 15
    end

    # R-multiple contribution
    if net_r
      score += case net_r
               when 2.. then 10
               when 1..1.99 then 5
               when 0..0.99 then 0
               else -10
               end
    end

    # Penalties
    score -= 15 if tilt
    score -= 10 if overtrading

    case score
    when 80.. then "A"
    when 65..79 then "B"
    when 50..64 then "C"
    when 35..49 then "D"
    else "F"
    end
  end

  def compute_session_streak(sessions)
    return 0 if sessions.empty?

    # Count from most recent going backwards
    streak = 0
    sessions.reverse_each do |s|
      break unless s[:total_pnl] > 0
      streak += 1
    end
    streak
  end

  def compute_pnl_by_trade_count(sessions)
    grouped = sessions.group_by { |s| s[:trade_count] }
    grouped.map { |count, sess|
      avg_pnl = (sess.sum { |s| s[:total_pnl] } / sess.count.to_f).round(2)
      { trade_count: count, avg_pnl: avg_pnl, session_count: sess.count }
    }.sort_by { |d| d[:trade_count] }
  end

  def compute_first_trade_stats(sessions)
    first_pnls = []
    rest_pnls = []

    sessions.each do |s|
      # We need original trades to get first trade -- reconstruct from cumulative
      # First trade P&L is cumulative_pnl[0], rest is total - first
      next if s[:cumulative_pnl].nil? || s[:cumulative_pnl].empty?

      first_pnl = s[:cumulative_pnl].first
      rest_total = s[:total_pnl] - first_pnl

      first_pnls << first_pnl
      rest_pnls << rest_total if s[:trade_count] > 1
    end

    first_wins = first_pnls.count { |p| p > 0 }
    first_avg = first_pnls.any? ? (first_pnls.sum / first_pnls.count.to_f).round(2) : 0
    first_win_rate = first_pnls.any? ? (first_wins.to_f / first_pnls.count * 100).round(1) : 0

    rest_avg = rest_pnls.any? ? (rest_pnls.sum / rest_pnls.count.to_f).round(2) : 0

    {
      first_avg_pnl: first_avg,
      first_win_rate: first_win_rate,
      first_count: first_pnls.count,
      rest_avg_pnl: rest_avg,
      rest_count: rest_pnls.count
    }
  end
end

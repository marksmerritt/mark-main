class TradingMentorController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 1000) }
    threads[:journal] = Thread.new { api_client.journal_entries(per_page: 200) }

    trade_result = threads[:trades].value rescue nil
    @trades = if trade_result.is_a?(Hash)
                trade_result["trades"] || []
              else
                Array(trade_result)
              end
    @trades = @trades.select { |t| t.is_a?(Hash) }
    @trades = @trades.select { |t| t["pnl"].present? }
    @trades = @trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    journal_result = threads[:journal].value rescue nil
    @journal_entries = if journal_result.is_a?(Hash)
                         journal_result["journal_entries"] || []
                       else
                         Array(journal_result)
                       end
    @journal_entries = @journal_entries.select { |e| e.is_a?(Hash) }

    return if @trades.empty?

    analyze_strengths
    analyze_weaknesses
    detect_behavioral_patterns
    generate_recommendations
    build_progress_report
    build_focus_areas
    audit_trading_rules
    calculate_tilt_risk
    build_overall_assessment
  end

  private

  # ── Strength Analysis ──────────────────────────────────────────────

  def analyze_strengths
    @strengths = []

    # 1. High win-rate symbols
    symbol_stats = {}
    @trades.each do |t|
      sym = t["symbol"].to_s
      next if sym.empty?
      symbol_stats[sym] ||= { wins: 0, total: 0, pnl: 0.0 }
      symbol_stats[sym][:total] += 1
      symbol_stats[sym][:wins] += 1 if t["pnl"].to_f > 0
      symbol_stats[sym][:pnl] += t["pnl"].to_f
    end
    top_symbols = symbol_stats.select { |_, v| v[:total] >= 3 }
                              .sort_by { |_, v| -(v[:wins].to_f / v[:total]) }
                              .first(3)
    if top_symbols.any? && top_symbols.first[1][:wins].to_f / top_symbols.first[1][:total] >= 0.55
      best = top_symbols.first
      wr = (best[1][:wins].to_f / best[1][:total] * 100).round(1)
      @strengths << {
        title: "Strong Symbol Selection",
        detail: "#{best[0]} has a #{wr}% win rate across #{best[1][:total]} trades (#{number_to_currency(best[1][:pnl])} P&L).",
        icon: "trending_up"
      }
    end

    # 2. Consistent position sizing
    position_sizes = @trades.filter_map { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      entry > 0 && qty > 0 ? entry * qty : nil
    }
    if position_sizes.length >= 5
      avg_size = position_sizes.sum / position_sizes.count
      std_dev = Math.sqrt(position_sizes.map { |s| (s - avg_size) ** 2 }.sum / position_sizes.count)
      cv = avg_size > 0 ? (std_dev / avg_size * 100).round(1) : 999
      if cv <= 35
        @strengths << {
          title: "Consistent Position Sizing",
          detail: "Position sizes vary by only #{cv}% — strong risk discipline.",
          icon: "tune"
        }
      end
    end

    # 3. Good stop loss usage
    trades_with_stops = @trades.count { |t| t["stop_loss"].to_f > 0 }
    stop_pct = @trades.any? ? (trades_with_stops.to_f / @trades.count * 100).round(1) : 0
    if stop_pct >= 70
      @strengths << {
        title: "Disciplined Stop Loss Usage",
        detail: "#{stop_pct}% of trades have a stop loss set (#{trades_with_stops}/#{@trades.count}).",
        icon: "shield"
      }
    end

    # 4. Positive profit factor
    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f < 0 }
    gross_profit = wins.sum { |t| t["pnl"].to_f }
    gross_loss = losses.sum { |t| t["pnl"].to_f.abs }
    pf = gross_loss > 0 ? (gross_profit / gross_loss).round(2) : (gross_profit > 0 ? 99 : 0)
    if pf >= 1.5
      @strengths << {
        title: "Strong Profit Factor",
        detail: "Profit factor of #{pf} — earning $#{pf} for every $1 lost.",
        icon: "paid"
      }
    end

    # 5. Good win rate overall
    overall_wr = @trades.any? ? (wins.count.to_f / @trades.count * 100).round(1) : 0
    if overall_wr >= 55
      @strengths << {
        title: "Above-Average Win Rate",
        detail: "#{overall_wr}% win rate across #{@trades.count} trades.",
        icon: "check_circle"
      }
    end

    # 6. Good risk/reward
    trades_with_rr = @trades.select { |t| t["stop_loss"].to_f > 0 && t["take_profit"].to_f > 0 && t["entry_price"].to_f > 0 }
    if trades_with_rr.length >= 3
      avg_rr = trades_with_rr.map { |t|
        entry = t["entry_price"].to_f
        stop = t["stop_loss"].to_f
        target = t["take_profit"].to_f
        risk = (entry - stop).abs
        reward = (target - entry).abs
        risk > 0 ? reward / risk : 0
      }.sum / trades_with_rr.count
      if avg_rr >= 1.8
        @strengths << {
          title: "Favorable Risk/Reward Setups",
          detail: "Average planned R:R of #{avg_rr.round(2)}:1 across #{trades_with_rr.count} trades with defined targets.",
          icon: "balance"
        }
      end
    end

    # 7. Journaling consistency
    if @journal_entries.length >= 10
      @strengths << {
        title: "Active Journaling Habit",
        detail: "#{@journal_entries.length} journal entries show strong self-reflection practice.",
        icon: "edit_note"
      }
    end

    @strengths = @strengths.first(3)
  end

  # ── Weakness Analysis ──────────────────────────────────────────────

  def analyze_weaknesses
    @weaknesses = []

    # 1. Overtrading detection (days with 5+ trades)
    daily_counts = {}
    @trades.each do |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next unless date
      daily_counts[date] ||= { count: 0, pnl: 0.0 }
      daily_counts[date][:count] += 1
      daily_counts[date][:pnl] += t["pnl"].to_f
    end
    overtrade_days = daily_counts.select { |_, v| v[:count] >= 5 }
    if overtrade_days.any?
      avg_pnl_overtrade = overtrade_days.values.sum { |v| v[:pnl] } / overtrade_days.count
      normal_days = daily_counts.reject { |_, v| v[:count] >= 5 }
      avg_pnl_normal = normal_days.any? ? normal_days.values.sum { |v| v[:pnl] } / normal_days.count : 0
      if avg_pnl_overtrade < avg_pnl_normal
        @weaknesses << {
          title: "Overtrading Tendency",
          detail: "#{overtrade_days.count} days with 5+ trades averaged #{number_to_currency(avg_pnl_overtrade)} vs #{number_to_currency(avg_pnl_normal)} on normal days.",
          icon: "speed"
        }
      end
    end

    # 2. Poor stop loss usage
    trades_with_stops = @trades.count { |t| t["stop_loss"].to_f > 0 }
    stop_pct = @trades.any? ? (trades_with_stops.to_f / @trades.count * 100).round(1) : 0
    if stop_pct < 70
      @weaknesses << {
        title: "Insufficient Stop Loss Usage",
        detail: "Only #{stop_pct}% of trades have stops set — #{@trades.count - trades_with_stops} trades unprotected.",
        icon: "remove_moderator"
      }
    end

    # 3. Poor risk/reward
    trades_with_rr = @trades.select { |t| t["stop_loss"].to_f > 0 && t["take_profit"].to_f > 0 && t["entry_price"].to_f > 0 }
    if trades_with_rr.length >= 3
      avg_rr = trades_with_rr.map { |t|
        entry = t["entry_price"].to_f
        stop = t["stop_loss"].to_f
        target = t["take_profit"].to_f
        risk = (entry - stop).abs
        reward = (target - entry).abs
        risk > 0 ? reward / risk : 0
      }.sum / trades_with_rr.count
      if avg_rr < 1.5
        @weaknesses << {
          title: "Unfavorable Risk/Reward",
          detail: "Average R:R of #{avg_rr.round(2)}:1 — aim for at least 2:1.",
          icon: "balance"
        }
      end
    elsif trades_with_rr.length < 3 && @trades.count >= 10
      @weaknesses << {
        title: "Missing Targets & Stops",
        detail: "Only #{trades_with_rr.count} of #{@trades.count} trades have both stop loss and take profit defined.",
        icon: "gps_off"
      }
    end

    # 4. Low win rate
    wins = @trades.count { |t| t["pnl"].to_f > 0 }
    wr = @trades.any? ? (wins.to_f / @trades.count * 100).round(1) : 0
    if wr < 45
      @weaknesses << {
        title: "Below-Average Win Rate",
        detail: "#{wr}% win rate — tighten entry criteria or be more selective.",
        icon: "trending_down"
      }
    end

    # 5. Worst trading hours
    hourly_stats = {}
    @trades.each do |t|
      time_str = (t["entry_time"] || "").to_s
      next if time_str.empty?
      hour = time_str[11, 2].to_i rescue nil
      next unless hour
      hourly_stats[hour] ||= { wins: 0, total: 0, pnl: 0.0 }
      hourly_stats[hour][:total] += 1
      hourly_stats[hour][:wins] += 1 if t["pnl"].to_f > 0
      hourly_stats[hour][:pnl] += t["pnl"].to_f
    end
    worst_hours = hourly_stats.select { |_, v| v[:total] >= 3 }
                              .sort_by { |_, v| v[:pnl] }
                              .first(1)
    if worst_hours.any? && worst_hours.first[1][:pnl] < 0
      wh = worst_hours.first
      hr_wr = (wh[1][:wins].to_f / wh[1][:total] * 100).round(0)
      formatted_hour = format_hour(wh[0])
      @weaknesses << {
        title: "Weak Trading Hour: #{formatted_hour}",
        detail: "#{hr_wr}% win rate and #{number_to_currency(wh[1][:pnl])} P&L across #{wh[1][:total]} trades at #{formatted_hour}.",
        icon: "schedule"
      }
    end

    # 6. Inconsistent sizing
    position_sizes = @trades.filter_map { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      entry > 0 && qty > 0 ? entry * qty : nil
    }
    if position_sizes.length >= 5
      avg_size = position_sizes.sum / position_sizes.count
      std_dev = Math.sqrt(position_sizes.map { |s| (s - avg_size) ** 2 }.sum / position_sizes.count)
      cv = avg_size > 0 ? (std_dev / avg_size * 100).round(1) : 0
      if cv > 50
        @weaknesses << {
          title: "Erratic Position Sizing",
          detail: "Position sizes vary by #{cv}% — standardize your sizing approach.",
          icon: "tune"
        }
      end
    end

    @weaknesses = @weaknesses.first(3)
  end

  # ── Behavioral Pattern Detection ──────────────────────────────────

  def detect_behavioral_patterns
    @patterns = []

    detect_revenge_trading
    detect_overtrading
    detect_time_of_day_bias
    detect_day_of_week_bias
    detect_loss_aversion
    detect_winner_cutting
  end

  def detect_revenge_trading
    revenge_trades = []
    sorted = @trades.sort_by { |t| t["entry_time"] || "" }

    sorted.each_with_index do |trade, idx|
      next if idx == 0
      next unless trade["pnl"].to_f != 0

      prev = sorted[idx - 1]
      next unless prev["pnl"].to_f < 0

      prev_exit = parse_time(prev["exit_time"])
      curr_entry = parse_time(trade["entry_time"])
      next unless prev_exit && curr_entry

      diff_minutes = ((curr_entry - prev_exit) * 24 * 60).to_f
      if diff_minutes >= 0 && diff_minutes <= 30
        prev_size = (prev["quantity"].to_f * prev["entry_price"].to_f).abs
        curr_size = (trade["quantity"].to_f * trade["entry_price"].to_f).abs
        larger = prev_size > 0 && curr_size > prev_size * 1.1
        revenge_trades << { trade: trade, larger: larger, gap_min: diff_minutes.round(0) }
      end
    end

    if revenge_trades.any?
      larger_count = revenge_trades.count { |r| r[:larger] }
      revenge_pnl = revenge_trades.sum { |r| r[:trade]["pnl"].to_f }
      win_count = revenge_trades.count { |r| r[:trade]["pnl"].to_f > 0 }
      wr = (win_count.to_f / revenge_trades.count * 100).round(0)

      @patterns << {
        name: "Revenge Trading",
        icon: "local_fire_department",
        color: "#e53935",
        severity: revenge_trades.count >= 5 ? "high" : "medium",
        evidence: "#{revenge_trades.count} trades entered within 30 minutes of a loss. #{larger_count} were with larger size. Win rate: #{wr}%, P&L: #{number_to_currency(revenge_pnl)}.",
        recommendation: "After a loss, enforce a mandatory 30-minute cooling-off period. Write in your journal before re-entering."
      }
    end
  end

  def detect_overtrading
    daily_counts = {}
    @trades.each do |t|
      date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next unless date
      daily_counts[date] ||= { count: 0, pnl: 0.0 }
      daily_counts[date][:count] += 1
      daily_counts[date][:pnl] += t["pnl"].to_f
    end

    heavy_days = daily_counts.select { |_, v| v[:count] >= 5 }
    normal_days = daily_counts.reject { |_, v| v[:count] >= 5 }

    if heavy_days.any? && normal_days.any?
      avg_heavy = heavy_days.values.sum { |v| v[:pnl] } / heavy_days.count
      avg_normal = normal_days.values.sum { |v| v[:pnl] } / normal_days.count
      heavy_wr = heavy_days.count { |_, v| v[:pnl] > 0 }.to_f / heavy_days.count * 100

      @patterns << {
        name: "Overtrading",
        icon: "speed",
        color: "#ff9800",
        severity: avg_heavy < 0 ? "high" : "low",
        evidence: "#{heavy_days.count} days with 5+ trades. Avg P&L on heavy days: #{number_to_currency(avg_heavy)} vs #{number_to_currency(avg_normal)} on normal days. Heavy day win rate: #{heavy_wr.round(0)}%.",
        recommendation: "Set a daily trade limit of 3-4 trades. Quality over quantity — fewer, higher-conviction setups."
      }
    end
  end

  def detect_time_of_day_bias
    hourly_stats = {}
    @trades.each do |t|
      time_str = (t["entry_time"] || "").to_s
      next if time_str.empty?
      hour = time_str[11, 2].to_i rescue nil
      next unless hour
      hourly_stats[hour] ||= { wins: 0, total: 0, pnl: 0.0 }
      hourly_stats[hour][:total] += 1
      hourly_stats[hour][:wins] += 1 if t["pnl"].to_f > 0
      hourly_stats[hour][:pnl] += t["pnl"].to_f
    end

    valid_hours = hourly_stats.select { |_, v| v[:total] >= 3 }
    return if valid_hours.empty?

    best_hour = valid_hours.max_by { |_, v| v[:pnl] }
    worst_hour = valid_hours.min_by { |_, v| v[:pnl] }

    if best_hour && worst_hour && best_hour[0] != worst_hour[0]
      best_wr = (best_hour[1][:wins].to_f / best_hour[1][:total] * 100).round(0)
      worst_wr = (worst_hour[1][:wins].to_f / worst_hour[1][:total] * 100).round(0)

      @patterns << {
        name: "Time-of-Day Bias",
        icon: "schedule",
        color: "#1565c0",
        severity: worst_hour[1][:pnl] < -100 ? "medium" : "low",
        evidence: "Best hour: #{format_hour(best_hour[0])} (#{best_wr}% WR, #{number_to_currency(best_hour[1][:pnl])}). Worst hour: #{format_hour(worst_hour[0])} (#{worst_wr}% WR, #{number_to_currency(worst_hour[1][:pnl])}).",
        recommendation: "Focus trading during #{format_hour(best_hour[0])}. Consider reducing size or skipping #{format_hour(worst_hour[0])} trades."
      }
    end
  end

  def detect_day_of_week_bias
    day_stats = {}
    day_names = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday]
    @trades.each do |t|
      date_str = (t["entry_time"] || t["exit_time"])&.to_s&.slice(0, 10)
      next unless date_str
      date = Date.parse(date_str) rescue nil
      next unless date
      dow = date.wday
      day_stats[dow] ||= { wins: 0, total: 0, pnl: 0.0 }
      day_stats[dow][:total] += 1
      day_stats[dow][:wins] += 1 if t["pnl"].to_f > 0
      day_stats[dow][:pnl] += t["pnl"].to_f
    end

    valid_days = day_stats.select { |_, v| v[:total] >= 3 }
    return if valid_days.length < 2

    best_day = valid_days.max_by { |_, v| v[:pnl] }
    worst_day = valid_days.min_by { |_, v| v[:pnl] }

    if best_day[0] != worst_day[0]
      best_wr = (best_day[1][:wins].to_f / best_day[1][:total] * 100).round(0)
      worst_wr = (worst_day[1][:wins].to_f / worst_day[1][:total] * 100).round(0)

      @patterns << {
        name: "Day-of-Week Bias",
        icon: "date_range",
        color: "#7b1fa2",
        severity: worst_day[1][:pnl] < -200 ? "medium" : "low",
        evidence: "Best day: #{day_names[best_day[0]]} (#{best_wr}% WR, #{number_to_currency(best_day[1][:pnl])}). Worst day: #{day_names[worst_day[0]]} (#{worst_wr}% WR, #{number_to_currency(worst_day[1][:pnl])}).",
        recommendation: "Trade with more conviction on #{day_names[best_day[0]]}s. Be cautious or reduce size on #{day_names[worst_day[0]]}s."
      }
    end
  end

  def detect_loss_aversion
    # Detect holding losers too long vs cutting winners short
    winning_durations = []
    losing_durations = []

    @trades.each do |t|
      entry_time = parse_time(t["entry_time"])
      exit_time = parse_time(t["exit_time"])
      next unless entry_time && exit_time
      duration_hours = ((exit_time - entry_time) * 24).to_f
      next unless duration_hours > 0

      if t["pnl"].to_f > 0
        winning_durations << duration_hours
      elsif t["pnl"].to_f < 0
        losing_durations << duration_hours
      end
    end

    if winning_durations.length >= 3 && losing_durations.length >= 3
      avg_win_dur = winning_durations.sum / winning_durations.count
      avg_loss_dur = losing_durations.sum / losing_durations.count

      if avg_loss_dur > avg_win_dur * 1.5
        @patterns << {
          name: "Loss Aversion / Holding Losers",
          icon: "hourglass_bottom",
          color: "#e65100",
          severity: "medium",
          evidence: "Average losing trade held #{avg_loss_dur.round(1)}h vs #{avg_win_dur.round(1)}h for winners. You may be holding losers hoping they recover.",
          recommendation: "Set time-based stops. If a trade hasn't worked within your planned timeframe, exit regardless."
        }
      end
    end
  end

  def detect_winner_cutting
    # Detect cutting winners too short (exits before target reached)
    trades_with_targets = @trades.select { |t|
      t["take_profit"].to_f > 0 && t["entry_price"].to_f > 0 && t["exit_price"].to_f > 0 && t["pnl"].to_f > 0
    }

    if trades_with_targets.length >= 5
      early_exits = trades_with_targets.count { |t|
        entry = t["entry_price"].to_f
        exit_p = t["exit_price"].to_f
        target = t["take_profit"].to_f
        side = t["side"].to_s.downcase

        if side == "short"
          potential = (entry - target).abs
          actual = (entry - exit_p).abs
        else
          potential = (target - entry).abs
          actual = (exit_p - entry).abs
        end

        potential > 0 && actual < potential * 0.7
      }

      pct_early = (early_exits.to_f / trades_with_targets.count * 100).round(0)
      if pct_early >= 40
        @patterns << {
          name: "Cutting Winners Short",
          icon: "content_cut",
          color: "#f57f17",
          severity: "medium",
          evidence: "#{pct_early}% of winning trades (#{early_exits}/#{trades_with_targets.count}) exited before reaching 70% of the target price.",
          recommendation: "Trust your analysis. Consider scaling out: take partial profits at 1R, let the rest run to target."
        }
      end
    end
  end

  # ── Actionable Recommendations ─────────────────────────────────────

  def generate_recommendations
    @recommendations = []

    wins = @trades.count { |t| t["pnl"].to_f > 0 }
    losses = @trades.count { |t| t["pnl"].to_f < 0 }
    wr = @trades.any? ? (wins.to_f / @trades.count * 100).round(1) : 0

    # Based on win rate
    if wr < 45
      @recommendations << {
        title: "Tighten Entry Criteria",
        detail: "Your #{wr}% win rate suggests loose entries. Add one more confirmation signal before entering trades.",
        icon: "filter_alt"
      }
    end

    # Based on stops
    stop_pct = @trades.any? ? (@trades.count { |t| t["stop_loss"].to_f > 0 }.to_f / @trades.count * 100).round(0) : 0
    if stop_pct < 90
      @recommendations << {
        title: "Always Set Stop Losses",
        detail: "#{100 - stop_pct}% of trades lack stops. Define your exit before entering every trade.",
        icon: "shield"
      }
    end

    # Based on journal entries
    if @journal_entries.length < 5
      @recommendations << {
        title: "Start Journaling Consistently",
        detail: "Only #{@journal_entries.length} journal entries found. Write a brief entry after each trading session.",
        icon: "edit_note"
      }
    end

    # Based on revenge trading pattern
    if @patterns.any? { |p| p[:name] == "Revenge Trading" }
      @recommendations << {
        title: "Implement a Cooling-Off Rule",
        detail: "After any loss, wait at least 30 minutes before placing another trade. Use this time to journal.",
        icon: "timer"
      }
    end

    # Based on overtrading
    if @patterns.any? { |p| p[:name] == "Overtrading" }
      @recommendations << {
        title: "Set a Daily Trade Limit",
        detail: "Cap yourself at 3-4 trades per day. Focus on your highest-conviction setups only.",
        icon: "block"
      }
    end

    # Position sizing
    position_sizes = @trades.filter_map { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      entry > 0 && qty > 0 ? entry * qty : nil
    }
    if position_sizes.length >= 5
      avg_size = position_sizes.sum / position_sizes.count
      std_dev = Math.sqrt(position_sizes.map { |s| (s - avg_size) ** 2 }.sum / position_sizes.count)
      cv = avg_size > 0 ? (std_dev / avg_size * 100).round(1) : 0
      if cv > 40
        @recommendations << {
          title: "Standardize Position Sizing",
          detail: "Use a fixed percentage of account risk (1-2%) per trade instead of varying sizes.",
          icon: "straighten"
        }
      end
    end

    # Risk/reward
    trades_no_target = @trades.count { |t| t["take_profit"].to_f == 0 || t["take_profit"].nil? }
    if trades_no_target > @trades.count * 0.5 && @trades.count >= 5
      @recommendations << {
        title: "Define Take Profit Targets",
        detail: "#{trades_no_target} of #{@trades.count} trades have no take profit set. Always know your target before entering.",
        icon: "flag"
      }
    end

    # General best practice
    if @recommendations.length < 3
      @recommendations << {
        title: "Review Your Best Trades Weekly",
        detail: "Study your top 5 winning trades each week. Identify what made them work and replicate those conditions.",
        icon: "star"
      }
    end

    @recommendations = @recommendations.first(6)
  end

  # ── Progress Report (30d vs prior 30d) ─────────────────────────────

  def build_progress_report
    today = Date.today
    last_30_start = today - 30
    prior_30_start = today - 60

    @last_30_trades = @trades.select { |t|
      date_str = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next false unless date_str
      d = Date.parse(date_str) rescue nil
      d && d >= last_30_start && d <= today
    }

    @prior_30_trades = @trades.select { |t|
      date_str = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      next false unless date_str
      d = Date.parse(date_str) rescue nil
      d && d >= prior_30_start && d < last_30_start
    }

    @progress = []

    # Trade count
    @progress << build_metric("Trades", @last_30_trades.count, @prior_30_trades.count, "")

    # Win rate
    last_wr = @last_30_trades.any? ? (@last_30_trades.count { |t| t["pnl"].to_f > 0 }.to_f / @last_30_trades.count * 100).round(1) : 0
    prior_wr = @prior_30_trades.any? ? (@prior_30_trades.count { |t| t["pnl"].to_f > 0 }.to_f / @prior_30_trades.count * 100).round(1) : 0
    @progress << build_metric("Win Rate", last_wr, prior_wr, "%")

    # Total P&L
    last_pnl = @last_30_trades.sum { |t| t["pnl"].to_f }
    prior_pnl = @prior_30_trades.sum { |t| t["pnl"].to_f }
    @progress << build_metric("Total P&L", last_pnl.round(2), prior_pnl.round(2), "$", is_currency: true)

    # Avg P&L per trade
    last_avg = @last_30_trades.any? ? (last_pnl / @last_30_trades.count).round(2) : 0
    prior_avg = @prior_30_trades.any? ? (prior_pnl / @prior_30_trades.count).round(2) : 0
    @progress << build_metric("Avg P&L/Trade", last_avg, prior_avg, "$", is_currency: true)

    # Profit factor
    last_gp = @last_30_trades.select { |t| t["pnl"].to_f > 0 }.sum { |t| t["pnl"].to_f }
    last_gl = @last_30_trades.select { |t| t["pnl"].to_f < 0 }.sum { |t| t["pnl"].to_f.abs }
    last_pf = last_gl > 0 ? (last_gp / last_gl).round(2) : (last_gp > 0 ? 99 : 0)

    prior_gp = @prior_30_trades.select { |t| t["pnl"].to_f > 0 }.sum { |t| t["pnl"].to_f }
    prior_gl = @prior_30_trades.select { |t| t["pnl"].to_f < 0 }.sum { |t| t["pnl"].to_f.abs }
    prior_pf = prior_gl > 0 ? (prior_gp / prior_gl).round(2) : (prior_gp > 0 ? 99 : 0)
    @progress << build_metric("Profit Factor", last_pf, prior_pf, "")

    # Stop loss usage
    last_stop_pct = @last_30_trades.any? ? (@last_30_trades.count { |t| t["stop_loss"].to_f > 0 }.to_f / @last_30_trades.count * 100).round(0) : 0
    prior_stop_pct = @prior_30_trades.any? ? (@prior_30_trades.count { |t| t["stop_loss"].to_f > 0 }.to_f / @prior_30_trades.count * 100).round(0) : 0
    @progress << build_metric("Stop Usage", last_stop_pct, prior_stop_pct, "%")
  end

  def build_metric(name, current, previous, unit, is_currency: false)
    change = current - previous
    direction = if change > 0
                  "up"
                elsif change < 0
                  "down"
                else
                  "flat"
                end
    {
      name: name,
      current: current,
      previous: previous,
      change: change.round(2),
      direction: direction,
      unit: unit,
      is_currency: is_currency
    }
  end

  # ── Focus Areas ───────────────────────────────────────────────────

  def build_focus_areas
    @focus_areas = []

    # Based on weaknesses
    if @weaknesses.any?
      @focus_areas << {
        title: @weaknesses.first[:title],
        detail: "This is your biggest area for improvement right now.",
        action: @weaknesses.first[:detail]
      }
    end

    # Based on patterns
    high_severity = @patterns.select { |p| p[:severity] == "high" }
    if high_severity.any?
      p = high_severity.first
      @focus_areas << {
        title: "Address #{p[:name]}",
        detail: p[:recommendation],
        action: p[:evidence]
      }
    end

    # Progress-based
    if @progress.present?
      declining = @progress.select { |m| m[:direction] == "down" && m[:name] != "Trades" }
      if declining.any?
        d = declining.first
        @focus_areas << {
          title: "Recover #{d[:name]}",
          detail: "#{d[:name]} dropped from #{format_metric_value(d, :previous)} to #{format_metric_value(d, :current)}.",
          action: "Review what changed in the last 30 days and revert to what was working."
        }
      end
    end

    # Default focus areas if we need more
    if @focus_areas.length < 3
      @focus_areas << {
        title: "Review Top 3 Winning Trades",
        detail: "Study what made your best trades work and document the pattern.",
        action: "Look for common entry signals, timing, and position sizing across your best trades."
      }
    end
    if @focus_areas.length < 3
      @focus_areas << {
        title: "Pre-Trade Checklist Discipline",
        detail: "Ensure every trade passes your checklist before entry.",
        action: "Write down 3-5 conditions that must be true before entering any trade."
      }
    end

    @focus_areas = @focus_areas.first(3)
  end

  # ── Trading Rules Audit ────────────────────────────────────────────

  def audit_trading_rules
    @rules_audit = []

    # Infer rules from best trades
    best_trades = @trades.sort_by { |t| -t["pnl"].to_f }.first(10)
    return if best_trades.empty?

    # Rule 1: Best trades have stops
    best_with_stops = best_trades.count { |t| t["stop_loss"].to_f > 0 }
    all_with_stops = @trades.count { |t| t["stop_loss"].to_f > 0 }
    best_stop_pct = (best_with_stops.to_f / best_trades.count * 100).round(0)
    all_stop_pct = @trades.any? ? (all_with_stops.to_f / @trades.count * 100).round(0) : 0

    @rules_audit << {
      rule: "Always set a stop loss",
      best_trades_compliance: best_stop_pct,
      overall_compliance: all_stop_pct,
      gap: best_stop_pct - all_stop_pct,
      icon: "shield"
    }

    # Rule 2: Best trades have targets
    best_with_tp = best_trades.count { |t| t["take_profit"].to_f > 0 }
    all_with_tp = @trades.count { |t| t["take_profit"].to_f > 0 }
    best_tp_pct = (best_with_tp.to_f / best_trades.count * 100).round(0)
    all_tp_pct = @trades.any? ? (all_with_tp.to_f / @trades.count * 100).round(0) : 0

    @rules_audit << {
      rule: "Define take profit target",
      best_trades_compliance: best_tp_pct,
      overall_compliance: all_tp_pct,
      gap: best_tp_pct - all_tp_pct,
      icon: "flag"
    }

    # Rule 3: Best trades tend to be in specific symbols
    best_symbols = best_trades.filter_map { |t| t["symbol"] }.uniq
    if best_symbols.length <= 3 && best_symbols.any?
      focus_pct = (@trades.count { |t| best_symbols.include?(t["symbol"]) }.to_f / @trades.count * 100).round(0)
      @rules_audit << {
        rule: "Focus on proven symbols (#{best_symbols.join(', ')})",
        best_trades_compliance: 100,
        overall_compliance: focus_pct,
        gap: 100 - focus_pct,
        icon: "stars"
      }
    end

    # Rule 4: Best trades tend to have notes/journal
    best_with_notes = best_trades.count { |t| t["notes"].to_s.strip.length > 0 }
    all_with_notes = @trades.count { |t| t["notes"].to_s.strip.length > 0 }
    best_notes_pct = (best_with_notes.to_f / best_trades.count * 100).round(0)
    all_notes_pct = @trades.any? ? (all_with_notes.to_f / @trades.count * 100).round(0) : 0

    @rules_audit << {
      rule: "Document trade rationale",
      best_trades_compliance: best_notes_pct,
      overall_compliance: all_notes_pct,
      gap: best_notes_pct - all_notes_pct,
      icon: "description"
    }
  end

  # ── Tilt Risk ──────────────────────────────────────────────────────

  def calculate_tilt_risk
    @tilt_score = 0
    @tilt_factors = []

    # Factor 1: Recent loss streak
    recent = @trades.last(10)
    recent_losses = recent.reverse.take_while { |t| t["pnl"].to_f < 0 }.count
    if recent_losses >= 3
      @tilt_score += 30
      @tilt_factors << "#{recent_losses} consecutive losses in recent trades"
    elsif recent_losses >= 2
      @tilt_score += 15
      @tilt_factors << "#{recent_losses} consecutive recent losses"
    end

    # Factor 2: Increasing position sizes after losses
    last_5 = @trades.last(5)
    if last_5.length >= 3
      sizes = last_5.filter_map { |t|
        entry = t["entry_price"].to_f
        qty = t["quantity"].to_f
        entry > 0 && qty > 0 ? entry * qty : nil
      }
      if sizes.length >= 3
        avg_first = sizes.first(2).sum / 2.0
        avg_last = sizes.last(2).sum / 2.0
        if avg_last > avg_first * 1.3 && last_5.last(2).all? { |t| t["pnl"].to_f <= 0 }
          @tilt_score += 25
          @tilt_factors << "Position sizes increasing after losses"
        end
      end
    end

    # Factor 3: High trade frequency today/recently
    today_str = Date.today.to_s
    yesterday_str = (Date.today - 1).to_s
    recent_day_trades = @trades.count { |t|
      d = (t["entry_time"] || "").to_s.slice(0, 10)
      d == today_str || d == yesterday_str
    }
    if recent_day_trades >= 6
      @tilt_score += 20
      @tilt_factors << "#{recent_day_trades} trades in the last 2 days"
    end

    # Factor 4: Recent large loss
    recent_10 = @trades.last(10)
    if recent_10.any?
      avg_loss = @trades.select { |t| t["pnl"].to_f < 0 }.map { |t| t["pnl"].to_f.abs }
      avg_loss_val = avg_loss.any? ? avg_loss.sum / avg_loss.count : 0
      big_recent_loss = recent_10.any? { |t| t["pnl"].to_f < 0 && t["pnl"].to_f.abs > avg_loss_val * 2 }
      if big_recent_loss
        @tilt_score += 15
        @tilt_factors << "Recent loss significantly larger than average"
      end
    end

    # Factor 5: Negative P&L trend
    if @last_30_trades && @prior_30_trades
      last_pnl = @last_30_trades.sum { |t| t["pnl"].to_f }
      prior_pnl = @prior_30_trades.sum { |t| t["pnl"].to_f }
      if last_pnl < 0 && prior_pnl > 0
        @tilt_score += 10
        @tilt_factors << "P&L turned negative in the last 30 days"
      end
    end

    @tilt_score = [@tilt_score, 100].min
    @tilt_level = case @tilt_score
                  when 0..20 then "Low"
                  when 21..45 then "Moderate"
                  when 46..70 then "Elevated"
                  else "High"
                  end
    @tilt_color = case @tilt_score
                  when 0..20 then "var(--positive)"
                  when 21..45 then "#fbbc04"
                  when 46..70 then "#ff9800"
                  else "#e53935"
                  end
  end

  # ── Overall Assessment ─────────────────────────────────────────────

  def build_overall_assessment
    score = 0
    factors = 0

    # Win rate component
    wins = @trades.count { |t| t["pnl"].to_f > 0 }
    wr = @trades.any? ? (wins.to_f / @trades.count * 100) : 0
    wr_score = case wr
               when 60.. then 95
               when 50..59.9 then 80
               when 40..49.9 then 60
               else 35
               end
    score += wr_score
    factors += 1

    # Profit factor
    gp = @trades.select { |t| t["pnl"].to_f > 0 }.sum { |t| t["pnl"].to_f }
    gl = @trades.select { |t| t["pnl"].to_f < 0 }.sum { |t| t["pnl"].to_f.abs }
    pf = gl > 0 ? gp / gl : (gp > 0 ? 5 : 0)
    pf_score = case pf
               when 2.. then 95
               when 1.5..1.99 then 80
               when 1..1.49 then 60
               else 30
               end
    score += pf_score
    factors += 1

    # Discipline (stops)
    stop_pct = @trades.any? ? (@trades.count { |t| t["stop_loss"].to_f > 0 }.to_f / @trades.count * 100) : 0
    disc_score = case stop_pct
                 when 80.. then 90
                 when 60..79 then 70
                 when 40..59 then 50
                 else 25
                 end
    score += disc_score
    factors += 1

    # Behavioral health (inverse of tilt)
    beh_score = [100 - @tilt_score, 0].max
    score += beh_score
    factors += 1

    @overall_score = factors > 0 ? (score / factors.to_f).round(0) : 50
    @overall_grade = case @overall_score
                     when 85..100 then "A"
                     when 70..84 then "B"
                     when 55..69 then "C"
                     when 40..54 then "D"
                     else "F"
                     end

    @overall_summary = case @overall_grade
                       when "A"
                         "Excellent trading discipline and performance. Keep doing what you're doing."
                       when "B"
                         "Solid trading fundamentals with a few areas to fine-tune."
                       when "C"
                         "Decent foundation but meaningful improvements needed in risk management and discipline."
                       when "D"
                         "Several critical areas need attention. Focus on risk management and reducing impulsive trades."
                       else
                         "Significant changes needed. Focus on the basics: stop losses, position sizing, and patience."
                       end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  def parse_time(str)
    return nil if str.nil? || str.to_s.empty?
    DateTime.parse(str.to_s) rescue nil
  end

  def format_hour(hour)
    hour = hour.to_i
    if hour == 0
      "12:00 AM"
    elsif hour < 12
      "#{hour}:00 AM"
    elsif hour == 12
      "12:00 PM"
    else
      "#{hour - 12}:00 PM"
    end
  end

  def format_metric_value(metric, key)
    val = metric[key]
    if metric[:is_currency]
      number_to_currency(val)
    else
      "#{val}#{metric[:unit]}"
    end
  end
end

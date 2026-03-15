class EntryTimingController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    trade_result = begin
      api_client.trades(per_page: 1000)
    rescue => e
      Rails.logger.error("EntryTiming: failed to fetch trades: #{e.message}")
      nil
    end

    all_trades = if trade_result.is_a?(Hash)
                   trade_result["trades"] || []
                 else
                   Array(trade_result)
                 end
    all_trades = all_trades.select { |t| t.is_a?(Hash) }

    @trades = all_trades.select { |t|
      t["status"]&.downcase == "closed" &&
        t["pnl"].present? &&
        t["entry_price"].present? &&
        (t["entry_time"].present? || t["exit_time"].present?)
    }

    return if @trades.empty?

    wins = @trades.select { |t| t["pnl"].to_f > 0 }
    losses = @trades.select { |t| t["pnl"].to_f < 0 }
    @total_trades = @trades.count
    @win_rate = @total_trades > 0 ? (wins.count.to_f / @total_trades * 100).round(1) : 0.0

    compute_mae_analysis
    compute_entry_hour_analysis
    compute_entry_quality_scores
    compute_early_late_entries
    compute_reentry_analysis
    compute_day_of_week_analysis
    compute_speed_to_target
    compute_recommendations
  end

  private

  # ── MAE (Maximum Adverse Excursion) ──
  def compute_mae_analysis
    @mae_trades = []
    @trades.each do |t|
      entry = t["entry_price"].to_f
      pnl = t["pnl"].to_f
      side = (t["side"] || t["direction"] || "").downcase
      is_long = side.include?("long") || side.include?("buy")

      # Use stop_loss as proxy for MAE if available; otherwise estimate from entry vs low/high
      stop = t["stop_loss"].to_f
      low = t["low_price"].to_f
      high = t["high_price"].to_f

      mae_dollars = nil
      mae_pct = nil

      if is_long
        # For longs, adverse = price going below entry
        if low > 0 && low < entry
          mae_dollars = entry - low
          mae_pct = (mae_dollars / entry * 100).round(2)
        elsif stop > 0 && stop < entry
          mae_dollars = entry - stop
          mae_pct = (mae_dollars / entry * 100).round(2)
        end
      else
        # For shorts, adverse = price going above entry
        if high > 0 && high > entry
          mae_dollars = high - entry
          mae_pct = (mae_dollars / entry * 100).round(2)
        elsif stop > 0 && stop > entry
          mae_dollars = stop - entry
          mae_pct = (mae_dollars / entry * 100).round(2)
        end
      end

      # Default to 0 if no adverse data available
      mae_pct ||= 0.0
      mae_dollars ||= 0.0

      @mae_trades << {
        trade: t,
        entry: entry,
        pnl: pnl,
        mae_pct: mae_pct,
        mae_dollars: mae_dollars,
        win: pnl > 0,
        side: is_long ? "long" : "short"
      }
    end

    maes = @mae_trades.map { |t| t[:mae_pct] }
    @avg_mae = maes.any? ? (maes.sum / maes.count).round(2) : 0.0
    @median_mae = if maes.any?
                    sorted = maes.sort
                    mid = sorted.length / 2
                    sorted.length.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(2)
                  else
                    0.0
                  end

    # MAE distribution for histogram
    @mae_distribution = {}
    buckets = [[0, 0.5], [0.5, 1.0], [1.0, 1.5], [1.5, 2.0], [2.0, 3.0], [3.0, 5.0], [5.0, Float::INFINITY]]
    bucket_labels = ["<0.5%", "0.5-1%", "1-1.5%", "1.5-2%", "2-3%", "3-5%", "5%+"]

    buckets.each_with_index do |(low, high), i|
      matching = @mae_trades.select { |t| t[:mae_pct] >= low && t[:mae_pct] < high }
      wins_in = matching.count { |t| t[:win] }
      wr = matching.any? ? (wins_in.to_f / matching.count * 100).round(1) : 0.0
      @mae_distribution[bucket_labels[i]] = { count: matching.count, win_rate: wr }
    end
  end

  # ── Entry Hour Win Rate ──
  def compute_entry_hour_analysis
    @hour_stats = {}

    @trades.each do |t|
      hour = parse_hour(t["entry_time"].to_s)
      next unless hour

      @hour_stats[hour] ||= { wins: 0, losses: 0, total_pnl: 0.0, count: 0 }
      @hour_stats[hour][:count] += 1
      @hour_stats[hour][:total_pnl] += t["pnl"].to_f
      if t["pnl"].to_f > 0
        @hour_stats[hour][:wins] += 1
      else
        @hour_stats[hour][:losses] += 1
      end
    end

    @hour_stats.each do |hour, stats|
      stats[:win_rate] = stats[:count] > 0 ? (stats[:wins].to_f / stats[:count] * 100).round(1) : 0.0
      stats[:avg_pnl] = stats[:count] > 0 ? (stats[:total_pnl] / stats[:count]).round(2) : 0.0
    end

    # Best entry hour
    active_hours = @hour_stats.select { |_, v| v[:count] >= 3 }
    @best_hour = if active_hours.any?
                   best = active_hours.max_by { |_, v| v[:win_rate] }
                   { hour: best[0], label: format_hour(best[0]), win_rate: best[1][:win_rate], count: best[1][:count] }
                 else
                   nil
                 end
  end

  # ── Entry Quality Score ──
  def compute_entry_quality_scores
    @quality_trades = @mae_trades.map do |mt|
      t = mt[:trade]
      entry = mt[:entry]
      pnl = mt[:pnl]
      mae_pct = mt[:mae_pct]

      # Entry quality components:
      # 1. MAE score (lower MAE = better entry, 0-40 points)
      mae_score = if mae_pct <= 0.25
                    40
                  elsif mae_pct <= 0.5
                    35
                  elsif mae_pct <= 1.0
                    25
                  elsif mae_pct <= 2.0
                    15
                  elsif mae_pct <= 3.0
                    8
                  else
                    0
                  end

      # 2. P&L ratio score (win = good entry, 0-30 points)
      pnl_score = pnl > 0 ? 30 : 0

      # 3. Risk/reward execution score (0-30 points)
      stop = t["stop_loss"].to_f
      target = t["take_profit"].to_f
      exit_price = t["exit_price"].to_f
      rr_score = 0
      if stop > 0 && entry > 0
        risk = (entry - stop).abs
        if exit_price > 0 && risk > 0
          actual_move = (exit_price - entry).abs
          r_multiple = actual_move / risk
          rr_score = if r_multiple >= 3.0
                       30
                     elsif r_multiple >= 2.0
                       25
                     elsif r_multiple >= 1.0
                       20
                     elsif r_multiple >= 0.5
                       10
                     else
                       0
                     end
        end
      end

      quality_score = mae_score + pnl_score + rr_score

      mt.merge(
        mae_score: mae_score,
        pnl_score: pnl_score,
        rr_score: rr_score,
        quality_score: quality_score,
        symbol: t["symbol"]
      )
    end

    scores = @quality_trades.map { |t| t[:quality_score] }
    @avg_quality = scores.any? ? (scores.sum.to_f / scores.count).round(1) : 0.0

    # Grade distribution
    @quality_distribution = {
      "Excellent (80-100)" => @quality_trades.count { |t| t[:quality_score] >= 80 },
      "Good (60-79)" => @quality_trades.count { |t| t[:quality_score] >= 60 && t[:quality_score] < 80 },
      "Fair (40-59)" => @quality_trades.count { |t| t[:quality_score] >= 40 && t[:quality_score] < 60 },
      "Poor (20-39)" => @quality_trades.count { |t| t[:quality_score] >= 20 && t[:quality_score] < 40 },
      "Bad (0-19)" => @quality_trades.count { |t| t[:quality_score] < 20 }
    }
  end

  # ── Early vs Late Entries ──
  def compute_early_late_entries
    @early_entries = []
    @late_entries = []

    @trades.each do |t|
      entry = t["entry_price"].to_f
      exit_price = t["exit_price"].to_f
      pnl = t["pnl"].to_f
      side = (t["side"] || t["direction"] || "").downcase
      is_long = side.include?("long") || side.include?("buy")

      low = t["low_price"].to_f
      high = t["high_price"].to_f
      next unless entry > 0 && low > 0 && high > 0 && (high - low).abs > 0

      range = high - low
      next unless range > 0

      if is_long
        # For longs, entry near low = good, entry near high = late/chasing
        position_in_range = (entry - low) / range
        if position_in_range > 0.75
          @late_entries << { trade: t, position_pct: (position_in_range * 100).round(1), pnl: pnl, symbol: t["symbol"] }
        elsif position_in_range < 0.25 && pnl < 0
          # Entered near low but still lost -- possibly too early (before the move started)
          @early_entries << { trade: t, position_pct: (position_in_range * 100).round(1), pnl: pnl, symbol: t["symbol"] }
        end
      else
        # For shorts, entry near high = good, entry near low = late/chasing
        position_in_range = (high - entry) / range
        if position_in_range > 0.75
          @late_entries << { trade: t, position_pct: (position_in_range * 100).round(1), pnl: pnl, symbol: t["symbol"] }
        elsif position_in_range < 0.25 && pnl < 0
          @early_entries << { trade: t, position_pct: (position_in_range * 100).round(1), pnl: pnl, symbol: t["symbol"] }
        end
      end
    end

    @early_entry_count = @early_entries.count
    @late_entry_count = @late_entries.count
    @early_avg_pnl = @early_entries.any? ? (@early_entries.sum { |e| e[:pnl] } / @early_entries.count).round(2) : 0.0
    @late_avg_pnl = @late_entries.any? ? (@late_entries.sum { |e| e[:pnl] } / @late_entries.count).round(2) : 0.0
    @late_win_rate = @late_entries.any? ? (@late_entries.count { |e| e[:pnl] > 0 }.to_f / @late_entries.count * 100).round(1) : 0.0

    # Keep top examples
    @early_entries = @early_entries.sort_by { |e| e[:pnl] }.first(8)
    @late_entries = @late_entries.sort_by { |e| e[:pnl] }.first(8)
  end

  # ── Re-entry Analysis ──
  def compute_reentry_analysis
    @reentries = []

    # Group by symbol
    by_symbol = @trades.group_by { |t| (t["symbol"] || "").upcase }

    by_symbol.each do |symbol, trades|
      next if symbol.empty? || trades.count < 2

      sorted = trades.sort_by { |t| t["entry_time"] || t["exit_time"] || "" }

      sorted.each_cons(2) do |prev_trade, next_trade|
        prev_exit_str = prev_trade["exit_time"].to_s
        next_entry_str = next_trade["entry_time"].to_s
        next if prev_exit_str.empty? || next_entry_str.empty?

        begin
          prev_exit = Time.parse(prev_exit_str)
          next_entry = Time.parse(next_entry_str)
          gap_hours = ((next_entry - prev_exit) / 3600.0).abs

          if gap_hours <= 24
            prev_pnl = prev_trade["pnl"].to_f
            next_pnl = next_trade["pnl"].to_f

            @reentries << {
              symbol: symbol,
              gap_hours: gap_hours.round(1),
              first_pnl: prev_pnl.round(2),
              second_pnl: next_pnl.round(2),
              combined_pnl: (prev_pnl + next_pnl).round(2),
              first_side: (prev_trade["side"] || prev_trade["direction"] || "").downcase,
              second_side: (next_trade["side"] || next_trade["direction"] || "").downcase,
              improved: next_pnl > prev_pnl
            }
          end
        rescue
          next
        end
      end
    end

    @reentry_count = @reentries.count
    @reentry_improved_count = @reentries.count { |r| r[:improved] }
    @reentry_improved_pct = @reentry_count > 0 ? (@reentry_improved_count.to_f / @reentry_count * 100).round(1) : 0.0
    @reentry_avg_combined = @reentries.any? ? (@reentries.sum { |r| r[:combined_pnl] } / @reentries.count).round(2) : 0.0

    @reentries = @reentries.first(10)
  end

  # ── Day of Week Analysis ──
  def compute_day_of_week_analysis
    day_names = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday]
    @day_stats = {}

    @trades.each do |t|
      date_str = (t["entry_time"] || t["exit_time"]).to_s.slice(0, 10)
      begin
        wday = Date.parse(date_str).wday
        day_name = day_names[wday]
        @day_stats[day_name] ||= { wins: 0, losses: 0, total_pnl: 0.0, count: 0, wday: wday }
        @day_stats[day_name][:count] += 1
        @day_stats[day_name][:total_pnl] += t["pnl"].to_f
        if t["pnl"].to_f > 0
          @day_stats[day_name][:wins] += 1
        else
          @day_stats[day_name][:losses] += 1
        end
      rescue
        next
      end
    end

    @day_stats.each do |_, stats|
      stats[:win_rate] = stats[:count] > 0 ? (stats[:wins].to_f / stats[:count] * 100).round(1) : 0.0
      stats[:avg_pnl] = stats[:count] > 0 ? (stats[:total_pnl] / stats[:count]).round(2) : 0.0
    end

    active_days = @day_stats.select { |_, v| v[:count] >= 3 }
    @best_day = active_days.any? ? active_days.max_by { |_, v| v[:win_rate] } : nil
    @worst_day = active_days.any? ? active_days.min_by { |_, v| v[:win_rate] } : nil
  end

  # ── Speed to Target ──
  def compute_speed_to_target
    @speed_trades = []

    @trades.each do |t|
      entry_str = t["entry_time"].to_s
      exit_str = t["exit_time"].to_s
      next if entry_str.empty? || exit_str.empty?

      begin
        entry_t = Time.parse(entry_str)
        exit_t = Time.parse(exit_str)
        duration_minutes = ((exit_t - entry_t) / 60.0).abs.round(0).to_i
        pnl = t["pnl"].to_f

        @speed_trades << {
          symbol: t["symbol"],
          duration_minutes: duration_minutes,
          pnl: pnl,
          win: pnl > 0
        }
      rescue
        next
      end
    end

    winning_speeds = @speed_trades.select { |t| t[:win] }
    losing_speeds = @speed_trades.reject { |t| t[:win] }

    @avg_win_duration = winning_speeds.any? ? (winning_speeds.sum { |t| t[:duration_minutes] } / winning_speeds.count.to_f).round(0).to_i : 0
    @avg_loss_duration = losing_speeds.any? ? (losing_speeds.sum { |t| t[:duration_minutes] } / losing_speeds.count.to_f).round(0).to_i : 0

    # Speed buckets
    @speed_buckets = {}
    speed_ranges = {
      "<5 min" => [0, 5],
      "5-15 min" => [5, 15],
      "15-30 min" => [15, 30],
      "30-60 min" => [30, 60],
      "1-4 hrs" => [60, 240],
      "4+ hrs" => [240, Float::INFINITY]
    }

    speed_ranges.each do |label, (low, high)|
      matching = @speed_trades.select { |t| t[:duration_minutes] >= low && t[:duration_minutes] < high }
      if matching.any?
        w = matching.count { |t| t[:win] }
        @speed_buckets[label] = {
          count: matching.count,
          win_rate: (w.to_f / matching.count * 100).round(1),
          avg_pnl: (matching.sum { |t| t[:pnl] } / matching.count).round(2)
        }
      end
    end
  end

  # ── Recommendations ──
  def compute_recommendations
    @recommendations = []

    # 1. MAE recommendation
    if @avg_mae > 2.0
      @recommendations << {
        icon: "shield",
        title: "Tighten Your Entries",
        detail: "Your average MAE is #{@avg_mae}%, meaning trades move #{@avg_mae}% against you on average before working. Wait for better entry signals or use limit orders closer to support/resistance."
      }
    elsif @avg_mae < 0.5
      @recommendations << {
        icon: "verified",
        title: "Excellent Entry Precision",
        detail: "Your average MAE of #{@avg_mae}% shows strong entry timing. Trades rarely move far against you. Maintain your current approach."
      }
    end

    # 2. Best hour recommendation
    if @best_hour
      @recommendations << {
        icon: "schedule",
        title: "Focus on #{@best_hour[:label]} Entries",
        detail: "Your best entry hour is #{@best_hour[:label]} with a #{@best_hour[:win_rate]}% win rate across #{@best_hour[:count]} trades. Consider concentrating your trading during this window."
      }
    end

    # 3. Late entry warning
    if @late_entry_count > 3 && @late_win_rate < 40
      @recommendations << {
        icon: "warning",
        title: "Stop Chasing Entries",
        detail: "#{@late_entry_count} trades were entered after the move already started, with only a #{@late_win_rate}% win rate. Wait for pullbacks instead of chasing."
      }
    end

    # 4. Re-entry pattern
    if @reentry_count >= 3 && @reentry_improved_pct < 50
      @recommendations << {
        icon: "replay",
        title: "Reduce Re-entries",
        detail: "#{@reentry_count} re-entries within 24 hours, but only #{@reentry_improved_pct}% improved on the first trade. Consider holding longer instead of exiting and re-entering."
      }
    end

    # 5. Day of week
    if @worst_day
      day_name = @worst_day[0]
      stats = @worst_day[1]
      if stats[:win_rate] < 40 && stats[:count] >= 5
        @recommendations << {
          icon: "event_busy",
          title: "Avoid #{day_name} Entries",
          detail: "Your #{day_name} win rate is only #{stats[:win_rate]}% across #{stats[:count]} trades with avg P&L of #{number_to_currency(stats[:avg_pnl])}. Consider reducing size or skipping this day."
        }
      end
    end

    # 6. Speed insight
    if @avg_win_duration > 0 && @avg_loss_duration > 0
      if @avg_loss_duration > @avg_win_duration * 1.5
        @recommendations << {
          icon: "speed",
          title: "Cut Losers Faster",
          detail: "Losing trades last #{format_duration(@avg_loss_duration)} vs #{format_duration(@avg_win_duration)} for winners. If a trade hasn't worked within #{format_duration(@avg_win_duration)}, consider exiting."
        }
      end
    end

    @recommendations = @recommendations.first(4)
  end

  def parse_hour(time_str)
    return nil if time_str.nil? || time_str.empty?
    begin
      Time.parse(time_str).hour
    rescue
      nil
    end
  end

  def format_hour(hour)
    if hour == 0
      "12 AM"
    elsif hour < 12
      "#{hour} AM"
    elsif hour == 12
      "12 PM"
    else
      "#{hour - 12} PM"
    end
  end

  def format_duration(minutes)
    if minutes < 60
      "#{minutes}min"
    elsif minutes < 1440
      hours = (minutes / 60.0).round(1)
      "#{hours}h"
    else
      days = (minutes / 1440.0).round(1)
      "#{days}d"
    end
  end
end

class StrategyBuilderController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    # Fetch all trades using paginated API
    trades_thread = Thread.new do
      all_trades = []
      page = 1
      loop do
        resp = api_client.trades(page: page, per_page: 100)
        break unless resp
        trades_arr = if resp.is_a?(Hash)
          resp["trades"] || resp["data"] || []
        else
          Array(resp)
        end
        break if trades_arr.empty?
        all_trades.concat(trades_arr)
        break if trades_arr.length < 100
        page += 1
      end
      all_trades
    rescue => e
      Rails.logger.error("strategy_builder trades: #{e.message}")
      []
    end

    @trades = trades_thread.value
    @trades = @trades.select { |t| t.is_a?(Hash) && t["status"]&.downcase == "closed" && t["pnl"].present? }

    return if @trades.empty?

    # ── Overall stats ──
    @total_trades = @trades.count
    @total_wins = @trades.count { |t| t["pnl"].to_f > 0 }
    @total_losses = @trades.count { |t| t["pnl"].to_f <= 0 }
    @overall_win_rate = @total_trades > 0 ? (@total_wins.to_f / @total_trades * 100).round(1) : 0
    @overall_pnl = @trades.sum { |t| t["pnl"].to_f }.round(2)
    @overall_avg_pnl = @total_trades > 0 ? (@overall_pnl / @total_trades).round(2) : 0

    # ── Analyze by dimensions ──
    @dimensions = {}

    # By Tag
    tag_groups = {}
    @trades.each do |t|
      tags = t["tags"]
      if tags.is_a?(Array) && tags.any?
        tags.each do |tag|
          tag_name = tag.is_a?(Hash) ? (tag["name"] || tag["label"] || tag.to_s) : tag.to_s
          next if tag_name.strip.empty?
          tag_groups[tag_name] ||= []
          tag_groups[tag_name] << t
        end
      else
        tag_groups["Untagged"] ||= []
        tag_groups["Untagged"] << t
      end
    end
    @dimensions["By Tag"] = tag_groups.map { |name, trades| build_stats(name, trades) }.sort_by { |s| -s[:expectancy] }

    # By Setup (playbook)
    setup_groups = @trades.group_by { |t| t["playbook_name"] || t["setup"] || "No Setup" }
    @dimensions["By Setup"] = setup_groups.map { |name, trades| build_stats(name, trades) }.sort_by { |s| -s[:expectancy] }

    # By Symbol
    symbol_groups = @trades.group_by { |t| (t["symbol"] || "Unknown").upcase }
    @dimensions["By Symbol"] = symbol_groups.map { |name, trades| build_stats(name, trades) }.sort_by { |s| -s[:expectancy] }

    # By Time of Day
    time_groups = @trades.group_by { |t|
      hour = parse_hour(t["entry_time"].to_s)
      if hour.nil?
        nil
      elsif hour < 11
        "Morning (pre-11am)"
      elsif hour < 14
        "Midday (11am-2pm)"
      else
        "Afternoon (2pm+)"
      end
    }.reject { |k, _| k.nil? }
    @dimensions["By Time"] = time_groups.map { |name, trades| build_stats(name, trades) }.sort_by { |s| -s[:expectancy] }

    # By Side
    side_groups = @trades.group_by { |t|
      side = (t["side"] || t["direction"] || "").downcase
      if side.include?("long") || side.include?("buy")
        "Long"
      elsif side.include?("short") || side.include?("sell")
        "Short"
      else
        "Unknown"
      end
    }
    @dimensions["By Side"] = side_groups.map { |name, trades| build_stats(name, trades) }.sort_by { |s| -s[:expectancy] }

    # By Asset Class
    asset_groups = @trades.group_by { |t| t["asset_class"] || t["instrument_type"] || classify_asset(t["symbol"].to_s) }
    @dimensions["By Asset Class"] = asset_groups.map { |name, trades| build_stats(name, trades) }.sort_by { |s| -s[:expectancy] }

    # ── Performance Matrix ──
    @matrix = []
    @dimensions.each do |dimension, stats_list|
      stats_list.each do |s|
        @matrix << s.merge(dimension: dimension)
      end
    end
    @matrix.sort_by! { |s| -s[:expectancy] }

    # ── Top Performing Combinations ──
    @top_combos = build_top_combinations

    # ── Worst Combinations (What to Avoid) ──
    @worst_combos = @top_combos.sort_by { |c| c[:expectancy] }.first(5).select { |c| c[:expectancy] < 0 }

    # ── Strategy Templates ──
    @templates = build_strategy_templates

    # ── Build Your Strategy data ──
    @symbols = symbol_groups.keys.sort
    @sides = side_groups.keys.reject { |s| s == "Unknown" }.sort
    @times = time_groups.keys.sort
    @setups = setup_groups.keys.sort
    @all_tags = tag_groups.keys.reject { |t| t == "Untagged" }.sort
  end

  private

  def build_stats(name, trades)
    count = trades.count
    wins = trades.select { |t| t["pnl"].to_f > 0 }
    losses = trades.select { |t| t["pnl"].to_f <= 0 }
    win_count = wins.count
    loss_count = losses.count
    win_rate = count > 0 ? (win_count.to_f / count * 100).round(1) : 0
    loss_rate = count > 0 ? (loss_count.to_f / count * 100).round(1) : 0
    total_pnl = trades.sum { |t| t["pnl"].to_f }.round(2)
    avg_pnl = count > 0 ? (total_pnl / count).round(2) : 0
    avg_win = win_count > 0 ? (wins.sum { |t| t["pnl"].to_f } / win_count).round(2) : 0
    avg_loss = loss_count > 0 ? (losses.sum { |t| t["pnl"].to_f } / loss_count).round(2) : 0

    gross_wins = wins.sum { |t| t["pnl"].to_f }
    gross_losses = losses.sum { |t| t["pnl"].to_f }.abs
    profit_factor = gross_losses > 0 ? (gross_wins / gross_losses).round(2) : (gross_wins > 0 ? 999.0 : 0.0)

    # Expectancy
    expectancy = (avg_win * (win_rate / 100.0)) - (avg_loss.abs * (loss_rate / 100.0))
    expectancy = expectancy.round(2)

    # Average hold time
    hold_times = trades.filter_map { |t|
      entry_str = t["entry_time"].to_s
      exit_str = t["exit_time"].to_s
      next nil if entry_str.empty? || exit_str.empty?
      begin
        ((Time.parse(exit_str) - Time.parse(entry_str)) / 60.0).abs
      rescue
        nil
      end
    }
    avg_hold_minutes = hold_times.any? ? (hold_times.sum / hold_times.count).round(0) : nil

    # Max drawdown within this group
    running_pnl = 0.0
    peak = 0.0
    max_dd = 0.0
    trades.sort_by { |t| t["exit_time"].to_s }.each do |t|
      running_pnl += t["pnl"].to_f
      peak = running_pnl if running_pnl > peak
      dd = peak - running_pnl
      max_dd = dd if dd > max_dd
    end

    best_trade = trades.max_by { |t| t["pnl"].to_f }
    worst_trade = trades.min_by { |t| t["pnl"].to_f }

    {
      name: name,
      trade_count: count,
      win_rate: win_rate,
      loss_rate: loss_rate,
      avg_pnl: avg_pnl,
      total_pnl: total_pnl,
      profit_factor: profit_factor,
      avg_win: avg_win,
      avg_loss: avg_loss,
      expectancy: expectancy,
      avg_hold_minutes: avg_hold_minutes,
      max_drawdown: max_dd.round(2),
      best_trade_pnl: best_trade ? best_trade["pnl"].to_f.round(2) : 0,
      worst_trade_pnl: worst_trade ? worst_trade["pnl"].to_f.round(2) : 0
    }
  end

  def build_top_combinations
    combos = []

    # Build multi-dimensional combos: symbol + side + time
    symbol_groups = @trades.group_by { |t| (t["symbol"] || "Unknown").upcase }
    symbol_groups.each do |symbol, sym_trades|
      # Symbol + Side
      side_groups = sym_trades.group_by { |t|
        side = (t["side"] || t["direction"] || "").downcase
        if side.include?("long") || side.include?("buy")
          "Long"
        elsif side.include?("short") || side.include?("sell")
          "Short"
        else
          nil
        end
      }.reject { |k, _| k.nil? }

      side_groups.each do |side, side_trades|
        next if side_trades.count < 3
        stats = build_stats("#{symbol} #{side}s", side_trades)
        combos << stats.merge(combo_desc: "#{symbol} #{side} trades")

        # Symbol + Side + Time
        time_groups = side_trades.group_by { |t|
          hour = parse_hour(t["entry_time"].to_s)
          if hour.nil?
            nil
          elsif hour < 11
            "morning"
          elsif hour < 14
            "midday"
          else
            "afternoon"
          end
        }.reject { |k, _| k.nil? }

        time_groups.each do |time_label, time_trades|
          next if time_trades.count < 3
          stats = build_stats("#{symbol} #{side}s in the #{time_label}", time_trades)
          combos << stats.merge(combo_desc: "#{symbol} #{side} trades in the #{time_label}")
        end
      end
    end

    combos.sort_by { |c| -c[:expectancy] }.first(5)
  rescue => e
    Rails.logger.error("strategy_builder combos: #{e.message}")
    []
  end

  def build_strategy_templates
    templates = []

    # Best Symbol strategy
    if @dimensions["By Symbol"]&.any?
      best_sym = @dimensions["By Symbol"].max_by { |s| s[:total_pnl] }
      if best_sym && best_sym[:total_pnl] > 0
        templates << {
          name: "Best Symbol Focus",
          icon: "sell",
          color: "#1976d2",
          description: "Focus exclusively on #{best_sym[:name]} - your most profitable symbol",
          stats: best_sym,
          rule: "Only trade #{best_sym[:name]}"
        }
      end
    end

    # Best Time strategy
    if @dimensions["By Time"]&.any?
      best_time = @dimensions["By Time"].max_by { |s| s[:win_rate] }
      if best_time && best_time[:win_rate] > 50
        templates << {
          name: "Best Time Window",
          icon: "schedule",
          color: "#e65100",
          description: "Only trade during #{best_time[:name]} when your win rate is highest",
          stats: best_time,
          rule: "Restrict trading to #{best_time[:name]}"
        }
      end
    end

    # Long Only or Short Only
    if @dimensions["By Side"]&.any?
      long_stats = @dimensions["By Side"].find { |s| s[:name] == "Long" }
      short_stats = @dimensions["By Side"].find { |s| s[:name] == "Short" }
      if long_stats && short_stats
        if long_stats[:expectancy] > short_stats[:expectancy] && long_stats[:expectancy] > 0
          templates << {
            name: "Long Only",
            icon: "trending_up",
            color: "#2e7d32",
            description: "Focus on long trades where your edge is stronger",
            stats: long_stats,
            rule: "Only take long positions"
          }
        elsif short_stats[:expectancy] > long_stats[:expectancy] && short_stats[:expectancy] > 0
          templates << {
            name: "Short Only",
            icon: "trending_down",
            color: "#c62828",
            description: "Focus on short trades where your edge is stronger",
            stats: short_stats,
            rule: "Only take short positions"
          }
        end
      elsif long_stats && long_stats[:expectancy] > 0
        templates << {
          name: "Long Only",
          icon: "trending_up",
          color: "#2e7d32",
          description: "Focus on long trades where your edge is stronger",
          stats: long_stats,
          rule: "Only take long positions"
        }
      end
    end

    # High Probability strategy
    high_prob = @matrix.select { |s| s[:win_rate] > 60 && s[:trade_count] >= 5 }.sort_by { |s| -s[:win_rate] }.first
    if high_prob
      templates << {
        name: "High Probability",
        icon: "verified",
        color: "#6a1b9a",
        description: "Focus on #{high_prob[:name]} (#{high_prob[:dimension]}) with #{high_prob[:win_rate]}% win rate",
        stats: high_prob,
        rule: "Only trade #{high_prob[:name]} setups"
      }
    end

    # Big Winner strategy
    big_winner = @matrix.select { |s| s[:trade_count] >= 5 }.sort_by { |s| -s[:avg_win] }.first
    if big_winner && big_winner[:avg_win] > 0
      templates << {
        name: "Big Winner",
        icon: "emoji_events",
        color: "#f9a825",
        description: "#{big_winner[:name]} (#{big_winner[:dimension]}) has the highest average winning trade",
        stats: big_winner,
        rule: "Focus on #{big_winner[:name]} for larger average wins"
      }
    end

    templates
  rescue => e
    Rails.logger.error("strategy_builder templates: #{e.message}")
    []
  end

  def parse_hour(time_str)
    return nil if time_str.nil? || time_str.empty?
    begin
      Time.parse(time_str).hour
    rescue
      nil
    end
  end

  def format_hold_time(minutes)
    return "--" unless minutes
    if minutes < 60
      "#{minutes}m"
    elsif minutes < 1440
      "#{(minutes / 60.0).round(1)}h"
    else
      "#{(minutes / 1440.0).round(1)}d"
    end
  end
  helper_method :format_hold_time

  def classify_asset(symbol)
    return "Unknown" if symbol.blank?
    sym = symbol.upcase.strip
    if sym.match?(/\d{6}[CP]\d+/) || sym.length > 10
      "Options"
    elsif sym.include?("/")
      "Forex"
    elsif ["ES", "NQ", "YM", "RTY", "CL", "GC", "SI", "ZB", "ZN", "MES", "MNQ", "MYM", "M2K", "MCL"].include?(sym.gsub(/[^A-Z]/, ""))
      "Futures"
    elsif sym.match?(/^[A-Z]{1,5}$/)
      "Equities"
    else
      "Other"
    end
  end
end

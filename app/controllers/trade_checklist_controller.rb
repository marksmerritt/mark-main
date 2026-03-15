class TradeChecklistController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:trades] = Thread.new { api_client.trades(per_page: 200) }
    threads[:journal] = Thread.new { api_client.journal_entries(per_page: 50) rescue [] }

    trade_result = threads[:trades].value
    @trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : Array(trade_result)
    @trades = @trades.select { |t| t.is_a?(Hash) }

    journal_result = threads[:journal].value
    @journal_entries = journal_result.is_a?(Hash) ? (journal_result["journal_entries"] || []) : Array(journal_result)
    @journal_entries = @journal_entries.select { |e| e.is_a?(Hash) }

    @open_trades = @trades.select { |t| t["status"] == "open" }
    @closed_trades = @trades.select { |t| t["status"] != "open" }
    @closed_trades = @closed_trades.sort_by { |t| t["exit_time"] || t["entry_time"] || "" }

    @checklist_items = []
    @tips = []

    analyze_risk_management
    analyze_position_sizing
    analyze_symbol_familiarity
    analyze_time_of_day
    analyze_streak_awareness
    analyze_concentration
    analyze_recent_performance
    analyze_journal_check

    compute_readiness_score
    build_quick_reference
  end

  private

  def analyze_risk_management
    return add_item("Risk Management", "shield", :warn, "No trade history to analyze",
      "Start logging trades with stop losses to build your risk profile.") if @closed_trades.empty?

    trades_with_stops = @closed_trades.count { |t| t["stop_loss"].to_f > 0 }
    stop_pct = (@closed_trades.count > 0 ? (trades_with_stops.to_f / @closed_trades.count * 100).round(1) : 0)

    # Average risk per trade (for trades with stop losses)
    risks = @closed_trades.select { |t| t["stop_loss"].to_f > 0 && t["entry_price"].to_f > 0 }.map { |t|
      entry = t["entry_price"].to_f
      stop = t["stop_loss"].to_f
      qty = t["quantity"].to_i
      qty > 0 ? ((entry - stop).abs * qty) : 0
    }.select { |r| r > 0 }
    avg_risk = risks.any? ? (risks.sum / risks.count.to_f).round(2) : 0

    if stop_pct >= 80
      add_item("Risk Management", "shield", :pass,
        "#{stop_pct}% of your trades have stop losses set (#{trades_with_stops}/#{@closed_trades.count}). Average risk per trade: #{number_to_currency(avg_risk)}.",
        "Great discipline! Keep setting stops on every trade.")
    elsif stop_pct >= 50
      add_item("Risk Management", "shield", :warn,
        "#{stop_pct}% of trades have stop losses (#{trades_with_stops}/#{@closed_trades.count}). #{@closed_trades.count - trades_with_stops} trades had undefined risk.",
        "Aim for 100% stop loss usage. Every trade should have a defined exit point.")
    else
      add_item("Risk Management", "shield", :fail,
        "Only #{stop_pct}% of trades have stop losses (#{trades_with_stops}/#{@closed_trades.count}). This is dangerous.",
        "CRITICAL: Set a stop loss before entering any trade. Undefined risk can wipe out your account.")
      @tips << "Your stop loss usage is low. Consider making it a rule: no stop = no trade."
    end
  end

  def analyze_position_sizing
    position_sizes = @closed_trades.filter_map { |t|
      entry = t["entry_price"].to_f
      qty = t["quantity"].to_f
      entry > 0 && qty > 0 ? (entry * qty) : nil
    }

    if position_sizes.count < 3
      return add_item("Position Sizing", "tune", :warn, "Not enough trade history to analyze position sizing.",
        "Log at least 3 trades to see position sizing analysis.")
    end

    avg_size = position_sizes.sum / position_sizes.count.to_f
    std_dev = Math.sqrt(position_sizes.map { |s| (s - avg_size) ** 2 }.sum / position_sizes.count.to_f)
    cv = avg_size > 0 ? (std_dev / avg_size * 100).round(1) : 0
    @avg_position_size = avg_size.round(2)
    @position_cv = cv

    if cv <= 30
      add_item("Position Sizing", "tune", :pass,
        "Consistent position sizing with #{cv}% variation. Average size: #{number_to_currency(avg_size)}.",
        "Great consistency! Your sizing discipline is solid.")
    elsif cv <= 60
      add_item("Position Sizing", "tune", :warn,
        "Position sizing varies moderately (#{cv}% CV). Range: #{number_to_currency(position_sizes.min)} to #{number_to_currency(position_sizes.max)}.",
        "Consider standardizing your position sizes. Large variance can amplify losses.")
      @tips << "Your position sizes vary quite a bit. Consider using a fixed percentage of your account per trade."
    else
      add_item("Position Sizing", "tune", :fail,
        "Highly inconsistent position sizing (#{cv}% CV). Largest position is #{(position_sizes.max / avg_size).round(1)}x your average.",
        "WARNING: Wildly varying position sizes indicates emotional sizing. Use a fixed formula.")
    end
  end

  def analyze_symbol_familiarity
    return add_item("Symbol Familiarity", "search", :warn, "No trade history to analyze symbol familiarity.",
      "Start trading to build your symbol performance data.") if @closed_trades.empty?

    @symbol_stats = {}
    @closed_trades.each do |t|
      sym = t["symbol"] || "Unknown"
      @symbol_stats[sym] ||= { wins: 0, losses: 0, total: 0, pnl: 0 }
      @symbol_stats[sym][:total] += 1
      @symbol_stats[sym][:pnl] += t["pnl"].to_f
      if t["pnl"].to_f > 0
        @symbol_stats[sym][:wins] += 1
      else
        @symbol_stats[sym][:losses] += 1
      end
    end

    @symbol_stats.each do |sym, stats|
      stats[:win_rate] = stats[:total] > 0 ? (stats[:wins].to_f / stats[:total] * 100).round(1) : 0
    end

    # Best symbols by win rate (min 3 trades)
    @best_symbols = @symbol_stats.select { |_, s| s[:total] >= 3 }
      .sort_by { |_, s| -s[:win_rate] }
      .first(5)

    # Symbols traded only once or twice (unfamiliar)
    unfamiliar = @symbol_stats.select { |_, s| s[:total] <= 2 }
    familiar_count = @symbol_stats.count { |_, s| s[:total] >= 3 }

    if familiar_count >= 3
      top_sym = @best_symbols.first
      add_item("Symbol Familiarity", "search", :pass,
        "You have #{familiar_count} well-traded symbols. Best: #{top_sym[0]} (#{top_sym[1][:win_rate]}% WR, #{top_sym[1][:total]} trades).",
        "Stick to your proven symbols. You know their behavior.")
    elsif familiar_count >= 1
      add_item("Symbol Familiarity", "search", :warn,
        "Only #{familiar_count} symbol#{'s' if familiar_count != 1} with 3+ trades. #{unfamiliar.count} symbols traded just once or twice.",
        "Build deeper experience with fewer symbols before branching out.")
      @tips << "Focus on mastering a few symbols rather than spreading thin across many."
    else
      add_item("Symbol Familiarity", "search", :warn,
        "No symbols traded 3+ times yet. You're still exploring.",
        "Consider specializing in 2-3 symbols to learn their patterns deeply.")
    end
  end

  def analyze_time_of_day
    return add_item("Time of Day", "schedule", :warn, "No trade history to analyze timing patterns.",
      "Start logging trades with timestamps to see your best/worst trading hours.") if @closed_trades.empty?

    @hourly_stats = {}
    @closed_trades.each do |t|
      time_str = t["entry_time"] || t["created_at"]
      next unless time_str
      hour = Time.parse(time_str.to_s).hour rescue nil
      next unless hour
      @hourly_stats[hour] ||= { wins: 0, losses: 0, total: 0, pnl: 0 }
      @hourly_stats[hour][:total] += 1
      @hourly_stats[hour][:pnl] += t["pnl"].to_f
      if t["pnl"].to_f > 0
        @hourly_stats[hour][:wins] += 1
      else
        @hourly_stats[hour][:losses] += 1
      end
    end

    if @hourly_stats.empty?
      return add_item("Time of Day", "schedule", :warn, "No timestamp data available for timing analysis.",
        "Ensure your trades include entry times.")
    end

    @hourly_stats.each do |hour, stats|
      stats[:win_rate] = stats[:total] > 0 ? (stats[:wins].to_f / stats[:total] * 100).round(1) : 0
    end

    best_hour = @hourly_stats.select { |_, s| s[:total] >= 2 }.max_by { |_, s| s[:win_rate] }
    worst_hour = @hourly_stats.select { |_, s| s[:total] >= 2 }.min_by { |_, s| s[:win_rate] }

    current_hour = Time.now.hour
    current_stats = @hourly_stats[current_hour]

    if current_stats && current_stats[:total] >= 2 && current_stats[:win_rate] >= 50
      add_item("Time of Day", "schedule", :pass,
        "Current hour (#{format_hour(current_hour)}) is a good time for you: #{current_stats[:win_rate]}% win rate over #{current_stats[:total]} trades.",
        best_hour ? "Your best hour: #{format_hour(best_hour[0])} (#{best_hour[1][:win_rate]}% WR)." : "Keep trading during your proven hours.")
    elsif current_stats && current_stats[:total] >= 2 && current_stats[:win_rate] < 50
      add_item("Time of Day", "schedule", :warn,
        "Caution: You have a #{current_stats[:win_rate]}% win rate at #{format_hour(current_hour)} (#{current_stats[:total]} trades).",
        worst_hour ? "Consider waiting for #{format_hour(best_hour[0])} when you perform best (#{best_hour[1][:win_rate]}% WR)." : "This time slot hasn't been great for you. Consider waiting.")
      @tips << "Your current time slot (#{format_hour(current_hour)}) historically underperforms. Consider sitting this one out."
    else
      detail = if best_hour
        "Best hour: #{format_hour(best_hour[0])} (#{best_hour[1][:win_rate]}% WR). Worst: #{format_hour(worst_hour[0])} (#{worst_hour[1][:win_rate]}% WR)."
      else
        "Not enough data per hour yet. Keep logging trades with timestamps."
      end
      add_item("Time of Day", "schedule", :pass,
        "Limited data for current hour (#{format_hour(current_hour)}). No red flags.",
        detail)
    end
  end

  def analyze_streak_awareness
    return add_item("Streak Awareness", "local_fire_department", :warn, "No trade history to analyze streaks.",
      "Start trading to see your win/loss streak patterns.") if @closed_trades.empty?

    # Current streak
    current_streak = 0
    streak_type = nil

    @closed_trades.reverse_each do |t|
      pnl = t["pnl"].to_f
      if current_streak == 0
        streak_type = pnl >= 0 ? :win : :loss
        current_streak = 1
      elsif (streak_type == :win && pnl >= 0) || (streak_type == :loss && pnl < 0)
        current_streak += 1
      else
        break
      end
    end

    @current_streak = current_streak
    @streak_type = streak_type

    if streak_type == :loss && current_streak >= 3
      add_item("Streak Awareness", "local_fire_department", :fail,
        "You're on a #{current_streak}-trade losing streak. Emotional risk is HIGH.",
        "STOP. Take a break. Review your last #{current_streak} trades before entering another. Revenge trading is the #1 account killer.")
      @tips << "You're on a #{current_streak}-trade losing streak. Step away, breathe, and come back with a clear plan."
    elsif streak_type == :loss && current_streak >= 2
      add_item("Streak Awareness", "local_fire_department", :warn,
        "You've lost your last #{current_streak} trades. Be cautious.",
        "Reduce position size by 50% after 2 consecutive losses. Protect your capital.")
      @tips << "Consider reducing your position size after consecutive losses."
    elsif streak_type == :win && current_streak >= 5
      add_item("Streak Awareness", "local_fire_department", :warn,
        "You're on a #{current_streak}-trade winning streak. Watch for overconfidence.",
        "Winning streaks can lead to oversizing and breaking rules. Stay disciplined with your process.")
    elsif streak_type == :win && current_streak >= 2
      add_item("Streak Awareness", "local_fire_department", :pass,
        "You're on a #{current_streak}-trade winning streak. Momentum is good.",
        "Stay disciplined. Don't increase size just because you're winning.")
    else
      add_item("Streak Awareness", "local_fire_department", :pass,
        "No significant streak. Last trade was a #{streak_type == :win ? 'win' : 'loss'}.",
        "Clean slate. Focus on your process, not the outcome.")
    end
  end

  def analyze_concentration
    if @open_trades.empty?
      return add_item("Concentration Check", "pie_chart", :pass,
        "No open positions. You have a clean slate to work with.",
        "You can enter a new position without concentration concerns.")
    end

    open_symbols = @open_trades.map { |t| t["symbol"] }.compact.uniq
    total_exposure = @open_trades.sum { |t| t["entry_price"].to_f * t["quantity"].to_i }

    # Check per-symbol concentration
    symbol_exposure = {}
    @open_trades.each do |t|
      sym = t["symbol"] || "Unknown"
      exposure = t["entry_price"].to_f * t["quantity"].to_i
      symbol_exposure[sym] ||= 0
      symbol_exposure[sym] += exposure
    end

    concentrated = symbol_exposure.select { |_, exp|
      total_exposure > 0 && (exp / total_exposure * 100) > 25
    }

    if @open_trades.count >= 6
      add_item("Concentration Check", "pie_chart", :fail,
        "#{@open_trades.count} open positions across #{open_symbols.count} symbols. That's a lot to manage.",
        "Consider closing some positions before adding new ones. Focus is better than diversification overload.")
      @tips << "You have #{@open_trades.count} open positions. Can you really monitor all of them effectively?"
    elsif concentrated.any?
      sym, exp = concentrated.first
      pct = (exp / total_exposure * 100).round(1)
      add_item("Concentration Check", "pie_chart", :warn,
        "#{@open_trades.count} open positions. #{sym} represents #{pct}% of your exposure.",
        "Adding another position in #{sym} would increase concentration risk. Consider a different symbol.")
    elsif @open_trades.count >= 4
      add_item("Concentration Check", "pie_chart", :warn,
        "#{@open_trades.count} open positions across #{open_symbols.count} symbols. Getting busy.",
        "Be selective about adding more positions. Quality over quantity.")
    else
      add_item("Concentration Check", "pie_chart", :pass,
        "#{@open_trades.count} open position#{'s' if @open_trades.count != 1} across #{open_symbols.count} symbol#{'s' if open_symbols.count != 1}. Manageable.",
        "Room for another position if your setup is solid.")
    end
  end

  def analyze_recent_performance
    last_5 = @closed_trades.last(5)

    if last_5.empty?
      return add_item("Recent Performance", "trending_up", :warn, "No recent closed trades to analyze.",
        "Start closing trades to build your performance history.")
    end

    wins = last_5.count { |t| t["pnl"].to_f > 0 }
    losses = last_5.count { |t| t["pnl"].to_f <= 0 }
    total_pnl = last_5.sum { |t| t["pnl"].to_f }

    # Check for drawdown
    running = 0
    peak = 0
    max_dd = 0
    @closed_trades.each do |t|
      running += t["pnl"].to_f
      peak = running if running > peak
      dd = peak - running
      max_dd = dd if dd > max_dd
    end
    @current_equity = running
    in_drawdown = peak > 0 && (peak - running) > 0
    drawdown_pct = peak > 0 ? ((peak - running) / peak * 100).round(1) : 0

    if total_pnl > 0 && wins >= 3
      add_item("Recent Performance", "trending_up", :pass,
        "Last 5 trades: #{wins}W/#{losses}L for #{number_to_currency(total_pnl)}. You're in the zone.",
        in_drawdown && drawdown_pct > 5 ? "Still in a #{drawdown_pct}% drawdown from peak despite recent wins." : "Momentum is on your side. Stay disciplined.")
    elsif total_pnl > 0
      add_item("Recent Performance", "trending_up", :pass,
        "Last 5 trades: #{wins}W/#{losses}L for #{number_to_currency(total_pnl)}. Net positive.",
        "Decent performance. Focus on keeping losses small.")
    elsif total_pnl <= 0 && losses >= 4
      add_item("Recent Performance", "trending_up", :fail,
        "Last 5 trades: #{wins}W/#{losses}L for #{number_to_currency(total_pnl)}. Rough stretch.",
        "Consider reducing size or taking a break. Review your last few trades for common mistakes.")
      @tips << "Your recent performance is poor. Before entering, ask: has anything changed about my strategy or the market?"
    else
      add_item("Recent Performance", "trending_up", :warn,
        "Last 5 trades: #{wins}W/#{losses}L for #{number_to_currency(total_pnl)}.",
        in_drawdown ? "You're in a #{drawdown_pct}% drawdown. Be extra cautious with new entries." : "Mixed results. Make sure your next trade has a clear edge.")
    end
  end

  def analyze_journal_check
    today = Date.today.to_s
    journaled_today = @journal_entries.any? { |e|
      entry_date = e["date"]&.to_s&.slice(0, 10)
      entry_date == today
    }

    recent_entries = @journal_entries.select { |e| e.is_a?(Hash) && e["date"].present? }
      .sort_by { |e| e["date"].to_s }
      .last(7)

    journal_days_last_week = recent_entries.count { |e|
      date = Date.parse(e["date"].to_s) rescue nil
      date && date >= Date.today - 7
    }

    if journaled_today
      add_item("Journal Check", "edit_note", :pass,
        "You've journaled today. You're mentally prepared and self-aware.",
        "Great habit! Journaling before trading improves decision-making.")
    elsif journal_days_last_week >= 5
      add_item("Journal Check", "edit_note", :warn,
        "You haven't journaled today, but you've been consistent this week (#{journal_days_last_week}/7 days).",
        "Take 2 minutes to jot down your mindset and plan before trading.")
    else
      add_item("Journal Check", "edit_note", :fail,
        "No journal entry today and only #{journal_days_last_week} entries in the last 7 days.",
        "Journal before you trade. Write down your plan, mindset, and what you'll do if the trade goes against you.")
      @tips << "Start your trading day with a journal entry. Even 2 sentences about your mindset can help."
    end
  end

  def compute_readiness_score
    return @readiness_score = 0 if @checklist_items.empty?

    weights = {
      "Risk Management" => 20,
      "Position Sizing" => 10,
      "Symbol Familiarity" => 10,
      "Time of Day" => 10,
      "Streak Awareness" => 20,
      "Concentration Check" => 10,
      "Recent Performance" => 10,
      "Journal Check" => 10
    }

    total_weight = 0
    weighted_score = 0

    @checklist_items.each do |item|
      weight = weights[item[:name]] || 10
      total_weight += weight
      score = case item[:status]
              when :pass then 100
              when :warn then 50
              when :fail then 0
              end
      weighted_score += score * weight
    end

    @readiness_score = total_weight > 0 ? (weighted_score.to_f / total_weight).round(0) : 0

    @readiness_grade = case @readiness_score
                       when 90..100 then "A"
                       when 75..89 then "B"
                       when 60..74 then "C"
                       when 40..59 then "D"
                       else "F"
                       end

    @readiness_label = case @readiness_score
                       when 80..100 then "Ready to Trade"
                       when 60..79 then "Proceed with Caution"
                       when 40..59 then "Review Before Trading"
                       else "Consider Sitting Out"
                       end
  end

  def build_quick_reference
    # Best symbols (by win rate, min 3 trades)
    @top_symbols = (@symbol_stats || {})
      .select { |_, s| s[:total] >= 3 }
      .sort_by { |_, s| -s[:win_rate] }
      .first(3)

    # Best hours
    @top_hours = (@hourly_stats || {})
      .select { |_, s| s[:total] >= 2 }
      .sort_by { |_, s| -s[:win_rate] }
      .first(3)

    # Average position size
    @ref_avg_size = @avg_position_size || 0
  end

  def add_item(name, icon, status, detail, recommendation)
    @checklist_items << {
      name: name,
      icon: icon,
      status: status,
      detail: detail,
      recommendation: recommendation
    }
  end

  def format_hour(hour)
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

  def number_to_currency(val)
    ActionController::Base.helpers.number_to_currency(val)
  end
end

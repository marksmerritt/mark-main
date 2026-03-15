class JournalPromptsController < ApplicationController
  include ApiConnected

  def show
    stats_thread = Thread.new do
      api_client.overview
    rescue => e
      Rails.logger.error("journal_prompts stats: #{e.message}")
      {}
    end

    streaks_thread = Thread.new do
      api_client.streaks
    rescue => e
      Rails.logger.error("journal_prompts streaks: #{e.message}")
      {}
    end

    trades_thread = Thread.new do
      api_client.trades(per_page: 10, sort: "closed_at", direction: "desc")
    rescue => e
      Rails.logger.error("journal_prompts trades: #{e.message}")
      {}
    end

    stats = stats_thread.value || {}
    streaks = streaks_thread.value || {}
    raw_trades = trades_thread.value || {}

    trades = raw_trades.is_a?(Hash) ? (raw_trades["trades"] || raw_trades["data"] || []) : Array(raw_trades)
    daily_pnl = normalize_daily_pnl(stats)

    cs = streaks.is_a?(Hash) ? streaks["current_streak"] : nil
    streak_count = cs.is_a?(Hash) ? cs["count"].to_i : cs.to_i
    streak_type = cs.is_a?(Hash) ? cs["type"] : (streaks.is_a?(Hash) ? streaks["streak_type"] : nil)

    today_pnl = daily_pnl[Date.today.to_s].to_f
    yesterday_pnl = daily_pnl[(Date.today - 1).to_s].to_f
    today_trades = trades.select { |t| t["closed_at"]&.start_with?(Date.today.to_s) }

    @context = {
      today_pnl: today_pnl,
      yesterday_pnl: yesterday_pnl,
      today_trade_count: today_trades.length,
      streak_count: streak_count,
      streak_type: streak_type,
      win_rate: stats["win_rate"]&.to_f,
      total_trades: stats["total_trades"].to_i,
      recent_symbols: trades.first(5).map { |t| t["symbol"] }.compact.uniq
    }

    @prompts = generate_prompts(@context)
    @categories = @prompts.map { |p| p[:category] }.uniq
  end

  private

  def normalize_daily_pnl(stats)
    raw = stats.is_a?(Hash) ? (stats["daily_pnl"] || {}) : {}
    pnl = raw.is_a?(Array) ? raw.to_h : raw
    pnl.transform_keys(&:to_s).transform_values(&:to_f)
  end

  def generate_prompts(ctx)
    prompts = []

    # Always-available prompts
    prompts.concat(core_prompts)

    # Context-driven prompts
    if ctx[:today_pnl] > 0
      prompts.concat(winning_day_prompts(ctx))
    elsif ctx[:today_pnl] < 0
      prompts.concat(losing_day_prompts(ctx))
    else
      prompts.concat(no_trades_prompts)
    end

    if ctx[:streak_count].abs >= 3
      prompts.concat(streak_prompts(ctx))
    end

    if ctx[:win_rate] && ctx[:win_rate] < 45
      prompts.concat(struggling_prompts)
    end

    prompts.concat(reflection_prompts)
    prompts.concat(planning_prompts)
    prompts.concat(psychology_prompts)

    prompts.uniq { |p| p[:text] }
  end

  def core_prompts
    [
      { category: "Daily Review", icon: "today", color: "#1a73e8",
        text: "What was my best decision today and why?",
        follow_up: "How can I replicate this decision-making process?" },
      { category: "Daily Review", icon: "today", color: "#1a73e8",
        text: "What was my worst decision today? What triggered it?",
        follow_up: "What rule would have prevented this?" },
      { category: "Daily Review", icon: "today", color: "#1a73e8",
        text: "Did I follow my trading plan today? Rate yourself 1-10.",
        follow_up: "What specific steps will improve this score tomorrow?" },
      { category: "Daily Review", icon: "today", color: "#1a73e8",
        text: "What emotional state was I in during my trades?",
        follow_up: "How did my emotions impact my entries and exits?" }
    ]
  end

  def winning_day_prompts(ctx)
    [
      { category: "Winning Day", icon: "celebration", color: "var(--positive)",
        text: "I made #{ActionController::Base.helpers.number_to_currency(ctx[:today_pnl])} today. Was this skill or luck?",
        follow_up: "What percentage of today's gains came from following my system?" },
      { category: "Winning Day", icon: "celebration", color: "var(--positive)",
        text: "Am I at risk of overconfidence after today's win?",
        follow_up: "What's my plan to stay disciplined tomorrow?" },
      { category: "Winning Day", icon: "celebration", color: "var(--positive)",
        text: "Which of today's trades would I take again? Which would I skip?",
        follow_up: "What separates the A+ setups from the rest?" }
    ]
  end

  def losing_day_prompts(ctx)
    [
      { category: "Losing Day", icon: "healing", color: "var(--negative)",
        text: "I lost #{ActionController::Base.helpers.number_to_currency(ctx[:today_pnl].abs)} today. Was my process still good?",
        follow_up: "Good process with bad outcomes is still good trading. Separate the two." },
      { category: "Losing Day", icon: "healing", color: "var(--negative)",
        text: "Did I honor my stop losses today or did I let losers run?",
        follow_up: "Write down the exact moment you should have exited vs when you did." },
      { category: "Losing Day", icon: "healing", color: "var(--negative)",
        text: "Was I revenge trading at any point today?",
        follow_up: "What was the trigger? How will I interrupt this pattern next time?" },
      { category: "Losing Day", icon: "healing", color: "var(--negative)",
        text: "What would I tell a friend who had today's results?",
        follow_up: "Practice the same self-compassion you'd offer them." }
    ]
  end

  def no_trades_prompts
    [
      { category: "No Trades", icon: "hourglass_empty", color: "#9e9e9e",
        text: "I didn't trade today. Was this patience or avoidance?",
        follow_up: "Sometimes the best trade is no trade. Was this intentional?" },
      { category: "No Trades", icon: "hourglass_empty", color: "#9e9e9e",
        text: "What setups did I see but pass on? Why?",
        follow_up: "Review these later — was passing the right call?" }
    ]
  end

  def streak_prompts(ctx)
    type = ctx[:streak_type]&.downcase == "loss" ? "losing" : "winning"
    [
      { category: "Streak", icon: "local_fire_department", color: "#e65100",
        text: "I'm on a #{ctx[:streak_count].abs}-trade #{type} streak. How is this affecting my mindset?",
        follow_up: "Streaks are normal. What matters is whether your process remains consistent." },
      { category: "Streak", icon: "local_fire_department", color: "#e65100",
        text: "Should I adjust my position sizing during this #{type} streak?",
        follow_up: "Consider reducing size after losses to protect capital, or taking some profits during wins." }
    ]
  end

  def struggling_prompts
    [
      { category: "Performance", icon: "trending_down", color: "#f9a825",
        text: "My win rate is below 45%. Is my strategy still viable?",
        follow_up: "Review: Is the problem entries, exits, or trade selection?" },
      { category: "Performance", icon: "trending_down", color: "#f9a825",
        text: "Should I paper trade for a week to rebuild confidence?",
        follow_up: "There's no shame in stepping back to recalibrate." }
    ]
  end

  def reflection_prompts
    [
      { category: "Reflection", icon: "psychology", color: "#9c27b0",
        text: "What belief about the market was challenged today?",
        follow_up: "How does this change your approach going forward?" },
      { category: "Reflection", icon: "psychology", color: "#9c27b0",
        text: "If I could go back to this morning, what one thing would I change?",
        follow_up: "This is your most actionable improvement for tomorrow." },
      { category: "Reflection", icon: "psychology", color: "#9c27b0",
        text: "What am I grateful for in my trading journey right now?",
        follow_up: "Gratitude builds resilience during drawdowns." },
      { category: "Reflection", icon: "psychology", color: "#9c27b0",
        text: "Describe your ideal trading day. How close was today?",
        follow_up: "What's the gap between ideal and reality? What's one step to close it?" }
    ]
  end

  def planning_prompts
    [
      { category: "Planning", icon: "event_note", color: "#00897b",
        text: "What are my top 3 watchlist symbols for tomorrow?",
        follow_up: "Why these? What's the thesis for each?" },
      { category: "Planning", icon: "event_note", color: "#00897b",
        text: "What is my maximum acceptable loss tomorrow?",
        follow_up: "Write it down. Commit to it. Set an alarm." },
      { category: "Planning", icon: "event_note", color: "#00897b",
        text: "What economic events or catalysts should I be aware of tomorrow?",
        follow_up: "Check the economic calendar and earnings schedule." }
    ]
  end

  def psychology_prompts
    [
      { category: "Psychology", icon: "self_improvement", color: "#5d4037",
        text: "On a scale of 1-10, how disciplined was I today?",
        follow_up: "What specific action would bump this score up by 1?" },
      { category: "Psychology", icon: "self_improvement", color: "#5d4037",
        text: "Did I experience FOMO today? How did I handle it?",
        follow_up: "Write down the specific moment and how you responded." },
      { category: "Psychology", icon: "self_improvement", color: "#5d4037",
        text: "What physical state was I in today? (Sleep, exercise, nutrition)",
        follow_up: "How does your physical well-being correlate with trading performance?" }
    ]
  end
end

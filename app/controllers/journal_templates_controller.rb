class JournalTemplatesController < ApplicationController
  before_action :require_api_connection

  def index
    # Fetch recent journal entries for analysis
    journal_result = begin
      api_client.journal_entries(per_page: 100)
    rescue
      {}
    end

    entries = if journal_result.is_a?(Hash)
      journal_result["journal_entries"] || []
    else
      Array(journal_result)
    end
    entries = entries.select { |e| e.is_a?(Hash) }

    @entry_count = entries.count

    # Compute avg entry length
    word_counts = entries.map { |e|
      content = e["content"] || e["body"] || ""
      content.split(/\s+/).reject { |w| w.strip.empty? }.count
    }
    @avg_entry_length = word_counts.any? ? (word_counts.sum.to_f / word_counts.count).round(0) : 0

    # Writing streak
    sorted_dates = entries.filter_map { |e| Date.parse(e["date"] || "") rescue nil }.uniq.sort
    @writing_streak = 0
    if sorted_dates.any?
      current = Date.current
      while sorted_dates.include?(current)
        @writing_streak += 1
        current -= 1
      end
    end

    # Build templates
    @templates = build_templates

    # Analyze which template types user writes most based on content patterns
    @usage_analysis = analyze_usage(entries)

    # Suggest template based on time of day
    @suggested_template = suggest_by_time
  end

  private

  def build_templates
    [
      {
        id: "pre_market_plan",
        name: "Pre-Market Plan",
        icon: "wb_sunny",
        color: "#ff8f00",
        description: "Set intentions and prepare mentally before the market opens.",
        sections: [
          { title: "Market Outlook", prompt: "What is your overall market read today?", placeholder: "Bullish/bearish bias, key catalysts, overnight action..." },
          { title: "Watchlist", prompt: "Which tickers are you watching and why?", placeholder: "AAPL - testing support at 180, TSLA - earnings reaction..." },
          { title: "Key Levels", prompt: "What are the important price levels to watch?", placeholder: "SPY 450 resistance, QQQ 380 support..." },
          { title: "Risk Limits", prompt: "What are your risk parameters for today?", placeholder: "Max loss: $500, max trades: 5, position size: 100 shares..." },
          { title: "Mental State", prompt: "How are you feeling going into today?", placeholder: "Well-rested, focused, no outside distractions..." }
        ]
      },
      {
        id: "trade_review",
        name: "Trade Review",
        icon: "rate_review",
        color: "#1e88e5",
        description: "Analyze a specific trade in detail to extract lessons.",
        sections: [
          { title: "Setup Description", prompt: "Describe the trade setup you identified.", placeholder: "Bull flag on 5min chart, volume confirmation, sector strength..." },
          { title: "Entry/Exit Rationale", prompt: "Why did you enter and exit where you did?", placeholder: "Entered on breakout above VWAP, exited at resistance..." },
          { title: "What Went Right", prompt: "What aspects of this trade were executed well?", placeholder: "Patient entry, proper position sizing, followed the plan..." },
          { title: "What Went Wrong", prompt: "What could have been done better?", placeholder: "Held too long, ignored the stop loss, over-sized..." },
          { title: "Lessons Learned", prompt: "What will you take away from this trade?", placeholder: "Need to respect stops, wait for confirmation before entry..." },
          { title: "Grade (A-F)", prompt: "Rate your overall execution.", placeholder: "B+ : Good entry, but exit could have been better..." }
        ]
      },
      {
        id: "end_of_day",
        name: "End of Day Review",
        icon: "nightlight",
        color: "#5e35b1",
        description: "Reflect on the day's trading and set up for tomorrow.",
        sections: [
          { title: "Today's P&L Summary", prompt: "What were today's results?", placeholder: "Net P&L: +$350, 3 wins / 1 loss, largest win: AAPL +$200..." },
          { title: "Best Trade", prompt: "Which trade was your best and why?", placeholder: "AAPL long - perfect entry, rode the trend, hit target..." },
          { title: "Worst Trade", prompt: "Which trade was your worst and why?", placeholder: "TSLA short - fought the trend, no edge, revenge trade..." },
          { title: "Emotional State", prompt: "How did emotions affect your trading today?", placeholder: "Stayed calm early, got aggressive after first loss..." },
          { title: "Rule Adherence", prompt: "Did you follow your trading rules?", placeholder: "Followed stop losses on 3/4 trades, broke max loss rule..." },
          { title: "Tomorrow's Plan", prompt: "What's the plan for tomorrow?", placeholder: "Watch for continuation, reduce size if still emotional..." }
        ]
      },
      {
        id: "weekly_review",
        name: "Weekly Review",
        icon: "date_range",
        color: "#00897b",
        description: "Review the week's performance and set goals for next week.",
        sections: [
          { title: "Week's Performance", prompt: "Summarize this week's trading results.", placeholder: "Net P&L: +$1,200, 12 trades, 8 wins, 67% win rate..." },
          { title: "Patterns Noticed", prompt: "What patterns or tendencies did you notice?", placeholder: "Best trades in the morning, overtrading on Fridays..." },
          { title: "Goals for Next Week", prompt: "What specific goals will you work on?", placeholder: "Limit to 3 trades/day, journal every session, improve exits..." },
          { title: "Habit Tracking", prompt: "How well did you stick to your habits?", placeholder: "Pre-market routine: 5/5, journaling: 4/5, exercise: 3/5..." }
        ]
      },
      {
        id: "monthly_review",
        name: "Monthly Review",
        icon: "calendar_month",
        color: "#e53935",
        description: "Deep dive into monthly performance and strategy adjustments.",
        sections: [
          { title: "Monthly Stats", prompt: "What are this month's key statistics?", placeholder: "P&L: +$4,500, 48 trades, 62% win rate, avg R:R 2.1:1..." },
          { title: "Strategy Adjustments", prompt: "What strategy changes should you make?", placeholder: "Tighten stops on momentum trades, add size to A+ setups..." },
          { title: "Risk Management Review", prompt: "How was your risk management this month?", placeholder: "Max drawdown: -$800, stayed within daily limits 90% of time..." },
          { title: "Goals & Objectives", prompt: "What are next month's goals?", placeholder: "Increase avg winner, reduce revenge trades, hit $5k target..." }
        ]
      },
      {
        id: "loss_analysis",
        name: "Loss Analysis",
        icon: "trending_down",
        color: "#d32f2f",
        description: "Dissect a losing trade to prevent repeating mistakes.",
        sections: [
          { title: "Loss Details", prompt: "Describe the losing trade.", placeholder: "Symbol, entry/exit prices, size, total loss amount..." },
          { title: "Root Cause", prompt: "What was the primary reason for the loss?", placeholder: "Poor entry timing, no edge, fought the trend, news event..." },
          { title: "Emotional State", prompt: "What was your emotional state before and during?", placeholder: "Frustrated from previous loss, FOMO entry, overconfident..." },
          { title: "Corrective Action", prompt: "What will you do differently next time?", placeholder: "Wait for pullback, use smaller size, set hard stop before entry..." },
          { title: "Similar Past Losses", prompt: "Have you had similar losses before?", placeholder: "Yes, same pattern on 3/5 and 3/12. Need to add this to rules..." }
        ]
      },
      {
        id: "win_analysis",
        name: "Win Analysis",
        icon: "trending_up",
        color: "#2e7d32",
        description: "Study winning trades to replicate success.",
        sections: [
          { title: "Win Details", prompt: "Describe the winning trade.", placeholder: "Symbol, entry/exit prices, size, total profit..." },
          { title: "What Worked", prompt: "What factors contributed to this win?", placeholder: "Clean setup, good timing, market conditions aligned..." },
          { title: "Replicability", prompt: "Can this setup be repeated consistently?", placeholder: "Yes, appears 2-3 times per week on momentum days..." },
          { title: "Position Sizing Reflection", prompt: "Was the position size appropriate?", placeholder: "Could have sized up given the A+ setup quality..." }
        ]
      },
      {
        id: "strategy_journal",
        name: "Strategy Journal",
        icon: "science",
        color: "#6a1b9a",
        description: "Document and refine your trading strategies.",
        sections: [
          { title: "Strategy Name", prompt: "What do you call this strategy?", placeholder: "Opening Range Breakout, VWAP Fade, Gap and Go..." },
          { title: "Rules", prompt: "What are the exact rules for this strategy?", placeholder: "Only trade first 30 minutes, min 2x avg volume..." },
          { title: "Entry Criteria", prompt: "What conditions must be met for entry?", placeholder: "Break above OR high, volume surge, sector alignment..." },
          { title: "Exit Criteria", prompt: "When do you exit the position?", placeholder: "Target: 2R, stop: below OR low, time stop: 30 minutes..." },
          { title: "Backtest Notes", prompt: "What does backtesting show?", placeholder: "65% win rate over 200 samples, best in trending markets..." },
          { title: "Live Performance", prompt: "How has it performed in live trading?", placeholder: "12 trades, 8 wins, avg profit $180, avg loss $95..." }
        ]
      }
    ]
  end

  def analyze_usage(entries)
    patterns = {
      "pre_market_plan" => { keywords: %w[pre-market premarket watchlist outlook morning plan bias], count: 0, label: "Pre-Market Plans" },
      "trade_review" => { keywords: %w[setup entry exit grade rationale review], count: 0, label: "Trade Reviews" },
      "end_of_day" => { keywords: %w[eod end-of-day p&l pnl best\ trade worst\ trade tomorrow], count: 0, label: "EOD Reviews" },
      "weekly_review" => { keywords: %w[weekly week\ review week's goals\ for\ next], count: 0, label: "Weekly Reviews" },
      "monthly_review" => { keywords: %w[monthly month\ review strategy\ adjustment monthly\ stats], count: 0, label: "Monthly Reviews" },
      "loss_analysis" => { keywords: %w[loss\ analysis root\ cause corrective mistake losing], count: 0, label: "Loss Analyses" },
      "win_analysis" => { keywords: %w[win\ analysis what\ worked replicab winning], count: 0, label: "Win Analyses" },
      "strategy_journal" => { keywords: %w[strategy\ name entry\ criteria exit\ criteria backtest rules], count: 0, label: "Strategy Journals" }
    }

    entries.each do |entry|
      content = (entry["content"] || entry["body"] || "").downcase
      next if content.empty?

      patterns.each do |_id, pattern|
        matched = pattern[:keywords].any? { |kw| content.include?(kw) }
        pattern[:count] += 1 if matched
      end
    end

    # Sort by usage count descending
    patterns.sort_by { |_, v| -v[:count] }
             .map { |id, v| { id: id, label: v[:label], count: v[:count] } }
             .select { |v| v[:count] > 0 }
  end

  def suggest_by_time
    hour = Time.current.hour
    case hour
    when 0..3 then "end_of_day"
    when 4..9 then "pre_market_plan"
    when 10..15 then "trade_review"
    when 16..20 then "end_of_day"
    when 21..23 then "weekly_review"
    else "pre_market_plan"
    end
  end
end

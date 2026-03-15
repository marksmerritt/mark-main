module InsightsHelper
  def trading_insights(stats, streaks = nil)
    return [] unless stats.is_a?(Hash) && stats["total_trades"].to_i >= 5

    insights = []

    # Win rate insights
    win_rate = stats["win_rate"].to_f
    if win_rate >= 60
      insights << { type: "positive", icon: "thumb_up", text: "Your #{win_rate}% win rate is above the 60% target. Stay disciplined." }
    elsif win_rate >= 50
      insights << { type: "neutral", icon: "info", text: "Win rate at #{win_rate}%. Consider reviewing your entry criteria to push above 60%." }
    elsif win_rate > 0
      insights << { type: "warning", icon: "priority_high", text: "Win rate at #{win_rate}% is below 50%. Focus on trade selection quality over quantity." }
    end

    # Profit factor
    pf = stats["profit_factor"].to_f
    if pf > 2
      insights << { type: "positive", icon: "trending_up", text: "Profit factor of #{pf} is excellent. You're earning $#{pf} for every $1 lost." }
    elsif pf < 1 && pf > 0
      insights << { type: "warning", icon: "warning", text: "Profit factor below 1.0 means losses outweigh wins. Tighten your stop losses." }
    end

    # Avg win vs avg loss
    avg_win = stats["avg_win"].to_f
    avg_loss = stats["avg_loss"].to_f.abs
    if avg_win > 0 && avg_loss > 0
      ratio = (avg_win / avg_loss).round(2)
      if ratio < 1
        insights << { type: "warning", icon: "compare_arrows", text: "Average win ($#{avg_win.round(0)}) is smaller than average loss ($#{avg_loss.round(0)}). Let winners run longer." }
      elsif ratio > 2
        insights << { type: "positive", icon: "military_tech", text: "Win/loss ratio of #{ratio}:1 shows great risk management." }
      end
    end

    # Streak insights
    if streaks.is_a?(Hash)
      losing = streaks["current_losing_day_streak"].to_i
      if losing >= 5
        insights << { type: "warning", icon: "pause_circle", text: "#{losing}-day losing streak. Consider reducing position size or taking a mental break." }
      end

      journal_streak = streaks["journal_entry_streak"].to_i
      if journal_streak == 0
        insights << { type: "neutral", icon: "edit_note", text: "You haven't journaled today. Writing helps identify patterns in your trading." }
      end
    end

    insights.first(3) # Max 3 insights
  end

  def earned_badges(stats, streaks = nil)
    return [] unless stats.is_a?(Hash)

    badges = []
    total = stats["total_trades"].to_i
    wr = stats["win_rate"].to_f
    pf = stats["profit_factor"].to_f
    total_pnl = stats["total_pnl"].to_f

    badges << { name: "First Trade", desc: "Log your first trade", icon: "flag", earned: total >= 1 }
    badges << { name: "10 Trades", desc: "Complete 10 trades", icon: "looks_one", earned: total >= 10 }
    badges << { name: "50 Club", desc: "Complete 50 trades", icon: "workspace_premium", earned: total >= 50 }
    badges << { name: "Century", desc: "Complete 100 trades", icon: "emoji_events", earned: total >= 100 }
    badges << { name: "Profitable", desc: "Achieve positive total P&L", icon: "trending_up", earned: total_pnl > 0 }
    badges << { name: "Sharp Shooter", desc: "Win rate above 60%", icon: "gps_fixed", earned: wr >= 60 && total >= 10 }
    badges << { name: "Risk Manager", desc: "Profit factor above 2", icon: "shield", earned: pf >= 2 && total >= 10 }

    if streaks.is_a?(Hash)
      best_streak = streaks["best_win_streak"].to_i
      journal_streak = streaks["journal_entry_streak"].to_i
      badges << { name: "Hot Streak", desc: "Win 5+ trades in a row", icon: "local_fire_department", earned: best_streak >= 5 }
      badges << { name: "Journaler", desc: "7-day journal streak", icon: "auto_stories", earned: journal_streak >= 7 }
      badges << { name: "Iron Will", desc: "30-day journal streak", icon: "diamond", earned: journal_streak >= 30 }
    end

    badges
  end

  def financial_health_score(stats: nil, streaks: nil, budget: nil, notes_stats: nil)
    scores = {}
    weights = {}

    # Trading discipline (0-100)
    if stats.is_a?(Hash) && stats["total_trades"].to_i >= 5
      trading_score = 50 # baseline
      wr = stats["win_rate"].to_f
      pf = stats["profit_factor"].to_f
      total_pnl = stats["total_pnl"].to_f

      # Win rate contribution (0-20)
      trading_score += [[wr - 40, 0].max / 30.0 * 20, 20].min.round

      # Profit factor contribution (0-15)
      trading_score += [[pf - 0.5, 0].max / 2.5 * 15, 15].min.round if pf > 0

      # Profitability (0-15)
      trading_score += 15 if total_pnl > 0
      trading_score -= 10 if total_pnl < 0

      scores[:trading] = trading_score.clamp(0, 100)
      weights[:trading] = 35
    end

    # Journal discipline (0-100)
    if streaks.is_a?(Hash)
      journal_score = 0
      js = streaks["journal_entry_streak"].to_i

      journal_score += [js * 8, 60].min          # streak contributes up to 60
      journal_score += 20 if js >= 7             # weekly bonus
      journal_score += 20 if js >= 30            # monthly bonus

      scores[:journal] = journal_score.clamp(0, 100)
      weights[:journal] = 15
    end

    # Budget discipline (0-100)
    if budget.is_a?(Hash) && budget["income"].to_f > 0
      budget_score = 50 # baseline
      income = budget["income"].to_f
      spent = budget["total_spent"].to_f
      planned = budget["total_planned"].to_f

      # Spending within budget (0-25)
      if planned > 0
        spend_ratio = spent / planned
        if spend_ratio <= 1
          budget_score += 25
        elsif spend_ratio <= 1.1
          budget_score += 15
        end
      end

      # Zero-based budgeting bonus (0-15)
      remaining = budget["remaining"].to_f
      if remaining.abs < income * 0.05
        budget_score += 15
      end

      # Under budget overall (0-10)
      budget_score += 10 if spent < income

      scores[:budget] = budget_score.clamp(0, 100)
      weights[:budget] = 35
    end

    # Notes / productivity (0-100)
    if notes_stats.is_a?(Hash) && notes_stats["total_notes"].to_i > 0
      notes_score = 30 # baseline for having notes
      total = notes_stats["total_notes"].to_i
      recent = notes_stats["recent_count"].to_i rescue 0

      notes_score += [total / 2, 30].min         # quantity up to 30
      notes_score += [recent * 10, 40].min        # recency up to 40

      scores[:notes] = notes_score.clamp(0, 100)
      weights[:notes] = 15
    end

    return nil if scores.empty?

    total_weight = weights.values.sum
    weighted = scores.sum { |k, v| v * weights[k] }
    overall = (weighted.to_f / total_weight).round

    {
      overall: overall,
      grade: score_grade(overall),
      components: scores,
      weights: weights
    }
  end

  def score_grade(score)
    case score
    when 90..100 then "A+"
    when 80..89 then "A"
    when 70..79 then "B"
    when 60..69 then "C"
    when 50..59 then "D"
    else "F"
    end
  end

  def score_color(score)
    case score
    when 80..100 then "var(--positive)"
    when 60..79 then "#ea8600"
    when 40..59 then "#f59e0b"
    else "var(--negative)"
    end
  end

  def deep_trade_analysis(stats, trades = [])
    return [] unless stats.is_a?(Hash) && stats["total_trades"].to_i >= 3

    analysis = []
    total = stats["total_trades"].to_i
    wr = stats["win_rate"].to_f
    pf = stats["profit_factor"].to_f
    avg_win = stats["avg_win"].to_f
    avg_loss = stats["avg_loss"].to_f.abs
    total_pnl = stats["total_pnl"].to_f
    largest_win = stats["largest_win"].to_f
    largest_loss = stats["largest_loss"].to_f.abs

    # Concentration risk
    if largest_win > 0 && total_pnl > 0
      win_concentration = (largest_win / total_pnl * 100).round(1)
      if win_concentration > 50
        analysis << {
          title: "Profit Concentration Risk",
          text: "Your largest single win accounts for #{win_concentration}% of total profits. Diversifying winning strategies would reduce reliance on outlier trades.",
          type: "warning"
        }
      end
    end

    # Loss discipline
    if avg_loss > 0 && largest_loss > avg_loss * 3
      analysis << {
        title: "Loss Outlier Detected",
        text: "Your largest loss ($#{largest_loss.round(0)}) is #{(largest_loss / avg_loss).round(1)}x your average loss ($#{avg_loss.round(0)}). This suggests stop losses may have been moved or ignored on at least one trade.",
        type: "warning"
      }
    end

    # Expectancy
    if wr > 0 && avg_win > 0 && avg_loss > 0
      expectancy = (wr / 100 * avg_win) - ((100 - wr) / 100 * avg_loss)
      analysis << {
        title: "Trade Expectancy",
        text: "Your expected value per trade is #{expectancy >= 0 ? '+' : ''}$#{expectancy.round(2)}. #{expectancy > 0 ? 'Positive expectancy means your edge is working over time.' : 'Negative expectancy means you need to improve either win rate or win/loss size ratio.'}",
        type: expectancy > 0 ? "positive" : "negative"
      }
    end

    # Trade frequency analysis from recent trades
    if trades.is_a?(Array) && trades.length >= 5
      dates = trades.filter_map { |t| Date.parse(t["entry_time"]) rescue nil }.sort
      if dates.length >= 2
        span_days = (dates.last - dates.first).to_i
        avg_per_week = span_days > 0 ? (dates.length.to_f / span_days * 7).round(1) : 0
        if avg_per_week > 15
          analysis << {
            title: "High Trade Frequency",
            text: "You're averaging #{avg_per_week} trades/week. Consider whether each trade meets your playbook criteria — overtrading often erodes profits.",
            type: "neutral"
          }
        elsif avg_per_week < 1 && avg_per_week > 0
          analysis << {
            title: "Low Trade Frequency",
            text: "Averaging #{avg_per_week} trades/week. This patience can be a strength if each trade is high-conviction.",
            type: "positive"
          }
        end
      end
    end

    # Win/loss size ratio assessment
    if avg_win > 0 && avg_loss > 0
      rr = (avg_win / avg_loss).round(2)
      if rr >= 2 && wr >= 40
        analysis << {
          title: "Strong Risk/Reward Profile",
          text: "#{rr}:1 average win/loss ratio with #{wr}% win rate creates a robust edge. This is a professional-grade statistical profile.",
          type: "positive"
        }
      elsif rr < 1 && wr < 60
        analysis << {
          title: "Edge Needs Improvement",
          text: "With a #{rr}:1 win/loss ratio and #{wr}% win rate, you need to either cut losses faster or hold winners longer to build a sustainable edge.",
          type: "warning"
        }
      end
    end

    analysis.first(4)
  end
end

module BadgesHelper
  BADGES = [
    { id: "first_trade", name: "First Blood", icon: "military_tech", desc: "Log your first trade", check: ->(stats) { stats["total_trades"].to_i >= 1 } },
    { id: "ten_trades", name: "Getting Started", icon: "trending_up", desc: "Complete 10 trades", check: ->(stats) { stats["total_trades"].to_i >= 10 } },
    { id: "fifty_trades", name: "Seasoned Trader", icon: "workspace_premium", desc: "Complete 50 trades", check: ->(stats) { stats["total_trades"].to_i >= 50 } },
    { id: "hundred_trades", name: "Centurion", icon: "emoji_events", desc: "Complete 100 trades", check: ->(stats) { stats["total_trades"].to_i >= 100 } },
    { id: "win_rate_60", name: "Sharp Shooter", icon: "gps_fixed", desc: "Achieve 60%+ win rate", check: ->(stats) { stats["win_rate"].to_f >= 60 && stats["total_trades"].to_i >= 10 } },
    { id: "win_rate_70", name: "Sniper", icon: "my_location", desc: "Achieve 70%+ win rate", check: ->(stats) { stats["win_rate"].to_f >= 70 && stats["total_trades"].to_i >= 10 } },
    { id: "profit_factor_2", name: "Edge Master", icon: "insights", desc: "Profit factor above 2.0", check: ->(stats) { stats["profit_factor"].to_f >= 2.0 && stats["total_trades"].to_i >= 10 } },
    { id: "green_month", name: "Green Month", icon: "calendar_month", desc: "Finish a month in profit", check: ->(stats) { stats["total_pnl"].to_f > 0 } },
    { id: "first_journal", name: "Reflective", icon: "auto_stories", desc: "Write your first journal entry", check: ->(stats, streaks) { streaks && streaks["journal_streak"].to_i >= 1 } },
    { id: "journal_week", name: "Disciplined Writer", icon: "edit_note", desc: "7-day journal streak", check: ->(stats, streaks) { streaks && streaks["journal_streak"].to_i >= 7 } },
    { id: "win_streak_5", name: "Hot Streak", icon: "local_fire_department", desc: "5+ consecutive winning days", check: ->(stats, streaks) { streaks && streaks["best_win_streak"].to_i >= 5 } },
    { id: "first_plan", name: "Planner", icon: "assignment", desc: "Create a trade plan", check: ->(stats) { true } }, # Always shown as pending
  ].freeze

  def earned_badges(stats, streaks = nil)
    BADGES.map do |badge|
      earned = begin
        if badge[:check].arity == 2
          badge[:check].call(stats, streaks)
        else
          badge[:check].call(stats)
        end
      rescue
        false
      end
      badge.merge(earned: earned)
    end
  end
end

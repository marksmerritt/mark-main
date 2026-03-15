class MorningBriefingController < ApplicationController
  include ActionView::Helpers::NumberHelper

  QUOTES = [
    { text: "The goal of a successful trader is to make the best trades. Money is secondary.", author: "Alexander Elder" },
    { text: "The most important thing in trading is risk management.", author: "Paul Tudor Jones" },
    { text: "In investing, what is comfortable is rarely profitable.", author: "Robert Arnott" },
    { text: "The market is a device for transferring money from the impatient to the patient.", author: "Warren Buffett" },
    { text: "Don't look for the needle in the haystack. Just buy the haystack.", author: "John Bogle" },
    { text: "Every trade you make should be part of a larger plan.", author: "Van Tharp" },
    { text: "Discipline is the bridge between goals and accomplishment.", author: "Jim Rohn" },
    { text: "It's not whether you're right or wrong that's important, but how much money you make when you're right.", author: "George Soros" },
    { text: "The secret to being successful is doing what you can do well and not doing what you can't do well.", author: "Warren Buffett" },
    { text: "Plan your trade and trade your plan.", author: "Trading Proverb" },
    { text: "Losses are part of the game. It's how you handle them that matters.", author: "Mark Douglas" },
    { text: "Success is not final, failure is not fatal: it is the courage to continue that counts.", author: "Winston Churchill" },
    { text: "The best investment you can make is in yourself.", author: "Warren Buffett" },
    { text: "Compound interest is the eighth wonder of the world.", author: "Albert Einstein" },
    { text: "Do not save what is left after spending, but spend what is left after saving.", author: "Warren Buffett" },
    { text: "A budget is telling your money where to go instead of wondering where it went.", author: "Dave Ramsey" },
    { text: "Financial freedom is a mental, emotional, and educational process.", author: "Robert Kiyosaki" },
    { text: "Small daily improvements over time lead to stunning results.", author: "Robin Sharma" },
    { text: "Consistency is the hallmark of the unimaginative.", author: "Oscar Wilde" },
    { text: "The only way to do great work is to love what you do.", author: "Steve Jobs" },
    { text: "Risk comes from not knowing what you're doing.", author: "Warren Buffett" },
    { text: "Cut your losses short and let your profits run.", author: "David Ricardo" },
    { text: "The trend is your friend until the end when it bends.", author: "Ed Seykota" },
    { text: "Win or lose, everybody gets what they want out of the market.", author: "Ed Seykota" },
    { text: "Beware of little expenses. A small leak will sink a great ship.", author: "Benjamin Franklin" },
    { text: "It is not the strongest of the species that survive, but the one most responsive to change.", author: "Charles Darwin" },
    { text: "The four most dangerous words in investing are: This time it's different.", author: "John Templeton" },
    { text: "An investment in knowledge pays the best interest.", author: "Benjamin Franklin" },
    { text: "Price is what you pay. Value is what you get.", author: "Warren Buffett" },
    { text: "The market can stay irrational longer than you can stay solvent.", author: "John Maynard Keynes" },
    { text: "What gets measured gets managed.", author: "Peter Drucker" },
  ].freeze

  def show
    threads = {}

    # ---- Trading API ----
    if api_token.present?
      threads[:overview] = Thread.new do
        api_client.overview rescue {}
      end

      threads[:streaks] = Thread.new do
        api_client.streaks rescue {}
      end

      threads[:recent_trades] = Thread.new do
        result = api_client.trades(per_page: 10, status: "closed") rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      end

      threads[:open_trades] = Thread.new do
        result = api_client.trades(status: "open", per_page: 50) rescue {}
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      end

      threads[:journal] = Thread.new do
        result = api_client.journal_entries(per_page: 5, sort: "date_desc") rescue {}
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      end
    end

    # ---- Notes API ----
    if notes_api_token.present?
      threads[:notes] = Thread.new do
        result = notes_client.notes(per_page: 3, sort: "updated_at_desc") rescue {}
        all = result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
        all.first(3)
      end

      threads[:notes_stats] = Thread.new do
        notes_client.stats rescue {}
      end
    end

    # ---- Budget API ----
    if budget_api_token.present?
      threads[:transactions] = Thread.new do
        result = budget_client.transactions(
          start_date: Date.current.to_s,
          end_date: (Date.current + 1.day).to_s,
          per_page: 50
        ) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      end

      threads[:budget_overview] = Thread.new do
        budget_client.budget_overview(
          month: Date.current.month,
          year: Date.current.year
        ) rescue {}
      end

      threads[:recurring] = Thread.new do
        budget_client.recurring_summary rescue {}
      end
    end

    # Collect results
    @overview = threads[:overview]&.value || {}
    @streaks_data = threads[:streaks]&.value || {}
    @recent_trades = threads[:recent_trades]&.value || []
    @open_trades = threads[:open_trades]&.value || []
    @journal_entries = threads[:journal]&.value || []
    @recent_notes = threads[:notes]&.value || []
    @notes_stats = threads[:notes_stats]&.value || {}
    @today_transactions = threads[:transactions]&.value || []
    @budget_overview = threads[:budget_overview]&.value || {}
    recurring_result = threads[:recurring]&.value || {}
    @upcoming_bills = recurring_result.is_a?(Hash) ? (recurring_result["upcoming"] || []) : []

    compute_greeting
    compute_yesterday_recap
    compute_financial_snapshot
    compute_streak_info
    compute_readiness_score
    compute_focus_items
    compute_continue_items
    select_quote
  end

  private

  def compute_greeting
    hour = Time.current.hour
    @greeting = if hour < 12
                  "Good Morning"
                elsif hour < 17
                  "Good Afternoon"
                else
                  "Good Evening"
                end
  end

  def compute_yesterday_recap
    yesterday = Date.current - 1.day
    @yesterday_trades = @recent_trades.select do |t|
      exit_date = (t["exit_time"] || t["entry_time"])&.to_s&.slice(0, 10)
      exit_date == yesterday.to_s
    end
    @yesterday_pnl = @yesterday_trades.sum { |t| t["pnl"].to_f }
    @yesterday_wins = @yesterday_trades.count { |t| t["pnl"].to_f > 0 }
    @yesterday_losses = @yesterday_trades.count { |t| t["pnl"].to_f < 0 }
    @yesterday_result = if @yesterday_trades.empty?
                          "No trades"
                        elsif @yesterday_pnl >= 0
                          "Winning day"
                        else
                          "Losing day"
                        end

    # Yesterday's spending
    @yesterday_spending = @today_transactions.select { |t|
      (t["transaction_date"])&.to_s&.slice(0, 10) == yesterday.to_s &&
        t["transaction_type"] != "income"
    }.sum { |t| t["amount"].to_f }
  end

  def compute_financial_snapshot
    # Handle daily_pnl being an Array of pairs
    daily_pnl = @overview["daily_pnl"]
    daily_pnl = daily_pnl.to_h if daily_pnl.is_a?(Array)
    @daily_pnl = daily_pnl || {}

    @total_pnl = @overview["total_pnl"].to_f
    @win_rate = @overview["win_rate"].to_f
    @total_trades = @overview["total_trades"].to_i

    # Week-to-date P&L
    week_start = Date.current.beginning_of_week(:monday)
    @wtd_pnl = @daily_pnl.select { |date_str, _|
      d = Date.parse(date_str) rescue nil
      d && d >= week_start && d <= Date.current
    }.values.sum(&:to_f)

    # Month-to-date P&L
    month_start = Date.current.beginning_of_month
    @mtd_pnl = @daily_pnl.select { |date_str, _|
      d = Date.parse(date_str) rescue nil
      d && d >= month_start && d <= Date.current
    }.values.sum(&:to_f)

    # Today's spending
    @today_spending = @today_transactions.select { |t|
      t["transaction_type"] != "income"
    }.sum { |t| t["amount"].to_f }

    # Budget remaining
    budget_total = @budget_overview.is_a?(Hash) ? @budget_overview["total_budgeted"].to_f : 0
    budget_spent = @budget_overview.is_a?(Hash) ? @budget_overview["total_spent"].to_f : 0
    @budget_remaining = budget_total - budget_spent
    @budget_pct = budget_total > 0 ? (budget_spent / budget_total * 100).round(1) : 0

    # Open positions
    @open_positions_count = @open_trades.count

    # Recent symbols for watchlist focus
    @watchlist_symbols = @recent_trades.map { |t| t["symbol"] }.compact.uniq.first(5)

    # Win rate trend
    if @recent_trades.length >= 6
      first_half = @recent_trades.last(@recent_trades.length / 2)
      second_half = @recent_trades.first(@recent_trades.length / 2)
      first_wr = first_half.any? ? (first_half.count { |t| t["pnl"].to_f > 0 }.to_f / first_half.count * 100) : 0
      second_wr = second_half.any? ? (second_half.count { |t| t["pnl"].to_f > 0 }.to_f / second_half.count * 100) : 0
      @win_rate_trend = if second_wr > first_wr + 5
                          :improving
                        elsif second_wr < first_wr - 5
                          :declining
                        else
                          :stable
                        end
    else
      @win_rate_trend = :stable
    end
  end

  def compute_streak_info
    cs = @streaks_data.is_a?(Hash) ? @streaks_data["current_streak"] : nil
    if cs.is_a?(Hash)
      @streak_type = cs["type"] || "none"
      @streak_count = cs["count"].to_i
    else
      # Fallback to older format
      win_streak = @streaks_data.is_a?(Hash) ? @streaks_data["current_winning_day_streak"].to_i : 0
      loss_streak = @streaks_data.is_a?(Hash) ? @streaks_data["current_losing_day_streak"].to_i : 0
      if win_streak > 0
        @streak_type = "win"
        @streak_count = win_streak
      elsif loss_streak > 0
        @streak_type = "loss"
        @streak_count = loss_streak
      else
        @streak_type = "none"
        @streak_count = 0
      end
    end

    @journal_streak = @streaks_data.is_a?(Hash) ? @streaks_data["journal_entry_streak"].to_i : 0

    # Pinned notes count
    @pinned_notes_count = @notes_stats.is_a?(Hash) ? (@notes_stats["pinned_count"] || @notes_stats["pinned"] || 0).to_i : 0
  end

  def compute_readiness_score
    score = 50 # Base score

    # Streak health (up to +20 or -15)
    if @streak_type == "win" && @streak_count >= 3
      score += 20
    elsif @streak_type == "win" && @streak_count >= 1
      score += 10
    elsif @streak_type == "loss" && @streak_count >= 3
      score -= 15
    elsif @streak_type == "loss" && @streak_count >= 1
      score -= 5
    end

    # Journal consistency (up to +15)
    if @journal_streak >= 5
      score += 15
    elsif @journal_streak >= 3
      score += 10
    elsif @journal_streak >= 1
      score += 5
    end

    # Win rate health (up to +10)
    if @win_rate >= 55
      score += 10
    elsif @win_rate >= 45
      score += 5
    elsif @win_rate > 0 && @win_rate < 40
      score -= 5
    end

    # Budget on track (up to +10)
    if @budget_pct > 0
      if @budget_pct <= 70
        score += 10
      elsif @budget_pct <= 90
        score += 5
      elsif @budget_pct > 100
        score -= 5
      end
    end

    # Journal mood approximation from recent entries
    recent_moods = @journal_entries.map { |j| j["mood"] }.compact
    if recent_moods.any?
      positive_moods = recent_moods.count { |m| %w[great good confident focused calm].include?(m.to_s.downcase) }
      if positive_moods > recent_moods.length / 2
        score += 5
      end
    end

    # Win rate trend bonus
    case @win_rate_trend
    when :improving then score += 5
    when :declining then score -= 5
    end

    @readiness_score = [[score, 0].max, 100].min
    @readiness_label = if @readiness_score >= 80
                         "Ready to Go"
                       elsif @readiness_score >= 60
                         "Looking Good"
                       elsif @readiness_score >= 40
                         "Proceed with Caution"
                       else
                         "Take It Easy"
                       end
    @readiness_color = if @readiness_score >= 80
                         "var(--positive)"
                       elsif @readiness_score >= 60
                         "var(--primary)"
                       elsif @readiness_score >= 40
                         "#f9ab00"
                       else
                         "var(--negative)"
                       end
  end

  def compute_focus_items
    @focus_items = []

    # Streak-based focus
    if @streak_type == "loss" && @streak_count >= 2
      @focus_items << {
        icon: "warning",
        color: "var(--negative)",
        text: "#{@streak_count}-trade losing streak. Review your last trades and consider reducing size."
      }
    elsif @streak_type == "win" && @streak_count >= 3
      @focus_items << {
        icon: "local_fire_department",
        color: "var(--positive)",
        text: "#{@streak_count}-trade winning streak! Stay disciplined and don't get overconfident."
      }
    end

    # Journal consistency
    if @journal_streak == 0
      @focus_items << {
        icon: "auto_stories",
        color: "var(--primary)",
        text: "Write a journal entry today to build your journaling streak."
      }
    elsif @journal_streak >= 5
      @focus_items << {
        icon: "auto_stories",
        color: "var(--positive)",
        text: "#{@journal_streak}-day journal streak! Keep it going with today's entry."
      }
    end

    # Budget awareness
    if @budget_pct > 80 && @budget_pct <= 100
      @focus_items << {
        icon: "account_balance_wallet",
        color: "#f9ab00",
        text: "Budget is #{@budget_pct}% used. Be mindful of spending today."
      }
    elsif @budget_pct > 100
      @focus_items << {
        icon: "account_balance_wallet",
        color: "var(--negative)",
        text: "Over budget by #{number_to_currency(@budget_remaining.abs)}. Pause discretionary spending."
      }
    end

    # Open positions
    if @open_positions_count > 0
      @focus_items << {
        icon: "show_chart",
        color: "var(--primary)",
        text: "#{@open_positions_count} open position#{'s' if @open_positions_count != 1} to monitor today."
      }
    end

    # Upcoming bills
    today_bills = @upcoming_bills.select do |b|
      due = Date.parse(b["next_date"] || b["next_due_date"]) rescue nil
      due && due == Date.current
    end
    if today_bills.any?
      total_due = today_bills.sum { |b| b["amount"].to_f }
      @focus_items << {
        icon: "receipt",
        color: "#e53935",
        text: "#{today_bills.count} bill#{'s' if today_bills.count != 1} due today totaling #{number_to_currency(total_due)}."
      }
    end

    # Win rate trend
    if @win_rate_trend == :declining
      @focus_items << {
        icon: "trending_down",
        color: "var(--negative)",
        text: "Win rate is declining. Focus on higher-quality setups today."
      }
    end

    # Ensure 3-5 items
    if @focus_items.length < 3
      @focus_items << {
        icon: "check_circle",
        color: "var(--positive)",
        text: "Review yesterday's trades and plan your setups for today."
      } unless @focus_items.any? { |i| i[:text].include?("Review") }

      @focus_items << {
        icon: "edit_note",
        color: "#9c27b0",
        text: "Capture any market observations or ideas in your notes."
      } if @focus_items.length < 3
    end

    @focus_items = @focus_items.first(5)
  end

  def compute_continue_items
    @continue_items = []

    # Recent trades
    @recent_trades.first(3).each do |trade|
      @continue_items << {
        icon: "show_chart",
        title: "#{trade['symbol']} - #{trade['side']&.capitalize}",
        subtitle: "#{number_to_currency(trade['pnl'])} P&L",
        path: "/trades/#{trade['id']}",
        color: trade["pnl"].to_f >= 0 ? "var(--positive)" : "var(--negative)"
      }
    end

    # Recent notes
    @recent_notes.first(2).each do |note|
      @continue_items << {
        icon: "description",
        title: note["title"].presence || "Untitled Note",
        subtitle: "Updated #{time_ago(note['updated_at'] || note['created_at'])}",
        path: "/notes/#{note['id']}",
        color: "#9c27b0"
      }
    end

    # Recent journal
    @journal_entries.first(1).each do |entry|
      @continue_items << {
        icon: "auto_stories",
        title: "Journal - #{entry['date']}",
        subtitle: entry["mood"].presence || "No mood recorded",
        path: "/journal_entries/#{entry['id']}",
        color: "var(--primary)"
      }
    end
  end

  def select_quote
    day_of_year = Date.current.yday
    @quote = QUOTES[day_of_year % QUOTES.length]
  end

  def time_ago(timestamp)
    return "recently" unless timestamp
    seconds = Time.current - Time.parse(timestamp.to_s)
    if seconds < 60
      "just now"
    elsif seconds < 3600
      "#{(seconds / 60).to_i}m ago"
    elsif seconds < 86400
      "#{(seconds / 3600).to_i}h ago"
    else
      "#{(seconds / 86400).to_i}d ago"
    end
  rescue
    "recently"
  end
end

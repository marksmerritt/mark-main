class StreakCalendarController < ApplicationController
  include ApiConnected

  def show
    trades_thread = Thread.new do
      api_client.trades(per_page: 500, sort: "closed_at", direction: "desc")
    rescue => e
      Rails.logger.error("streak_calendar trades: #{e.message}")
      {}
    end

    journal_thread = Thread.new do
      api_client.journal_entries(per_page: 500)
    rescue => e
      Rails.logger.error("streak_calendar journal: #{e.message}")
      {}
    end

    notes_thread = Thread.new do
      notes_client.notes(per_page: 500) if notes_api_token.present?
    rescue => e
      Rails.logger.error("streak_calendar notes: #{e.message}")
      {}
    end

    raw_trades = trades_thread.value || {}
    raw_journal = journal_thread.value || {}
    raw_notes = notes_thread.value || {}

    trades = extract_list(raw_trades, "trades")
    journal = extract_list(raw_journal, "journal_entries")
    notes = extract_list(raw_notes, "notes")

    # Build activity map for last 365 days
    today = Date.today
    start_date = today - 364

    @activity = {}
    (start_date..today).each { |d| @activity[d.to_s] = { trades: 0, journal: false, notes: 0, pnl: 0.0 } }

    trades.each do |t|
      d = (t["closed_at"] || t["created_at"]).to_s.slice(0, 10)
      next unless @activity.key?(d)
      @activity[d][:trades] += 1
      @activity[d][:pnl] += t["pnl"].to_f
    end

    journal.each do |j|
      d = (j["date"] || j["created_at"]).to_s.slice(0, 10)
      @activity[d][:journal] = true if @activity.key?(d)
    end

    notes.each do |n|
      d = (n["created_at"] || n["updated_at"]).to_s.slice(0, 10)
      @activity[d][:notes] += 1 if @activity.key?(d)
    end

    # Compute streaks
    @current_trading_streak = 0
    @current_journal_streak = 0
    @longest_trading_streak = 0
    @longest_journal_streak = 0
    @total_active_days = 0
    @total_journal_days = 0
    @total_trades = 0
    @total_notes = 0

    trading_streak = 0
    journal_streak = 0

    (start_date..today).to_a.reverse.each_with_index do |d, i|
      day = @activity[d.to_s]
      next unless day

      if day[:trades] > 0
        trading_streak += 1 if i == 0 || trading_streak > 0
        @current_trading_streak = trading_streak if i < 30
      else
        @longest_trading_streak = [trading_streak, @longest_trading_streak].max
        trading_streak = 0 if i > 0
      end

      if day[:journal]
        journal_streak += 1 if i == 0 || journal_streak > 0
        @current_journal_streak = journal_streak if i < 30
      else
        @longest_journal_streak = [journal_streak, @longest_journal_streak].max
        journal_streak = 0 if i > 0
      end
    end

    # Recalculate streaks properly
    @current_trading_streak = 0
    @current_journal_streak = 0
    (start_date..today).to_a.reverse.each do |d|
      day = @activity[d.to_s]
      break unless day
      if day[:trades] > 0
        @current_trading_streak += 1
      else
        break
      end
    end

    cur_j = 0
    (start_date..today).to_a.reverse.each do |d|
      day = @activity[d.to_s]
      break unless day
      if day[:journal]
        cur_j += 1
      else
        break
      end
    end
    @current_journal_streak = cur_j

    # Longest streaks
    ts = 0
    js = 0
    (start_date..today).each do |d|
      day = @activity[d.to_s]
      next unless day
      if day[:trades] > 0
        ts += 1
        @longest_trading_streak = [ts, @longest_trading_streak].max
      else
        ts = 0
      end
      if day[:journal]
        js += 1
        @longest_journal_streak = [js, @longest_journal_streak].max
      else
        js = 0
      end
      @total_active_days += 1 if day[:trades] > 0 || day[:journal] || day[:notes] > 0
      @total_journal_days += 1 if day[:journal]
      @total_trades += day[:trades]
      @total_notes += day[:notes]
    end

    @start_date = start_date
    @today = today
  end

  private

  def extract_list(data, key)
    if data.is_a?(Hash)
      data[key] || data["data"] || []
    elsif data.is_a?(Array)
      data
    else
      []
    end
  end
end

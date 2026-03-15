class JournalEntriesController < ApplicationController
  before_action :require_api_connection

  def index
    filter_params = params.permit(:mood, :start_date, :end_date, :page).to_h.compact_blank

    threads = {}
    threads[:entries] = Thread.new { api_client.journal_entries(filter_params) }
    threads[:mood] = Thread.new { api_client.mood_analytics(filter_params.except("page")) rescue {} }

    result = threads[:entries].value
    @journal_entries = result["journal_entries"] || result
    @meta = result["meta"] || {}

    return render partial: "entry_cards", layout: false if params[:page].to_i > 1

    mood_result = threads[:mood].value
    @mood_analytics = mood_result.is_a?(Hash) ? mood_result : {}
  end

  def show
    @journal_entry = api_client.journal_entry(params[:id])
  end

  def new
    @journal_entry = {}
    load_smart_context
  end

  def create
    result = api_client.create_journal_entry(journal_entry_params)
    if result["id"]
      redirect_to journal_entry_path(result["id"]), notice: "Journal entry created successfully."
    else
      @journal_entry = journal_entry_params
      @errors = result["errors"] || [ result["message"] ]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @journal_entry = api_client.journal_entry(params[:id])
  end

  def update
    result = api_client.update_journal_entry(params[:id], journal_entry_params)
    if result["id"]
      redirect_to journal_entry_path(result["id"]), notice: "Journal entry updated successfully."
    else
      @journal_entry = api_client.journal_entry(params[:id])
      @errors = result["errors"] || [ result["message"] ]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    api_client.delete_journal_entry(params[:id])
    redirect_to journal_entries_path, notice: "Journal entry deleted successfully."
  end

  def calendar
    @month_offset = params[:month].to_i
    today = Date.current
    @target_date = today - @month_offset.months
    @month_start = @target_date.beginning_of_month
    @month_end = @target_date.end_of_month

    threads = {}
    threads[:entries] = Thread.new {
      api_client.journal_entries(
        start_date: @month_start.to_s,
        end_date: @month_end.to_s,
        per_page: 50
      )
    }
    threads[:stats] = Thread.new {
      api_client.overview(
        start_date: @month_start.to_s,
        end_date: @month_end.to_s
      )
    }

    result = threads[:entries].value
    entries = result.is_a?(Hash) ? (result["journal_entries"] || []) : (result || [])
    @entries_by_date = entries.index_by { |e| e["date"] }

    stats = threads[:stats].value
    @daily_pnl = stats.is_a?(Hash) ? (stats["daily_pnl"] || {}) : {}
  end

  private

  def load_smart_context
    threads = {}
    threads[:today] = Thread.new {
      api_client.trades(start_date: Date.current.to_s, end_date: (Date.current + 1).to_s, per_page: 50) rescue {}
    }
    threads[:stats] = Thread.new { api_client.overview rescue {} }
    threads[:streaks] = Thread.new { api_client.streaks rescue {} }

    today_result = threads[:today].value
    today_trades = today_result.is_a?(Hash) ? (today_result["trades"] || []) : (today_result || [])
    stats = threads[:stats].value || {}
    streaks = threads[:streaks].value || {}

    @smart_context = {
      today_trades: today_trades.count,
      today_pnl: today_trades.sum { |t| t["pnl"].to_f }.round(2),
      today_wins: today_trades.count { |t| t["pnl"].to_f > 0 },
      today_losses: today_trades.count { |t| t["pnl"].to_f < 0 },
      today_symbols: today_trades.map { |t| t["symbol"] }.uniq.compact,
      today_best: today_trades.max_by { |t| t["pnl"].to_f }&.slice("symbol", "pnl"),
      today_worst: today_trades.min_by { |t| t["pnl"].to_f }&.slice("symbol", "pnl"),
      win_rate: stats["win_rate"],
      total_pnl: stats["total_pnl"],
      current_streak: streaks.is_a?(Hash) ? (streaks["current_streak"].is_a?(Hash) ? streaks["current_streak"]["count"].to_i : streaks["current_streak"]) : nil,
      streak_type: streaks.is_a?(Hash) ? (streaks["current_streak"].is_a?(Hash) ? streaks["current_streak"]["type"] : streaks["streak_type"]) : nil
    }
  rescue
    @smart_context = {}
  end

  def journal_entry_params
    params.require(:journal_entry).permit(:date, :content, :mood, :market_conditions, :plan, :review).to_h.compact_blank
  end
end

class TradesController < ApplicationController
  before_action :require_api_connection

  def index
    filter_params = params.permit(:symbol, :asset_class, :status, :side, :tag_id, :start_date, :end_date, :page).to_h.compact_blank
    result = api_client.trades(filter_params)
    @trades = result["trades"] || result
    @meta = result["meta"] || {}

    if params[:page].to_i > 1
      render partial: "trade_rows", layout: false
    else
      @tags = cached_tags
      @period_stats = compute_period_stats(@trades)

      # Fetch broader closed trades set for the heatmap calendar (last year)
      heatmap_thread = Thread.new {
        api_client.trades(status: "closed", per_page: 500)
      }
      heatmap_result = heatmap_thread.value
      @heatmap_trades = heatmap_result.is_a?(Hash) ? (heatmap_result["trades"] || []) : (heatmap_result || [])
    end
  end

  def show
    threads = {}
    threads[:trade] = Thread.new { api_client.trade(params[:id]) }
    threads[:screenshots] = Thread.new { api_client.trade_screenshots(params[:id]) }

    @trade = threads[:trade].value
    screenshot_result = threads[:screenshots].value
    @screenshots = screenshot_result.is_a?(Hash) ? (screenshot_result["trade_screenshots"] || []) : []

    # Fetch related trades, notes, and playbooks in parallel
    related_threads = {}
    related_threads[:playbooks] = Thread.new {
      result = api_client.playbooks
      all = result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["playbooks"] || []) : [])
      trade_setup = @trade["setup"].to_s.downcase
      trade_notes = @trade["notes"].to_s.downcase
      all.select { |p|
        name = p["name"].to_s.downcase
        name.present? && (trade_setup.include?(name) || trade_notes.include?(name) || name.include?(@trade["symbol"].to_s.downcase))
      }.first(3)
    }
    if @trade["symbol"].present?
      related_threads[:trades] = Thread.new {
        result = api_client.trades(symbol: @trade["symbol"], per_page: 10, status: "closed")
        all = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
        all.reject { |t| t["id"].to_s == @trade["id"].to_s }.first(5)
      }
      if notes_api_token.present?
        related_threads[:notes] = Thread.new {
          result = notes_client.search(q: @trade["symbol"])
          result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
        }
      end
    end

    # Fetch journal entry for trade date
    trade_date = @trade["entry_time"]&.to_s&.slice(0, 10)
    if trade_date.present?
      related_threads[:journal] = Thread.new {
        result = api_client.journal_entries(start_date: trade_date, end_date: trade_date, per_page: 1)
        entries = result.is_a?(Hash) ? (result["journal_entries"] || []) : (result || [])
        entries.first
      }
    end

    @related_trades = related_threads[:trades]&.value || []
    @linked_notes = related_threads[:notes]&.value || []
    @matched_playbooks = related_threads[:playbooks]&.value || []
    @trade_journal = related_threads[:journal]&.value
  end

  def new
    @trade = params[:trade]&.permit(
      :symbol, :asset_class, :side, :quantity, :entry_price, :setup
    )&.to_h&.compact_blank || {}
    @tags = cached_tags
    @symbols = extract_symbols
    @tag_history = build_tag_history
  end

  def create
    result = api_client.create_trade(trade_params.merge(tag_ids: params[:tag_ids]))
    if result["id"]
      redirect_to trade_path(result["id"]), notice: "Trade created successfully."
    else
      @trade = trade_params
      @tags = cached_tags
      @errors = result["errors"] || [ result["message"] ]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @trade = api_client.trade(params[:id])
    @tags = cached_tags
    @symbols = extract_symbols
    @tag_history = build_tag_history
  end

  def update
    result = api_client.update_trade(params[:id], trade_params.merge(tag_ids: params[:tag_ids]))
    if result["id"]
      redirect_to trade_path(result["id"]), notice: "Trade updated successfully."
    else
      @trade = api_client.trade(params[:id])
      @tags = cached_tags
      @errors = result["errors"] || [ result["message"] ]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    api_client.delete_trade(params[:id])
    redirect_to trades_path, notice: "Trade deleted successfully."
  end

  def bulk_tag
    result = api_client.bulk_update_trades(params[:trade_ids], { tag_ids: params[:tag_ids] })
    render json: result
  end

  def bulk_delete
    result = api_client.bulk_delete_trades(params[:trade_ids])
    render json: result
  end

  def review
    filter = params.permit(:symbol, :asset_class, :status, :side, :tag_id, :start_date, :end_date).to_h.compact_blank
    filter[:status] ||= "closed"
    filter[:per_page] = 200
    result = api_client.trades(filter)
    all_trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])

    @trade_ids = all_trades.map { |t| t["id"] }
    current_idx = params[:idx].to_i.clamp(0, [@trade_ids.length - 1, 0].max)
    @current_idx = current_idx
    @total = @trade_ids.length

    if @trade_ids.any?
      @trade = api_client.trade(@trade_ids[current_idx])
    end
  end

  def submit_review
    review_attrs = params.permit(:trade_grade, :emotional_state, :followed_plan, :mistakes, :lessons).to_h.compact_blank
    api_client.review_trade(params[:id], review_attrs)
    return_to = params[:return_to].presence || review_trades_path
    redirect_to return_to, notice: "Trade reviewed."
  end

  def review_stats
    @stats = api_client.review_stats
  end

  def create_screenshot
    result = api_client.create_screenshot(params[:trade_id], screenshot_params)
    if result["id"]
      render json: result, status: :created
    else
      render json: { errors: result["errors"] || [result["message"]] }, status: :unprocessable_entity
    end
  end

  def destroy_screenshot
    api_client.delete_screenshot(params[:trade_id], params[:id])
    redirect_to trade_path(params[:trade_id]), notice: "Screenshot removed."
  end

  def import_wizard
  end

  def import
    if params[:file].blank?
      redirect_to trades_path, alert: "Please select a CSV file."
      return
    end

    csv_content = params[:file].read
    result = api_client.import_trades(csv_content)

    if result["imported"]
      notice = "Imported #{result["imported"]} trades."
      notice += " #{result["errors"].length} errors." if result["errors"]&.any?
      redirect_to trades_path, notice: notice
    else
      redirect_to trades_path, alert: result["error"] || "Import failed."
    end
  end

  def export
    csv = api_client.export_trades(params.permit(:symbol, :start_date, :end_date).to_h.compact_blank)
    send_data csv, filename: "trades_#{Date.today}.csv", type: "text/csv"
  end

  private

  def build_tag_history
    result = api_client.trades(per_page: 100, status: "closed")
    trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
    history = {}
    trades.each do |trade|
      sym = trade["symbol"]
      next unless sym.present? && trade["tags"].is_a?(Array)
      tag_names = trade["tags"].map { |t| t["name"] }.compact
      history[sym] ||= []
      history[sym].concat(tag_names)
    end
    history.transform_values { |names| names.tally.sort_by { |_, c| -c }.map(&:first).first(5) }
  rescue
    {}
  end

  def extract_symbols
    result = api_client.report_by_symbol
    return [] unless result.is_a?(Array)
    result.map { |s| s["symbol"] }.compact.uniq.sort
  rescue
    []
  end

  def compute_period_stats(trades)
    return nil unless trades.is_a?(Array)

    closed = trades.select { |t| t["status"] == "closed" && t["pnl"] && t["exit_time"] }
    return nil if closed.empty?

    today = Date.today
    this_week_start = today.beginning_of_week
    last_week_start = this_week_start - 7
    last_week_end = this_week_start - 1
    this_month_start = today.beginning_of_month
    last_month_start = (this_month_start - 1).beginning_of_month
    last_month_end = this_month_start - 1

    this_week_pnl = closed.select { |t|
      d = Date.parse(t["exit_time"]) rescue nil
      d && d >= this_week_start && d <= today
    }.sum { |t| t["pnl"].to_f }

    last_week_pnl = closed.select { |t|
      d = Date.parse(t["exit_time"]) rescue nil
      d && d >= last_week_start && d <= last_week_end
    }.sum { |t| t["pnl"].to_f }

    this_month_pnl = closed.select { |t|
      d = Date.parse(t["exit_time"]) rescue nil
      d && d >= this_month_start && d <= today
    }.sum { |t| t["pnl"].to_f }

    last_month_pnl = closed.select { |t|
      d = Date.parse(t["exit_time"]) rescue nil
      d && d >= last_month_start && d <= last_month_end
    }.sum { |t| t["pnl"].to_f }

    {
      this_week: this_week_pnl.round(2),
      last_week: last_week_pnl.round(2),
      week_delta: (this_week_pnl - last_week_pnl).round(2),
      this_month: this_month_pnl.round(2),
      last_month: last_month_pnl.round(2),
      month_delta: (this_month_pnl - last_month_pnl).round(2)
    }
  end

  def screenshot_params
    params.require(:trade_screenshot).permit(:filename, :content_type, :caption).to_h.compact_blank
  end

  def trade_params
    params.require(:trade).permit(
      :symbol, :asset_class, :side, :quantity, :entry_price, :exit_price,
      :entry_time, :exit_time, :commissions, :fees, :notes, :setup,
      :mistakes, :lessons, :max_favorable_excursion, :max_adverse_excursion,
      :stop_loss, :take_profit
    ).to_h.compact_blank
  end
end

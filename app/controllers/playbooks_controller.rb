class PlaybooksController < ApplicationController
  before_action :require_api_connection

  def index
    filter = params.permit(:status, :q).to_h.compact_blank
    threads = {}
    threads[:playbooks] = Thread.new { api_client.playbooks(filter) }
    threads[:trades] = Thread.new { api_client.trades(status: "closed", per_page: 500) }

    pb_result = threads[:playbooks].value
    @playbooks = pb_result.is_a?(Hash) ? (pb_result["playbooks"] || [pb_result]) : (pb_result || [])
    @playbooks = Array.wrap(@playbooks).reject { |p| p.is_a?(Hash) && p["error"] }

    trade_result = threads[:trades].value
    trades = trade_result.is_a?(Hash) ? (trade_result["trades"] || []) : (trade_result || [])

    # Build performance stats per playbook (matched by setup field)
    @playbook_stats = {}
    @playbooks.each do |pb|
      name = pb["name"]
      next unless name.present?
      matching = trades.select { |t| t["setup"].to_s.downcase == name.downcase }
      next if matching.empty?
      wins = matching.count { |t| t["pnl"].to_f > 0 }
      total_pnl = matching.sum { |t| t["pnl"].to_f }
      @playbook_stats[name] = {
        trades: matching.count,
        wins: wins,
        losses: matching.count - wins,
        win_rate: (wins.to_f / matching.count * 100).round(1),
        total_pnl: total_pnl.round(2),
        avg_pnl: (total_pnl / matching.count).round(2)
      }
    end
  end

  def show
    @playbook = api_client.playbook(params[:id])
    # Find trades using this playbook's name as setup
    result = api_client.trades(setup: @playbook["name"], status: "closed", per_page: 50)
    @related_trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
  end

  def new
    @playbook = {}
  end

  def create
    result = api_client.create_playbook(playbook_params)
    if result["id"]
      redirect_to playbook_path(result["id"]), notice: "Playbook created."
    else
      flash.now[:alert] = result["message"] || "Could not create playbook."
      @playbook = playbook_params
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @playbook = api_client.playbook(params[:id])
  end

  def update
    result = api_client.update_playbook(params[:id], playbook_params)
    if result["id"]
      redirect_to playbook_path(result["id"]), notice: "Playbook updated."
    else
      flash.now[:alert] = result["message"] || "Could not update playbook."
      @playbook = api_client.playbook(params[:id]).merge(playbook_params)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    api_client.delete_playbook(params[:id])
    redirect_to playbooks_path, notice: "Playbook deleted."
  end

  private

  def playbook_params
    params.require(:playbook).permit(:name, :description, :setup_rules, :entry_criteria,
                                     :exit_criteria, :risk_rules, :asset_classes,
                                     :timeframes, :status)
  end
end

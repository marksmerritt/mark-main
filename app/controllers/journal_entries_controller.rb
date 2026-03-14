class JournalEntriesController < ApplicationController
  before_action :require_api_connection

  def index
    filter_params = params.permit(:mood, :start_date, :end_date, :page).to_h.compact_blank
    result = api_client.journal_entries(filter_params)
    @journal_entries = result["journal_entries"] || result
    @meta = result["meta"] || {}

    return render partial: "entry_cards", layout: false if params[:page].to_i > 1
  end

  def show
    @journal_entry = api_client.journal_entry(params[:id])
  end

  def new
    @journal_entry = {}
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

  private

  def journal_entry_params
    params.require(:journal_entry).permit(:date, :content, :mood, :market_conditions, :plan, :review).to_h.compact_blank
  end
end

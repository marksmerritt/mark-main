module Budget
  class TransactionsController < ApplicationController
    before_action :require_budget_connection

    def index
      filter = params.permit(:month, :year, :type, :status, :unassigned, :merchant, :page).to_h.compact_blank
      filter[:month] ||= Date.current.month.to_s
      filter[:year] ||= Date.current.year.to_s
      threads = {}
      threads[:transactions] = Thread.new { budget_client.transactions(filter) }
      threads[:budget] = Thread.new { budget_client.current_budget }
      result = threads[:transactions].value
      @transactions = result["transactions"] || result
      @meta = result["meta"] || {}
      budget = threads[:budget].value
      @budget_items = []
      if budget.is_a?(Hash) && budget["categories"].is_a?(Array)
        budget["categories"].each do |cat|
          (cat["items"] || []).each do |item|
            @budget_items << { id: item["id"], label: "#{cat["name"]} > #{item["name"]}" }
          end
        end
      end
    end

    def new
      @transaction = {}
    end

    def create
      result = budget_client.create_transaction(transaction_params)
      if result["id"]
        redirect_to budget_transactions_path, notice: "Transaction added."
      else
        @transaction = transaction_params
        @errors = result["errors"] || [result["message"]]
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @transaction = budget_client.transaction(params[:id])
    end

    def update
      result = budget_client.update_transaction(params[:id], transaction_params)
      if result["id"]
        redirect_to budget_transactions_path, notice: "Transaction updated."
      else
        @transaction = budget_client.transaction(params[:id])
        @errors = result["errors"] || [result["message"]]
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      budget_client.delete_transaction(params[:id])
      redirect_to budget_transactions_path, notice: "Transaction deleted."
    end

    def merchants
      results = budget_client.merchant_autocomplete(params[:q].to_s)
      render json: results.is_a?(Array) ? results : []
    end

    def search
      @query = params[:q].to_s
      if @query.present?
        @results = budget_client.transactions(
          merchant: @query,
          start_date: 1.year.ago.to_date.to_s,
          end_date: Date.current.to_s
        )
        @results = @results["transactions"] || @results
        @results = [] unless @results.is_a?(Array)
      else
        @results = []
      end
    end

    def split
      splits = params[:splits].map do |s|
        { amount: s[:amount], description: s[:description], budget_item_id: s[:budget_item_id] }
      end
      result = budget_client.split_transaction(params[:id], splits)
      if result["errors"]
        redirect_to budget_transactions_path, alert: result["errors"].join(", ")
      else
        redirect_to budget_transactions_path, notice: "Transaction split into #{splits.size} parts."
      end
    end

    def unsplit
      budget_client.unsplit_transaction(params[:id])
      redirect_to budget_transactions_path, notice: "Split removed."
    end

    def add_tag
      budget_client.add_tag_to_transaction(params[:id], params[:tag_name])
      redirect_back fallback_location: budget_transactions_path, notice: "Tag added."
    end

    def remove_tag
      budget_client.remove_tag_from_transaction(params[:id], params[:tag_name])
      redirect_back fallback_location: budget_transactions_path, notice: "Tag removed."
    end

    def bulk_assign
      ids = params[:transaction_ids].select(&:present?).map(&:to_i)
      if ids.empty?
        redirect_to budget_transactions_path, alert: "No transactions selected."
        return
      end
      result = budget_client.bulk_assign_transactions(ids, params[:budget_item_id])
      redirect_to budget_transactions_path(month: params[:month], year: params[:year]),
                  notice: "#{result['updated'] || 0} transactions assigned."
    end

    def bulk_delete
      ids = params[:transaction_ids].select(&:present?).map(&:to_i)
      if ids.empty?
        redirect_to budget_transactions_path, alert: "No transactions selected."
        return
      end
      result = budget_client.bulk_delete_transactions(ids)
      redirect_to budget_transactions_path(month: params[:month], year: params[:year]),
                  notice: "#{result['deleted'] || 0} transactions deleted."
    end

    def import_wizard
    end

    def export
      filter = params.permit(:month, :year, :type, :status, :merchant).to_h.compact_blank
      csv_data = budget_client.export_transactions(filter)

      send_data csv_data,
        filename: "transactions-#{Date.current}.csv",
        type: "text/csv",
        disposition: "attachment"
    end

    def import
      if params[:file].blank?
        redirect_to budget_transactions_path, alert: "Please select a CSV file to import."
        return
      end

      csv_data = params[:file].read
      result = budget_client.import_transactions(csv_data)

      if result["error"]
        redirect_to budget_transactions_path, alert: "Import failed: #{result['message']}"
      else
        imported = result["imported"] || 0
        error_count = result["errors"]&.size || 0
        message = "Imported #{imported} transaction#{'s' unless imported == 1}."
        message += " #{error_count} row#{'s' unless error_count == 1} skipped due to errors." if error_count > 0
        redirect_to budget_transactions_path, notice: message
      end
    end

    private

    def transaction_params
      params.require(:transaction).permit(
        :amount, :description, :merchant, :transaction_date,
        :transaction_type, :status, :budget_item_id, :notes
      ).to_h.compact_blank
    end
  end
end

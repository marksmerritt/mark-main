module Budget
  class RecurringController < ApplicationController
    before_action :require_budget_connection

    def index
      threads = {}
      threads[:items] = Thread.new { budget_client.recurring_transactions(active: "true") }
      threads[:summary] = Thread.new { budget_client.recurring_summary }
      @items = threads[:items].value
      @summary = threads[:summary].value
    end

    def calendar
      @month = (params[:month] || Date.current.month).to_i
      @year = (params[:year] || Date.current.year).to_i
      @items = budget_client.recurring_transactions(active: "true")
      @items = [] unless @items.is_a?(Array)
    end

    def new
      @recurring = {}
    end

    def create
      result = budget_client.create_recurring_transaction(recurring_params)
      if result["id"]
        redirect_to budget_recurring_index_path, notice: "Recurring transaction added."
      else
        @recurring = recurring_params
        @errors = result["errors"] || [result["message"]]
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @recurring = budget_client.recurring_transaction(params[:id])
    end

    def update
      result = budget_client.update_recurring_transaction(params[:id], recurring_params)
      if result["id"]
        redirect_to budget_recurring_index_path, notice: "Updated."
      else
        @recurring = budget_client.recurring_transaction(params[:id])
        @errors = result["errors"] || [result["message"]]
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      budget_client.delete_recurring_transaction(params[:id])
      redirect_to budget_recurring_index_path, notice: "Deleted."
    end

    def skip
      budget_client.skip_recurring(params[:id])
      redirect_to budget_recurring_index_path, notice: "Due date advanced."
    end

    def auto_process
      result = budget_client.auto_process_recurring
      count = result.is_a?(Hash) ? result["count"].to_i : 0
      redirect_to budget_recurring_index_path, notice: "#{count} recurring transaction#{'s' unless count == 1} processed."
    end

    private

    def recurring_params
      params.require(:recurring_transaction).permit(
        :name, :amount, :category_name, :frequency, :next_due, :active, :merchant
      ).to_h.compact_blank
    end
  end
end

module Budget
  class BudgetsController < ApplicationController
    before_action :require_budget_connection

    def index
      @budgets = budget_client.budgets
    end

    def show
      @budget = budget_client.budget(params[:id])
    end

    def new
      @budget = {}
      @templates = budget_client.budget_templates
      @templates = [] unless @templates.is_a?(Array)
    end

    def create
      if params[:from_template]
        template_key = params[:template].presence || "ramsey"
        result = budget_client.create_budget_from_template(budget_params, template: template_key)
      else
        result = budget_client.create_budget(budget_params)
      end

      if result["id"]
        redirect_to budget_budget_path(result["id"]), notice: "Budget created."
      else
        @budget = budget_params
        @errors = result["errors"] || [result["message"]]
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @budget = budget_client.budget(params[:id])
    end

    def update
      result = budget_client.update_budget(params[:id], budget_params)
      if result["id"]
        redirect_to budget_budget_path(result["id"]), notice: "Budget updated."
      else
        @budget = budget_client.budget(params[:id])
        @errors = result["errors"] || [result["message"]]
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      budget_client.delete_budget(params[:id])
      redirect_to budget_budgets_path, notice: "Budget deleted."
    end

    def copy
      result = budget_client.copy_budget(params[:id], params[:target_month], params[:target_year])
      if result["id"]
        redirect_to budget_budget_path(result["id"]), notice: "Budget copied."
      else
        redirect_to budget_budget_path(params[:id]), alert: "Failed to copy budget."
      end
    end

    def rollover
      if params[:preview]
        @budget = budget_client.budget(params[:id])
        @preview = budget_client.rollover_preview(params[:id])
        @preview = [] unless @preview.is_a?(Array)
        render :rollover_preview
      else
        result = budget_client.rollover_budget(params[:id], params[:target_month], params[:target_year])
        if result["target_budget_id"]
          redirect_to budget_budget_path(result["target_budget_id"]), notice: "Rollover applied — #{result['adjustments']&.size || 0} items adjusted."
        else
          redirect_to budget_budget_path(params[:id]), alert: result["error"] || "Rollover failed."
        end
      end
    end

    private

    def budget_params
      params.require(:budget).permit(:month, :year, :name, :income, :notes).to_h.compact_blank
    end
  end
end

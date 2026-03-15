module Budget
  class BudgetCategoriesController < ApplicationController
    before_action :require_budget_connection

    def create
      result = budget_client.create_budget_category(params[:budget_id], category_params)
      if result["id"]
        redirect_to budget_budget_path(params[:budget_id]), notice: "Category added."
      else
        redirect_to budget_budget_path(params[:budget_id]), alert: result["message"] || "Failed to create category."
      end
    end

    def update
      result = budget_client.update_budget_category(params[:budget_id], params[:id], category_params)
      if result["id"]
        redirect_to budget_budget_path(params[:budget_id]), notice: "Category updated."
      else
        redirect_to budget_budget_path(params[:budget_id]), alert: result["message"] || "Failed to update category."
      end
    end

    def destroy
      budget_client.delete_budget_category(params[:budget_id], params[:id])
      redirect_to budget_budget_path(params[:budget_id]), notice: "Category deleted."
    end

    private

    def category_params
      params.require(:budget_category).permit(:name, :planned_amount).to_h.compact_blank
    end
  end
end

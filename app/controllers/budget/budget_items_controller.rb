module Budget
  class BudgetItemsController < ApplicationController
    before_action :require_budget_connection

    def create
      result = budget_client.create_budget_item(params[:budget_id], params[:budget_category_id], item_params)
      if result["id"]
        redirect_to budget_budget_path(params[:budget_id]), notice: "Item added."
      else
        redirect_to budget_budget_path(params[:budget_id]), alert: result["message"] || "Failed to create item."
      end
    end

    def update
      result = budget_client.update_budget_item(params[:budget_id], params[:budget_category_id], params[:id], item_params)
      if result["id"]
        redirect_to budget_budget_path(params[:budget_id]), notice: "Item updated."
      else
        redirect_to budget_budget_path(params[:budget_id]), alert: result["message"] || "Failed to update item."
      end
    end

    def destroy
      budget_client.delete_budget_item(params[:budget_id], params[:budget_category_id], params[:id])
      redirect_to budget_budget_path(params[:budget_id]), notice: "Item deleted."
    end

    private

    def item_params
      params.require(:budget_item).permit(:name, :planned_amount).to_h.compact_blank
    end
  end
end

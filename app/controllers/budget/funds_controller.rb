module Budget
  class FundsController < ApplicationController
    before_action :require_budget_connection

    def index
      @funds = budget_client.funds
    end

    def show
      @fund = budget_client.fund(params[:id])
    end

    def new
      @fund = {}
    end

    def create
      result = budget_client.create_fund(fund_params)
      if result["id"]
        redirect_to budget_fund_path(result["id"]), notice: "Fund created."
      else
        @fund = fund_params
        @errors = result["errors"] || [result["message"]]
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @fund = budget_client.fund(params[:id])
    end

    def update
      result = budget_client.update_fund(params[:id], fund_params)
      if result["id"]
        redirect_to budget_fund_path(result["id"]), notice: "Fund updated."
      else
        @fund = budget_client.fund(params[:id])
        @errors = result["errors"] || [result["message"]]
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      budget_client.delete_fund(params[:id])
      redirect_to budget_funds_path, notice: "Fund deleted."
    end

    def contribute
      result = budget_client.contribute_to_fund(params[:id], params[:amount].to_f, note: params[:note])
      if result["error"]
        redirect_to budget_fund_path(params[:id]), alert: "Contribution failed."
      else
        redirect_to budget_fund_path(params[:id]), notice: "Contribution recorded."
      end
    end

    private

    def fund_params
      params.require(:fund).permit(:name, :target_amount, :target_date, :notes).to_h.compact_blank
    end
  end
end

module Budget
  class DebtAccountsController < ApplicationController
    before_action :require_budget_connection

    def index
      sort = params[:sort] || "snowball"
      threads = {}
      threads[:accounts] = Thread.new { budget_client.debt_accounts(sort: sort) }
      threads[:overview] = Thread.new { budget_client.debt_overview }
      threads[:snowball] = Thread.new { budget_client.snowball_plan(extra: params[:extra].to_f) }

      @accounts = threads[:accounts].value
      @overview = threads[:overview].value
      @plan = threads[:snowball].value
    end

    def show
      @account = budget_client.debt_account(params[:id])
    end

    def new
      @account = {}
    end

    def create
      result = budget_client.create_debt_account(account_params)
      if result["id"]
        redirect_to budget_debt_account_path(result["id"]), notice: "Debt account added."
      else
        @account = account_params
        @errors = result["errors"] || [result["message"]]
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @account = budget_client.debt_account(params[:id])
    end

    def update
      result = budget_client.update_debt_account(params[:id], account_params)
      if result["id"]
        redirect_to budget_debt_account_path(result["id"]), notice: "Account updated."
      else
        @account = budget_client.debt_account(params[:id])
        @errors = result["errors"] || [result["message"]]
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      budget_client.delete_debt_account(params[:id])
      redirect_to budget_debt_accounts_path, notice: "Account deleted."
    end

    def pay
      result = budget_client.pay_debt(params[:id], params[:amount].to_f,
        note: params[:note], payment_type: params[:payment_type] || "regular")
      if result["error"]
        redirect_to budget_debt_account_path(params[:id]), alert: "Payment failed."
      else
        redirect_to budget_debt_account_path(params[:id]), notice: "Payment recorded."
      end
    end

    def snowball
      threads = {}
      threads[:plan] = Thread.new { budget_client.snowball_plan(extra: params[:extra].to_f) }
      threads[:accounts] = Thread.new { budget_client.debt_accounts(sort: "snowball") }
      threads[:overview] = Thread.new { budget_client.debt_overview }
      @plan = threads[:plan].value
      @accounts = threads[:accounts].value
      @overview = threads[:overview].value
      @extra = params[:extra].to_f
    end

    def avalanche
      threads = {}
      threads[:plan] = Thread.new { budget_client.avalanche_plan(extra: params[:extra].to_f) }
      threads[:accounts] = Thread.new { budget_client.debt_accounts(sort: "avalanche") }
      threads[:overview] = Thread.new { budget_client.debt_overview }
      @plan = threads[:plan].value
      @accounts = threads[:accounts].value
      @overview = threads[:overview].value
      @extra = params[:extra].to_f
    end

    def compare_plans
      @extra = params[:extra].to_f
      threads = {}
      threads[:snowball] = Thread.new { budget_client.snowball_plan(extra: @extra) }
      threads[:avalanche] = Thread.new { budget_client.avalanche_plan(extra: @extra) }
      threads[:overview] = Thread.new { budget_client.debt_overview }
      threads[:accounts] = Thread.new { budget_client.debt_accounts }

      @snowball = threads[:snowball].value
      @avalanche = threads[:avalanche].value
      @overview = threads[:overview].value
      @accounts = threads[:accounts].value
    end

    private

    def account_params
      params.require(:debt_account).permit(
        :name, :balance, :minimum_payment, :interest_rate, :debt_type, :due_date
      ).to_h.compact_blank
    end
  end
end

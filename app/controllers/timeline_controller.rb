class TimelineController < ApplicationController
  def index
    @filter = params[:filter].presence || "all"
    threads = {}

    if api_token.present? && @filter.in?(%w[all trades journal])
      threads[:trades] = Thread.new {
        result = api_client.trades(per_page: 30, status: "closed")
        trades = result.is_a?(Hash) ? (result["trades"] || []) : (result || [])
        trades.map { |t|
          {
            type: "trade",
            title: "#{t["side"]&.capitalize} #{t["symbol"]}",
            subtitle: "#{t["quantity"]} shares @ #{number_to_currency_val(t["entry_price"])}",
            value: t["pnl"].to_f,
            value_label: number_to_currency_val(t["pnl"]),
            timestamp: t["exit_time"] || t["entry_time"],
            icon: t["pnl"].to_f >= 0 ? "trending_up" : "trending_down",
            color: t["pnl"].to_f >= 0 ? "var(--positive)" : "var(--negative)",
            url: "/trades/#{t["id"]}",
            tags: (t["tags"] || []).map { |tag| tag["name"] },
            meta: t["setup"]
          }
        }
      }

      threads[:journal] = Thread.new {
        result = api_client.journal_entries(per_page: 20)
        entries = result.is_a?(Hash) ? (result["journal_entries"] || []) : (result || [])
        entries.map { |e|
          {
            type: "journal",
            title: "Journal Entry",
            subtitle: e["content"].to_s.truncate(120),
            timestamp: e["date"] || e["created_at"],
            icon: "edit_note",
            color: "var(--primary)",
            url: "/journal_entries/#{e["id"]}",
            meta: e["mood"]
          }
        }
      }
    end

    if notes_api_token.present? && @filter.in?(%w[all notes])
      threads[:notes] = Thread.new {
        result = notes_client.notes(per_page: 20)
        notes = result.is_a?(Hash) ? (result["notes"] || []) : (result || [])
        notes.map { |n|
          notebook = n.dig("notebook", "name") || n["notebook_name"]
          {
            type: "note",
            title: n["title"] || "Untitled",
            subtitle: notebook ? "in #{notebook}" : nil,
            timestamp: n["updated_at"] || n["created_at"],
            icon: n["pinned"] ? "push_pin" : (n["favorited"] ? "star" : "description"),
            color: n["color"].present? ? n["color"] : "#5c6bc0",
            url: "/notes/#{n["id"]}",
            tags: (n["tags"] || []).map { |t| t["name"] },
            meta: "#{n["word_count"]} words"
          }
        }
      }
    end

    if budget_api_token.present? && @filter.in?(%w[all budget])
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 20)
        txns = result.is_a?(Hash) ? (result["transactions"] || []) : (result || [])
        txns.map { |t|
          {
            type: "transaction",
            title: t["description"] || t["merchant"] || "Transaction",
            subtitle: t["merchant"],
            value: t["amount"].to_f,
            value_label: number_to_currency_val(t["amount"]),
            timestamp: t["date"] || t["created_at"],
            icon: t["amount"].to_f >= 0 ? "savings" : "shopping_cart",
            color: t["amount"].to_f >= 0 ? "var(--positive)" : "#f9ab00",
            url: "/budget/transactions",
            meta: t["category_name"]
          }
        }
      }
    end

    # Collect all items
    @items = []
    threads.each do |_, thread|
      begin
        @items.concat(thread.value || [])
      rescue
        # Skip failed API calls
      end
    end

    # Sort by timestamp descending
    @items.sort_by! { |i| i[:timestamp].to_s }.reverse!

    # Group by date
    @grouped = @items.group_by { |i| i[:timestamp].to_s.slice(0, 10) }

    # Summary stats
    @trade_count = @items.count { |i| i[:type] == "trade" }
    @note_count = @items.count { |i| i[:type] == "note" }
    @journal_count = @items.count { |i| i[:type] == "journal" }
    @txn_count = @items.count { |i| i[:type] == "transaction" }
    @trade_pnl = @items.select { |i| i[:type] == "trade" }.sum { |i| i[:value].to_f }
  end

  private

  def number_to_currency_val(val)
    return "$0.00" if val.nil?
    v = val.to_f
    sign = v < 0 ? "-" : ""
    "#{sign}$#{'%.2f' % v.abs}"
  end
end

class TradeTemplatesController < ApplicationController
  include ApiConnected

  def show
    trades_thread = Thread.new do
      fetch_recent_trades
    rescue => e
      Rails.logger.error("trade_templates trades: #{e.message}")
      []
    end

    playbooks_thread = Thread.new do
      result = api_client.playbooks
      result.is_a?(Hash) ? (result["playbooks"] || result["data"] || []) : Array(result)
    rescue => e
      Rails.logger.error("trade_templates playbooks: #{e.message}")
      []
    end

    trades = trades_thread.value || []
    @playbooks = playbooks_thread.value || []
    @suggested_templates = build_suggested_templates(trades, @playbooks)
  end

  private

  def fetch_recent_trades
    all = []
    page = 1
    loop do
      result = api_client.trades(page: page, per_page: 100)
      batch = result.is_a?(Hash) ? (result["trades"] || result["data"] || []) : Array(result)
      break if batch.empty?
      all.concat(batch)
      break if all.length >= 100 || batch.length < 100
      page += 1
    end
    all.first(100)
  end

  def build_suggested_templates(trades, playbooks)
    return [] if trades.empty?

    templates = []

    # 1. Most traded symbol template
    symbol_groups = trades.group_by { |t| t["symbol"] }.sort_by { |_, v| -v.length }
    if symbol_groups.any?
      top_symbol, top_trades = symbol_groups.first
      sides = top_trades.group_by { |t| (t["side"] || "long").downcase }
      common_side = sides.max_by { |_, v| v.length }&.first || "long"
      quantities = top_trades.map { |t| t["quantity"].to_f }.select(&:positive?)
      avg_qty = quantities.any? ? (quantities.sum / quantities.length).round(0).to_i : 100
      avg_entry = top_trades.map { |t| t["entry_price"].to_f }.select(&:positive?)
      avg_price = avg_entry.any? ? (avg_entry.sum / avg_entry.length).round(2) : nil
      asset_class = top_trades.first["asset_class"] || "Equity"
      win_count = top_trades.count { |t| t["pnl"].to_f > 0 }
      win_rate = top_trades.length > 0 ? (win_count.to_f / top_trades.length * 100).round(0) : 0

      templates << {
        name: "#{top_symbol} #{common_side.capitalize} (Most Traded)",
        symbol: top_symbol,
        side: common_side,
        quantity: avg_qty,
        asset_class: asset_class,
        playbook_id: nil,
        notes: "Based on #{top_trades.length} trades (#{win_rate}% win rate)#{avg_price ? ", avg entry $#{avg_price}" : ""}",
        risk_amount: nil,
        source: "suggested",
        trade_count: top_trades.length,
        win_rate: win_rate
      }
    end

    # 2. Second most traded symbol (if different enough)
    if symbol_groups.length >= 2
      second_symbol, second_trades = symbol_groups[1]
      sides = second_trades.group_by { |t| (t["side"] || "long").downcase }
      common_side = sides.max_by { |_, v| v.length }&.first || "long"
      quantities = second_trades.map { |t| t["quantity"].to_f }.select(&:positive?)
      avg_qty = quantities.any? ? (quantities.sum / quantities.length).round(0).to_i : 100
      asset_class = second_trades.first["asset_class"] || "Equity"
      win_count = second_trades.count { |t| t["pnl"].to_f > 0 }
      win_rate = second_trades.length > 0 ? (win_count.to_f / second_trades.length * 100).round(0) : 0

      templates << {
        name: "#{second_symbol} #{common_side.capitalize} (Frequent)",
        symbol: second_symbol,
        side: common_side,
        quantity: avg_qty,
        asset_class: asset_class,
        playbook_id: nil,
        notes: "Based on #{second_trades.length} trades (#{win_rate}% win rate)",
        risk_amount: nil,
        source: "suggested",
        trade_count: second_trades.length,
        win_rate: win_rate
      }
    end

    # 3. Best win-rate setup (min 3 trades)
    symbol_groups.each do |sym, sym_trades|
      next if sym_trades.length < 3
      win_count = sym_trades.count { |t| t["pnl"].to_f > 0 }
      win_rate = (win_count.to_f / sym_trades.length * 100).round(0)
      next if win_rate < 60
      next if templates.any? { |t| t[:symbol] == sym }

      sides = sym_trades.group_by { |t| (t["side"] || "long").downcase }
      common_side = sides.max_by { |_, v| v.length }&.first || "long"
      quantities = sym_trades.map { |t| t["quantity"].to_f }.select(&:positive?)
      avg_qty = quantities.any? ? (quantities.sum / quantities.length).round(0).to_i : 100
      asset_class = sym_trades.first["asset_class"] || "Equity"

      templates << {
        name: "#{sym} #{common_side.capitalize} (Best Win Rate)",
        symbol: sym,
        side: common_side,
        quantity: avg_qty,
        asset_class: asset_class,
        playbook_id: nil,
        notes: "#{win_rate}% win rate across #{sym_trades.length} trades",
        risk_amount: nil,
        source: "suggested",
        trade_count: sym_trades.length,
        win_rate: win_rate
      }
      break
    end

    # 4. Most used playbook template
    playbook_trades = trades.select { |t| t["playbook_id"].present? }
    if playbook_trades.any?
      pb_groups = playbook_trades.group_by { |t| t["playbook_id"] }
      top_pb_id, pb_trades = pb_groups.max_by { |_, v| v.length }
      playbook = playbooks.find { |p| p["id"].to_s == top_pb_id.to_s }
      pb_name = playbook ? playbook["name"] : "Playbook ##{top_pb_id}"

      top_sym = pb_trades.group_by { |t| t["symbol"] }.max_by { |_, v| v.length }&.first || pb_trades.first["symbol"]
      sides = pb_trades.group_by { |t| (t["side"] || "long").downcase }
      common_side = sides.max_by { |_, v| v.length }&.first || "long"
      quantities = pb_trades.map { |t| t["quantity"].to_f }.select(&:positive?)
      avg_qty = quantities.any? ? (quantities.sum / quantities.length).round(0).to_i : 100
      asset_class = pb_trades.first["asset_class"] || "Equity"
      win_count = pb_trades.count { |t| t["pnl"].to_f > 0 }
      win_rate = pb_trades.length > 0 ? (win_count.to_f / pb_trades.length * 100).round(0) : 0

      templates << {
        name: "#{pb_name} Setup",
        symbol: top_sym,
        side: common_side,
        quantity: avg_qty,
        asset_class: asset_class,
        playbook_id: top_pb_id.to_i,
        notes: "#{pb_name} playbook - #{pb_trades.length} trades (#{win_rate}% win rate)",
        risk_amount: nil,
        source: "suggested",
        trade_count: pb_trades.length,
        win_rate: win_rate
      }
    end

    # 5. Common side pattern (e.g., if user predominantly goes long or short)
    side_groups = trades.group_by { |t| (t["side"] || "long").downcase }
    dominant_side = side_groups.max_by { |_, v| v.length }
    if dominant_side
      side_name, side_trades = dominant_side
      pct = (side_trades.length.to_f / trades.length * 100).round(0)
      if pct >= 65 && templates.length < 5
        # Find best symbol for this side
        side_sym_groups = side_trades.group_by { |t| t["symbol"] }.sort_by { |_, v| -v.length }
        best_sym = nil
        side_sym_groups.each do |sym, st|
          next if templates.any? { |t| t[:symbol] == sym && t[:side] == side_name }
          best_sym = [sym, st]
          break
        end

        if best_sym
          sym, st = best_sym
          quantities = st.map { |t| t["quantity"].to_f }.select(&:positive?)
          avg_qty = quantities.any? ? (quantities.sum / quantities.length).round(0).to_i : 100
          asset_class = st.first["asset_class"] || "Equity"

          templates << {
            name: "#{sym} #{side_name.capitalize} (#{pct}% of trades are #{side_name})",
            symbol: sym,
            side: side_name,
            quantity: avg_qty,
            asset_class: asset_class,
            playbook_id: nil,
            notes: "You go #{side_name} #{pct}% of the time. #{sym} is a top pick for this side.",
            risk_amount: nil,
            source: "suggested",
            trade_count: st.length,
            win_rate: nil
          }
        end
      end
    end

    templates.first(5)
  end
end

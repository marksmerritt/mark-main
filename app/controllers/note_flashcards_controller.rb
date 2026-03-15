class NoteFlashcardsController < ApplicationController
  before_action :require_notes_connection

  def show
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(per_page: 500) }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    notes_result = threads[:notes].value
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }

    notebooks_result = threads[:notebooks].value
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Build notebook lookup
    notebook_lookup = {}
    @notebooks.each { |nb| notebook_lookup[nb["id"].to_s] = nb["name"] || "Untitled Notebook" }

    # Generate flashcards
    @flashcards = []
    card_id = 0

    @notes.each do |note|
      title = (note["title"] || "").strip
      content = note["content"] || note["body"] || ""
      notebook_id = note["notebook_id"].to_s
      deck_name = notebook_lookup[notebook_id] || "General"
      tags = (note["tags"] || []).map { |t| t.is_a?(Hash) ? (t["name"] || "") : t.to_s }.reject(&:blank?)

      next if title.blank? && content.blank?

      # Card type 1: Title -> Content
      if title.present? && content.present?
        card_id += 1
        answer = content.gsub(/[\r\n]+/, " ").strip
        answer = answer.length > 200 ? answer[0..199] + "..." : answer
        @flashcards << {
          id: card_id,
          front: title,
          back: answer,
          deck: deck_name,
          tags: tags,
          type: "title_content",
          difficulty_estimate: estimate_difficulty(content)
        }
      end

      # Card type 2: Key terms extraction (bold **word** or CAPS WORDS)
      bold_terms = content.scan(/\*\*([^*]+)\*\*/).flatten.map(&:strip).reject(&:blank?).uniq
      caps_terms = content.scan(/\b([A-Z][A-Z0-9]{2,})\b/).flatten.uniq

      key_terms = (bold_terms + caps_terms).uniq.first(5)
      key_terms.each do |term|
        # Extract surrounding context as definition
        pattern = Regexp.escape(term)
        match = content.match(/(?:^|[\.\!\?]\s*)([^\.!\?]*#{pattern}[^\.!\?]*[\.\!\?]?)/i)
        definition = match ? match[1].strip : content[0..150].strip
        next if definition.blank?

        card_id += 1
        @flashcards << {
          id: card_id,
          front: "Define: #{term}",
          back: definition.length > 200 ? definition[0..199] + "..." : definition,
          deck: deck_name,
          tags: tags + ["key-term"],
          type: "key_term",
          difficulty_estimate: "medium"
        }
      end

      # Card type 3: Summary cards for long notes (> 300 words)
      word_count = content.split(/\s+/).reject(&:blank?).count
      if word_count > 300 && title.present?
        card_id += 1
        # Pull first and last sentences as summary hint
        sentences = content.split(/[\.\!\?]+/).map(&:strip).reject(&:blank?)
        summary_hint = if sentences.length >= 3
          "#{sentences[0]}. ... #{sentences[-1]}."
        else
          content[0..200] + "..."
        end
        @flashcards << {
          id: card_id,
          front: "What are the key points of \"#{title}\"?",
          back: summary_hint.length > 300 ? summary_hint[0..299] + "..." : summary_hint,
          deck: deck_name,
          tags: tags + ["summary"],
          type: "summary",
          difficulty_estimate: "hard"
        }
      end
    end

    # Build tag-based grouping info
    @tag_groups = {}
    @flashcards.each do |card|
      card[:tags].each do |tag|
        next if tag == "key-term" || tag == "summary"
        @tag_groups[tag] ||= []
        @tag_groups[tag] << card[:id]
      end
    end
    @tag_groups = @tag_groups.sort_by { |_, ids| -ids.length }.to_h

    # Build deck stats
    @deck_stats = {}
    @flashcards.each do |card|
      @deck_stats[card[:deck]] ||= 0
      @deck_stats[card[:deck]] += 1
    end
    @deck_stats = @deck_stats.sort_by { |_, count| -count }.to_h

    # Compute stats
    @total_cards = @flashcards.count
    @total_decks = @deck_stats.keys.count
    @estimated_time = (@total_cards * 30.0 / 60).ceil # minutes
    @cards_from_tags = @flashcards.count { |c| c[:tags].any? { |t| t != "key-term" && t != "summary" } }
  end

  private

  def estimate_difficulty(content)
    word_count = content.split(/\s+/).reject(&:blank?).count
    if word_count < 50
      "easy"
    elsif word_count < 200
      "medium"
    else
      "hard"
    end
  end
end

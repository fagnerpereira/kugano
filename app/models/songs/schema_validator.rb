module Songs
  class SchemaValidator
    Result = Struct.new(:valid?, :errors, keyword_init: true)

    NOTE_REGEX = /\A[A-G]#?[0-8]\z/
    SLUG_REGEX = /\A[a-z0-9-]+\z/
    TIME_SIG_REGEX = /\A\d+\/\d+\z/
    SOURCE_TYPES = %w[native musicxml midi pdf_omr audio_youtube].freeze
    LEVEL_KEYS = %w[easy medium original faithful].freeze

    def self.validate(payload)
      new(payload).validate
    end

    def initialize(payload)
      @data = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
      @errors = []
    end

    def validate
      validate_top_level
      validate_meta if @data["meta"].is_a?(Hash)
      validate_sections if @data["sections"].is_a?(Array) && @data["sections"].any?
      validate_steps if @data["steps"].is_a?(Array) && @data["steps"].any?

      Result.new(valid?: @errors.empty?, errors: @errors)
    end

    private

    def validate_top_level
      @errors << "schemaVersion deve ser '1.0'" unless @data["schemaVersion"] == "1.0"
      @errors << "slug ausente ou inválido" unless @data["slug"].is_a?(String) && @data["slug"].match?(SLUG_REGEX)
      @errors << "meta ausente" unless @data["meta"].is_a?(Hash)
      @errors << "sections deve conter ao menos 1 seção" unless @data["sections"].is_a?(Array) && @data["sections"].any?
      @errors << "steps deve conter ao menos 1 compasso" unless @data["steps"].is_a?(Array) && @data["steps"].any?
    end

    def validate_meta
      meta = @data["meta"]
      @errors << "meta.title ausente" if meta["title"].to_s.strip.empty?
      @errors << "meta.info ausente" if meta["info"].to_s.strip.empty?
      @errors << "meta.key ausente" if meta["key"].to_s.strip.empty?

      bpm = meta["defaultBpm"]
      @errors << "meta.defaultBpm deve estar entre 30 e 240" unless bpm.is_a?(Integer) && bpm.between?(30, 240)

      presets = meta["presets"]
      unless presets.is_a?(Array) && presets.any? && presets.all? { |p| p.is_a?(Integer) && p.between?(30, 240) }
        @errors << "meta.presets inválido"
      end

      unless meta["timeSignature"].is_a?(String) && meta["timeSignature"].match?(TIME_SIG_REGEX)
        @errors << "meta.timeSignature inválido"
      end

      ticks = meta["ticksPerMeasure"]
      @errors << "meta.ticksPerMeasure deve estar entre 4 e 32" unless ticks.is_a?(Integer) && ticks.between?(4, 32)

      unless SOURCE_TYPES.include?(meta["sourceType"])
        @errors << "meta.sourceType inválido (#{meta['sourceType']})"
      end
    end

    def validate_sections
      @data["sections"].each_with_index do |sec, idx|
        unless sec.is_a?(Hash) && sec["id"].is_a?(Integer) && sec["id"] >= 1 && !sec["name"].to_s.strip.empty?
          @errors << "sections[#{idx}] inválida"
        end
      end
    end

    def validate_steps
      ticks_limit = (@data.dig("meta", "ticksPerMeasure") || 16).to_i
      section_ids = (@data["sections"] || []).filter_map { |s| s["id"] if s.is_a?(Hash) }

      @data["steps"].each_with_index do |step, idx|
        unless step.is_a?(Hash)
          @errors << "steps[#{idx}] deve ser um objeto"
          next
        end

        @errors << "steps[#{idx}].id inválido" unless step["id"].is_a?(Integer) && step["id"] >= 1
        @errors << "steps[#{idx}].tag ausente" if step["tag"].to_s.strip.empty?
        unless section_ids.include?(step["sectionId"])
          @errors << "steps[#{idx}].sectionId (#{step['sectionId']}) não existe em sections"
        end
        @errors << "steps[#{idx}].title ausente" if step["title"].to_s.strip.empty?
        @errors << "steps[#{idx}].lyric deve ser string" unless step["lyric"].is_a?(String)

        validate_voice(step["voice"], idx, ticks_limit)
        validate_levels(step["levels"], idx, ticks_limit)
      end
    end

    def validate_voice(voice, step_idx, ticks_limit)
      unless voice.is_a?(Array)
        @errors << "steps[#{step_idx}].voice deve ser array"
        return
      end

      voice.each_with_index do |ev, v_idx|
        unless ev.is_a?(Hash)
          @errors << "steps[#{step_idx}].voice[#{v_idx}] inválido"
          next
        end
        unless ev["tick"].is_a?(Integer) && ev["tick"].between?(0, ticks_limit - 1)
          @errors << "steps[#{step_idx}].voice[#{v_idx}].tick fora do compasso"
        end
        unless ev["dur"].is_a?(Integer) && ev["dur"].between?(1, ticks_limit)
          @errors << "steps[#{step_idx}].voice[#{v_idx}].dur inválido"
        end
        unless ev["note"].is_a?(String) && ev["note"].match?(NOTE_REGEX)
          @errors << "steps[#{step_idx}].voice[#{v_idx}].note inválida (#{ev['note']})"
        end
      end
    end

    def validate_levels(levels, step_idx, ticks_limit)
      unless levels.is_a?(Hash)
        @errors << "steps[#{step_idx}].levels ausente"
        return
      end

      LEVEL_KEYS.each do |lvl_key|
        lvl = levels[lvl_key]
        unless lvl.is_a?(Hash)
          @errors << "steps[#{step_idx}].levels.#{lvl_key} ausente"
          next
        end

        @errors << "steps[#{step_idx}].levels.#{lvl_key}.chord ausente" if lvl["chord"].to_s.strip.empty?
        @errors << "steps[#{step_idx}].levels.#{lvl_key}.pedal deve ser booleano" unless [ true, false ].include?(lvl["pedal"])
        @errors << "steps[#{step_idx}].levels.#{lvl_key}.tip ausente" if lvl["tip"].to_s.strip.empty?

        validate_hand_events(lvl["lh"], "steps[#{step_idx}].levels.#{lvl_key}.lh", ticks_limit)
        validate_hand_events(lvl["rh"], "steps[#{step_idx}].levels.#{lvl_key}.rh", ticks_limit)
      end
    end

    def validate_hand_events(events, path, ticks_limit)
      unless events.is_a?(Array)
        @errors << "#{path} deve ser array"
        return
      end

      events.each_with_index do |ev, e_idx|
        unless ev.is_a?(Hash)
          @errors << "#{path}[#{e_idx}] inválido"
          next
        end

        unless ev["tick"].is_a?(Integer) && ev["tick"].between?(0, ticks_limit - 1)
          @errors << "#{path}[#{e_idx}].tick fora do intervalo"
        end
        unless ev["dur"].is_a?(Integer) && ev["dur"].between?(1, ticks_limit)
          @errors << "#{path}[#{e_idx}].dur fora do intervalo"
        end

        notes = ev["notes"]
        fingers = ev["fingers"]

        unless notes.is_a?(Array) && notes.any?
          @errors << "#{path}[#{e_idx}].notes deve conter ao menos 1 nota"
          next
        end

        notes.each do |note|
          unless note.is_a?(String) && note.match?(NOTE_REGEX)
            @errors << "#{path}[#{e_idx}].notes contém cifra inválida: #{note}"
          end
        end

        unless fingers.is_a?(Array) && fingers.length == notes.length
          @errors << "#{path}[#{e_idx}].fingers: quantidade de dedos deve coincidir com notes"
          next
        end

        fingers.each do |finger|
          unless finger.is_a?(Integer) && finger.between?(1, 5)
            @errors << "#{path}[#{e_idx}].fingers contém dedilhado fora de 1..5 (#{finger})"
          end
        end
      end
    end
  end
end

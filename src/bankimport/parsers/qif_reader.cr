# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Parsers
    # Lecture d'un relevé QIF (D-BKI-002) : sections `!Type:Bank`,
    # `!Type:CCard`, `!Type:Cash` ou `!Type:Oth A` ; une opération par bloc
    # terminé par `^` — date `D` (ordre selon le format choisi, le QIF ne le
    # dit pas), montant `T` ou `U`, bénéficiaire `P`, mémo `M`, numéro `N`,
    # catégorie `L` (gardée en information). Les ventilations (`S`, `E`,
    # `$`) sont ignorées : le montant total suffit. Les sections de
    # placements (`!Type:Invst`) et de listes (`!Account`, `!Type:Cat`…)
    # sont sautées.
    module QifReader
      BANK_TYPES = ["bank", "ccard", "cash", "oth a", "oth l"]

      def self.qif?(text : String) : Bool
        text.lstrip.starts_with?('!')
      end

      def self.parse(bytes : Bytes, date_format : String) : Parsed
        parsed = Parsed.new
        text = Text.guess(bytes)
        unless qif?(text)
          parsed.issue(0, "file.not_qif")
          return parsed
        end
        records(text).each { |(position, record)| read(parsed, record, position, date_format) }
        parsed.issue(0, "file.empty") if parsed.lines.empty? && parsed.issues.empty?
        parsed
      end

      # Blocs des sections de trésorerie, avec le rang de leur première
      # ligne : code (`D`, `T`…) et valeur ; la première valeur d'un code
      # de ventilation (`S`, `E`, `$`) est gardée.
      private def self.records(text : String) : Array({Int32, Hash(Char, String)})
        found = [] of {Int32, Hash(Char, String)}
        reading = false
        record = {} of Char => String
        start = 0
        text.each_line.with_index(1) do |raw, number|
          line = raw.rstrip
          next if line.empty?
          if line.starts_with?('!')
            reading = section?(line)
            record = {} of Char => String
          elsif !reading
            next
          elsif line.starts_with?('^')
            found << {start, record} unless record.empty?
            record = {} of Char => String
          else
            start = number if record.empty?
            code = line[0]
            record[code] = line[1..].strip unless record.has_key?(code) && code.in?('S', 'E', '$')
          end
        end
        found << {start, record} if reading && !record.empty?
        found
      end

      private def self.section?(line : String) : Bool
        header = line.downcase
        return false unless header.starts_with?("!type:")
        BANK_TYPES.includes?(header.lchop("!type:").strip)
      end

      private def self.read(parsed : Parsed, record : Hash(Char, String), position : Int32, date_format : String) : Nil
        date_text = record['D']? || ""
        date = Dates.parse(date_text, date_format)
        return parsed.issue(position, "line.date", {"value" => date_text}) if date.nil?
        amount_text = record['T']? || record['U']? || ""
        amount = Amounts.parse(amount_text)
        return parsed.issue(position, "line.amount", {"value" => amount_text}) if amount.nil?
        return parsed.issue(position, "line.zero") if amount.zero?
        payee = Parsers.clean(record['P']? || "")
        label, extra = texts(payee, record)
        return parsed.issue(position, "line.label") if label.empty?
        parsed.lines << ParsedLine.new(position, date, amount, label, extra: extra,
          reference: Parsers.clean(record['N']? || "", 64), counterparty: payee, payee: payee)
      end

      # Libellé (bénéficiaire, à défaut mémo) et information complémentaire
      # (mémo, catégorie).
      private def self.texts(payee : String, record : Hash(Char, String)) : {String, String}
        memo = Parsers.clean(record['M']? || "", 2000)
        label = payee.empty? ? memo[0, 255] : payee
        category = Parsers.clean(record['L']? || "").presence
        {label, [memo == label ? nil : memo.presence, category].compact.join(" · ")}
      end
    end
  end
end

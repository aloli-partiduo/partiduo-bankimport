# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Parsers
    # Réglages d'un format CSV (copie de `CsvFormat`, ou saisis pour un
    # essai) : rangs de colonnes à partir de 1.
    record CsvSettings,
      separator : String = "semicolon",
      encoding : String = "utf-8",
      skip_lines : Int32 = 1,
      date_format : String = "dd/mm/yyyy",
      decimal_separator : String = "comma",
      thousands_separator : String = "none",
      date_column : Int32 = 1,
      label_column : Int32 = 2,
      amount_column : Int32? = 3,
      debit_column : Int32? = nil,
      credit_column : Int32? = nil,
      extra_column : Int32? = nil,
      reference_column : Int32? = nil,
      counterparty_column : Int32? = nil,
      negate : Bool = false

    # Lecture d'un relevé CSV selon le format de l'établissement (D-BKI-002) :
    # lignes d'en-tête sautées, lignes vides ignorées ; montant signé, ou
    # crédit moins débit (valeurs absolues : une banque qui écrit le débit en
    # négatif est lue de même) ; `negate` inverse le signe. Une ligne de
    # montant nul (ligne d'information, solde) est ignorée et signalée.
    module CsvReader
      SEPARATORS = {"comma" => ',', "semicolon" => ';', "tab" => '\t', "pipe" => '|'}

      def self.parse(bytes : Bytes, settings : CsvSettings) : Parsed
        parsed = Parsed.new
        text = Text.decode(bytes, settings.encoding)
        rows = begin
          CSV.parse(text, separator: SEPARATORS[settings.separator]? || ';')
        rescue ex : CSV::MalformedCSVError
          parsed.issue(0, "file.malformed_csv", {"detail" => ex.message.to_s})
          return parsed
        end
        rows.each_with_index(1) do |cells, position|
          next if position <= settings.skip_lines
          next if cells.all?(&.strip.empty?)
          read_row(parsed, cells, position, settings)
        end
        parsed.issue(0, "file.empty") if parsed.lines.empty? && parsed.issues.empty?
        parsed
      end

      # Premières lignes découpées, pour régler un format sur un fichier
      # d'exemple.
      def self.sample(bytes : Bytes, separator : String, encoding : String, rows : Int32 = 8) : Array(Array(String))
        CSV.parse(Text.decode(bytes, encoding), separator: SEPARATORS[separator]? || ';').first(rows)
      rescue CSV::MalformedCSVError
        [] of Array(String)
      end

      private def self.read_row(parsed : Parsed, cells : Array(String), position : Int32, settings : CsvSettings) : Nil
        cell = ->(column : Int32?) { column.try { |index| cells[index - 1]?.try(&.strip) } || "" }
        date_text = cell.call(settings.date_column)
        date = Dates.parse(date_text, settings.date_format)
        return parsed.issue(position, "line.date", {"value" => date_text}) if date.nil?
        amount = read_amount(parsed, position, settings, cell) || return
        return parsed.issue(position, "line.zero") if amount.zero?

        label = Parsers.clean(cell.call(settings.label_column))
        extra = Parsers.clean(cell.call(settings.extra_column), 2000)
        label = extra[0, 255] if label.empty?
        return parsed.issue(position, "line.label") if label.empty?
        parsed.lines << ParsedLine.new(position, date, amount, label, extra: label == extra ? "" : extra,
          reference: Parsers.clean(cell.call(settings.reference_column), 64),
          counterparty: Parsers.clean(cell.call(settings.counterparty_column)))
      end

      # Montant signé de la ligne (`negate` appliqué), ou `nil` avec
      # l'anomalie notée.
      private def self.read_amount(parsed : Parsed, position : Int32, settings : CsvSettings,
                                   cell : Proc(Int32?, String)) : BigDecimal?
        decimal = Amounts::SEPARATORS[settings.decimal_separator]? || ','
        thousands = Amounts::THOUSANDS[settings.thousands_separator]?
        amount = if column = settings.amount_column
                   text = cell.call(column)
                   Amounts.parse(text, decimal, thousands) || return parsed.issue(position, "line.amount", {"value" => text})
                 else
                   debit_text, credit_text = cell.call(settings.debit_column), cell.call(settings.credit_column)
                   debit = debit_text.empty? ? BigDecimal.new(0) : Amounts.parse(debit_text, decimal, thousands)
                   credit = credit_text.empty? ? BigDecimal.new(0) : Amounts.parse(credit_text, decimal, thousands)
                   if debit.nil? || credit.nil?
                     return parsed.issue(position, "line.amount", {"value" => "#{debit_text} #{credit_text}".strip})
                   end
                   credit.abs - debit.abs
                 end
        settings.negate ? -amount : amount
      end
    end
  end
end

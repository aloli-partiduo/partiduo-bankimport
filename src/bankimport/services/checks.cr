# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Règles de saisie des formats, des règles de catégorisation et des
  # contreparties (interne). Les erreurs sont des `FieldError` aux clés
  # `bankimport.errors.*`.
  module Checks
    alias Api = Bankimport::Api
    alias FieldError = Partiduo::Api::FieldError

    COLUMNS = %w[date_column label_column amount_column debit_column credit_column extra_column reference_column
      counterparty_column]

    def self.format_errors(actor : Partiduo::Api::Actor, input : Api::FormatInput, id : Int64?) : Array(FieldError)
      errors = [] of FieldError
      format_name_errors(input, id, errors)
      choice(errors, "separator", input.separator, Api::SEPARATORS)
      choice(errors, "encoding", input.encoding, Api::ENCODINGS)
      choice(errors, "date_format", input.date_format, Api::DATE_FORMATS)
      choice(errors, "decimal_separator", input.decimal_separator, Api::DECIMAL_SEPARATORS)
      choice(errors, "thousands_separator", input.thousands_separator, Api::THOUSANDS_SEPARATORS)
      if input.thousands_separator == input.decimal_separator
        errors << Records.error("thousands_separator", "format.thousands_separator.same")
      end
      errors << Records.error("skip_lines", "format.skip_lines.range") unless (0..50).includes?(input.skip_lines)
      column_errors(input, errors)
      input.ledger_id.try { |ledger_id| Records.financial_ledger(actor, ledger_id, "ledger_id", errors) }
      errors
    end

    private def self.format_name_errors(input : Api::FormatInput, id : Int64?, errors : Array(FieldError)) : Nil
      name = input.name.strip
      if name.empty?
        errors << Records.error("name", "format.name.blank")
      elsif name.size > 100
        errors << Records.error("name", "format.name.too_long", {"max" => "100"})
      elsif CsvFormat.all.to_a.any? { |row| row.id != id && row.name.to_s.downcase == name.downcase }
        errors << Records.error("name", "format.name.taken")
      end
      errors << Records.error("institution", "format.institution.too_long", {"max" => "100"}) if input.institution.strip.size > 100
    end

    # Rangs dans les bornes, chacun une seule fois ; montant signé *ou*
    # débit et crédit.
    private def self.column_errors(input : Api::FormatInput, errors : Array(FieldError)) : Nil
      columns = {
        "date_column" => input.date_column, "label_column" => input.label_column, "amount_column" => input.amount_column,
        "debit_column" => input.debit_column, "credit_column" => input.credit_column, "extra_column" => input.extra_column,
        "reference_column" => input.reference_column, "counterparty_column" => input.counterparty_column,
      }
      columns.each do |field, value|
        next if value.nil? || (1..Api::MAX_COLUMN).includes?(value)
        errors << Records.error(field, "format.column.range", {"max" => Api::MAX_COLUMN.to_s})
      end
      if input.amount_column.nil? && (input.debit_column.nil? || input.credit_column.nil?)
        errors << Records.error("amount_column", "format.amount_column.blank")
      elsif input.amount_column && (input.debit_column || input.credit_column)
        errors << Records.error("amount_column", "format.amount_column.both")
      end
      used = columns.values.compact
      errors << Records.error(FieldError::BASE, "format.column.repeated") if used.size != used.uniq.size
    end

    def self.apply_format(row : CsvFormat, input : Api::FormatInput) : CsvFormat
      row.name = input.name.strip
      row.institution = input.institution.strip
      row.ledger_id = input.ledger_id
      row.separator = input.separator
      row.encoding = input.encoding
      row.skip_lines = input.skip_lines
      row.date_format = input.date_format
      row.decimal_separator = input.decimal_separator
      row.thousands_separator = input.thousands_separator
      row.date_column = input.date_column
      row.label_column = input.label_column
      row.amount_column = input.amount_column
      row.debit_column = input.debit_column
      row.credit_column = input.credit_column
      row.extra_column = input.extra_column
      row.reference_column = input.reference_column
      row.counterparty_column = input.counterparty_column
      row.negate = input.negate
      row
    end

    def self.rule_errors(actor : Partiduo::Api::Actor, input : Api::RuleInput) : Array(FieldError)
      errors = [] of FieldError
      text = input.label_contains.strip
      errors << Records.error("label_contains", "rule.label_contains.too_long", {"max" => "120"}) if text.size > 120
      if text.empty? && input.amount.nil?
        errors << Records.error("label_contains", "rule.condition.blank")
      end
      if amount = input.amount
        errors << Records.error("amount", "rule.amount.positive") unless amount > 0
      end
      choice(errors, "direction", input.direction, Api::DIRECTIONS)
      errors << Records.error("position", "rule.position.range") unless (0..999).includes?(input.position)
      counterpart_errors(actor, input.card_code, input.account, errors)
      input.ledger_id.try { |ledger_id| Records.financial_ledger(actor, ledger_id, "ledger_id", errors) }
      errors
    end

    def self.apply_rule(row : Rule, input : Api::RuleInput) : Rule
      row.label_contains = input.label_contains.strip
      row.amount = input.amount
      row.direction = input.direction
      row.card_code = Partiduo::Api::Cards.format_code(input.card_code.strip)
      row.account = input.account.strip
      row.ledger_id = input.ledger_id
      row.position = input.position
      row.active = input.active
      row
    end

    # Fiche *ou* compte, existant : la fiche par son quick code, le compte
    # par son numéro (utilisable en saisie).
    def self.counterpart_errors(actor : Partiduo::Api::Actor, card_code : String, account : String,
                                errors : Array(FieldError)) : Nil
      code = card_code.strip
      number = account.strip
      if code.empty? && number.empty?
        errors << Records.error("card_code", "counterpart.blank")
      elsif !code.empty? && !number.empty?
        errors << Records.error("card_code", "counterpart.both")
      elsif !code.empty?
        errors << Records.error("card_code", "counterpart.card_unknown", {"code" => code}) unless card?(actor, code)
      else
        account_errors(actor, number, errors)
      end
    end

    private def self.card?(actor : Partiduo::Api::Actor, code : String) : Bool
      !Partiduo::Api::Cards.card_by_code(actor, code).nil?
    end

    private def self.account_errors(actor : Partiduo::Api::Actor, number : String, errors : Array(FieldError)) : Nil
      account = Partiduo::Api::Accounting.account(actor, number)
      errors << Records.error("account", "counterpart.account_not_direct", {"number" => number}) unless account.direct_use
    rescue Partiduo::Api::NotFound
      errors << Records.error("account", "counterpart.account_unknown", {"number" => number})
    end

    private def self.choice(errors : Array(FieldError), field : String, value : String, allowed : Array(String)) : Nil
      errors << Records.error(field, "choice.invalid", {"value" => value}) unless allowed.includes?(value)
    end
  end
end

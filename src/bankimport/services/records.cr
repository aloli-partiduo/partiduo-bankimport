# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Lecture des lignes et construction des vues du contrat (interne).
  module Records
    alias Api = Bankimport::Api
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : FieldError
      FieldError.new(field, "bankimport.errors.#{key}", params)
    end

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    # --- Recherche ---------------------------------------------------------------

    def self.format!(id : Int64) : CsvFormat
      CsvFormat.filter(id: id).first || raise Partiduo::Api::NotFound.new("bankimport_format", id)
    end

    def self.rule!(id : Int64) : Rule
      Rule.filter(id: id).first || raise Partiduo::Api::NotFound.new("bankimport_rule", id)
    end

    # Import d'un journal visible de l'acteur ; `NotFound` sinon.
    def self.import!(actor : Partiduo::Api::Actor, id : Int64) : Import
      row = Import.filter(id: id).first
      raise Partiduo::Api::NotFound.new("bankimport_import", id) if row.nil? || !visible?(actor, row.ledger_id!.to_i64)
      row
    end

    def self.line!(actor : Partiduo::Api::Actor, id : Int64, lock : Bool = false) : Line
      query = Line.filter(id: id)
      query = query.lock if lock
      row = query.first
      raise Partiduo::Api::NotFound.new("bankimport_line", id) if row.nil? || !visible?(actor, row.ledger_id!.to_i64)
      row
    end

    # Journaux financiers visibles de l'acteur (droits par journal du socle,
    # ADR-011 D12) : la zone d'attente et l'historique n'en montrent pas
    # d'autres (D-BKI-004). L'acteur système les voit tous.
    def self.visible_ledgers(actor : Partiduo::Api::Actor) : Array(Acc::LedgerView)
      Acc.ledgers(actor, Acc::LedgerKind::Financial)
    rescue Partiduo::Api::AccessDenied
      [] of Acc::LedgerView
    end

    def self.visible_ledger_ids(actor : Partiduo::Api::Actor) : Array(Int64)
      visible_ledgers(actor).map(&.id)
    end

    def self.visible?(actor : Partiduo::Api::Actor, ledger_id : Int64) : Bool
      visible_ledger_ids(actor).includes?(ledger_id)
    end

    # Journal financier visible de l'acteur, ou erreur sur `field`.
    def self.financial_ledger(actor : Partiduo::Api::Actor, id : Int64?, field : String,
                              errors : Array(FieldError)) : Acc::LedgerView?
      if id.nil?
        errors << error(field, "ledger.blank")
        return
      end
      ledger = visible_ledgers(actor).find { |item| item.id == id }
      errors << error(field, "ledger.invalid") if ledger.nil?
      ledger
    end

    # --- Vues --------------------------------------------------------------------

    def self.format_view(row : CsvFormat) : Api::FormatView
      Api::FormatView.new(
        id: row.id!.to_i64, name: row.name.to_s, institution: row.institution.to_s, ledger_id: row.ledger_id.try(&.to_i64),
        separator: row.separator.to_s, encoding: row.encoding.to_s, skip_lines: row.skip_lines!.to_i32,
        date_format: row.date_format.to_s, decimal_separator: row.decimal_separator.to_s,
        thousands_separator: row.thousands_separator.to_s, date_column: row.date_column!.to_i32,
        label_column: row.label_column!.to_i32, amount_column: row.amount_column.try(&.to_i32),
        debit_column: row.debit_column.try(&.to_i32), credit_column: row.credit_column.try(&.to_i32),
        extra_column: row.extra_column.try(&.to_i32), reference_column: row.reference_column.try(&.to_i32),
        counterparty_column: row.counterparty_column.try(&.to_i32), negate: row.negate == true,
        import_count: Import.filter(format_id: row.id).count.to_i32, iban_column: row.iban_column.try(&.to_i32),
      )
    end

    def self.settings(row : CsvFormat) : Parsers::CsvSettings
      Parsers::CsvSettings.new(
        separator: row.separator.to_s, encoding: row.encoding.to_s, skip_lines: row.skip_lines!.to_i32,
        date_format: row.date_format.to_s, decimal_separator: row.decimal_separator.to_s,
        thousands_separator: row.thousands_separator.to_s, date_column: row.date_column!.to_i32,
        label_column: row.label_column!.to_i32, amount_column: row.amount_column.try(&.to_i32),
        debit_column: row.debit_column.try(&.to_i32), credit_column: row.credit_column.try(&.to_i32),
        extra_column: row.extra_column.try(&.to_i32), reference_column: row.reference_column.try(&.to_i32),
        counterparty_column: row.counterparty_column.try(&.to_i32), negate: row.negate == true,
        iban_column: row.iban_column.try(&.to_i32),
      )
    end

    def self.import_views(rows : Array(Import), ledgers : Hash(Int64, String)) : Array(Api::ImportView)
      return [] of Api::ImportView if rows.empty?
      ids = rows.map(&.id!.to_i64)
      lines = Line.filter(import_id__in: ids).to_a.group_by(&.import_id!.to_i64)
      formats = CsvFormat.filter(id__in: rows.compact_map(&.format_id)).to_a.to_h { |row| {row.id!.to_i64, row.name.to_s} }
      zero = BigDecimal.new(0)
      rows.map do |row|
        id = row.id!.to_i64
        own = lines[id]? || [] of Line
        kept = own.reject { |line| line.status == "duplicate" }
        dates = kept.map(&.date!)
        Api::ImportView.new(
          id: id, ledger_id: row.ledger_id!.to_i64, ledger_code: ledgers[row.ledger_id!.to_i64]? || "",
          kind: row.kind.to_s, format_id: row.format_id.try(&.to_i64),
          format_name: row.format_id.try { |format_id| formats[format_id.to_i64]? }, filename: row.filename.to_s,
          attachment_id: row.attachment_id.try(&.to_i64), account_number: row.account_number.to_s,
          currency_code: row.currency_code.to_s, start_balance: row.start_balance, end_balance: row.end_balance,
          statement_on: row.statement_on, line_count: row.line_count!.to_i32, duplicate_count: own.count(&.status.==("duplicate")),
          pending_count: own.count(&.status.==("pending")), transferred_count: own.count(&.status.==("transferred")),
          discarded_count: own.count(&.status.==("discarded")), first_date: dates.min?, last_date: dates.max?,
          total_in: kept.map(&.amount!).select(&.>(zero)).sum(zero),
          total_out: kept.map(&.amount!).select(&.<(zero)).sum(zero).abs,
          statement_id: row.statement_id.try(&.to_i64), statement_reference: row.statement_reference.to_s,
          created_by_id: row.created_by_id.try(&.to_i64), created_at: row.created_at || Time.utc,
        )
      end
    end

    # Vues des lignes ; noms des fiches et libellés des comptes relus par le
    # contrat du cœur, une fois chacun, si l'acteur peut les lire.
    def self.line_views(actor : Partiduo::Api::Actor, rows : Array(Line)) : Array(Api::LineView)
      cards = {} of String => String?
      accounts = {} of String => String?
      rows.map do |row|
        code = row.card_code.to_s
        number = row.account.to_s
        Api::LineView.new(
          id: row.id!.to_i64, import_id: row.import_id!.to_i64, ledger_id: row.ledger_id!.to_i64,
          position: row.position!.to_i32, date: row.date!, amount: row.amount!, label: row.label.to_s,
          extra: row.extra.to_s, reference: row.reference.to_s, fitid: row.fitid.to_s,
          counterparty: row.counterparty.to_s, status: row.status.to_s, card_code: code,
          card_name: code.empty? ? nil : cards.put_if_absent(code) { card_name(actor, code) },
          account: number,
          account_label: number.empty? ? nil : accounts.put_if_absent(number) { account_label(actor, number) },
          rule_id: row.rule_id.try(&.to_i64), match_line_id: row.match_line_id.try(&.to_i64),
          duplicate_of_id: row.duplicate_of_id.try(&.to_i64), recorded_entry_id: row.recorded_entry_id.try(&.to_i64),
          entry_id: row.entry_id.try(&.to_i64), reversed_entry_id: row.reversed_entry_id.try(&.to_i64),
          error: stored_error(row), payee: row.payee.to_s, iban: row.iban.to_s,
        )
      end
    end

    def self.line_view(actor : Partiduo::Api::Actor, row : Line) : Api::LineView
      line_views(actor, [row]).first
    end

    def self.rule_view(row : Rule) : Api::RuleView
      Api::RuleView.new(
        id: row.id!.to_i64, ledger_id: row.ledger_id.try(&.to_i64), label_contains: row.label_contains.to_s,
        amount: row.amount, direction: row.direction.to_s, card_code: row.card_code.to_s, account: row.account.to_s,
        position: row.position!.to_i32, active: row.active == true, learned: row.learned == true,
        hits: row.hits!.to_i32, last_used_at: row.last_used_at, payee: row.payee.to_s,
      )
    end

    # Erreur du dernier transfert, gardée sur la ligne (clé et paramètres).
    def self.stored_error(row : Line) : FieldError?
      key = row.error_key.to_s
      return if key.empty?
      params = begin
        Hash(String, String).from_json(row.error_params.to_s.presence || "{}")
      rescue JSON::ParseException
        {} of String => String
      end
      FieldError.new("base", key, params)
    end

    def self.store_error(row : Line, error : FieldError?) : Nil
      row.error_key = error.try(&.key) || ""
      row.error_params = error.try(&.params.to_json) || ""
    end

    def self.card_name(actor : Partiduo::Api::Actor, code : String) : String?
      Partiduo::Api::Cards.card_by_code(actor, code).try(&.name)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    def self.account_label(actor : Partiduo::Api::Actor, number : String) : String?
      Acc.account(actor, number).label
    rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
      nil
    end
  end
end

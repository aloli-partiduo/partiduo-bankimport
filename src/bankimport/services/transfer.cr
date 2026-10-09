# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Transfert des lignes vers le journal financier (D-BKI-008) : une
  # écriture par ligne, par `Partiduo::Api::Accounting.post_financial`, le
  # seul service d'écriture du cœur (ADR-003 D6) — jamais de table comptable
  # propre. La ligne garde son écriture ; un refus reste sur la ligne, à
  # corriger, sans empêcher les autres. Interne.
  module Transfer
    alias Acc = Partiduo::Api::Accounting

    # Référence de l'écriture (`source`) : la ligne qui l'a produite.
    SOURCE = "bankimport:line:"

    def self.run(actor : Partiduo::Api::Actor, rows : Array(Line)) : {Array(Line), Array(Line)}
      done = [] of Line
      failed = [] of Line
      attachments = {} of Int64 => Int64?
      rows.each do |row|
        if row.status != "pending"
          next
        elsif row.card_code.to_s.empty? && row.account.to_s.empty?
          Records.store_error(row, Records.error("card_code", "counterpart.blank"))
          row.save!
          failed << row
          next
        end
        import_id = row.import_id!.to_i64
        attachment_id = attachments.put_if_absent(import_id) { Import.filter(id: import_id).first.try(&.attachment_id.try(&.to_i64)) }
        error = post(actor, row, attachment_id)
        if error
          Records.store_error(row, error)
          row.save!
          failed << row
        else
          done << row
        end
      end
      {done, failed}
    end

    # Passe l'écriture d'une ligne ; rend l'erreur, ou `nil`.
    private def self.post(actor : Partiduo::Api::Actor, row : Line, attachment_id : Int64?) : Partiduo::Api::FieldError?
      line = Acc::PaymentLineInput.new(row.amount!, card: row.card_code.to_s.presence, account: row.account.to_s.presence,
        label: row.label.to_s, match_line_ids: row.match_line_id.try { |id| [id.to_i64] } || [] of Int64)
      input = Acc::FinancialInput.new(ledger_id: row.ledger_id!.to_i64, date: row.date!, lines: [line],
        attachment_id: attachment_id, source: "#{SOURCE}#{row.id}")
      result = Partiduo::Api::Transaction.run do
        posted = Acc.post_financial(actor, input)
        next Partiduo::Api::Result(Int64).failure(posted.errors) if posted.failure?
        entry = posted.value!.first
        row.status = "transferred"
        row.entry_id = entry.id
        row.transferred_by_id = actor.user_id
        row.transferred_at = Partiduo::Config.now
        Records.store_error(row, nil)
        row.save!
        Partiduo::Api::Result(Int64).success(entry.id)
      end
      result.success? ? nil : result.errors.first
    end
  end
end

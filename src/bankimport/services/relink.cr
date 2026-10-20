# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Rattachement d'une ligne à traiter à une écriture déjà passée dans son
  # journal (A-PER-3, D-BKI-015) : l'écriture qui corrige celle que la ligne
  # avait produite (extournée, D-BKI-009), ou celle passée à la main que la
  # ligne signale. Aucune écriture n'est passée ; le relevé pointé de
  # l'import est refait par le contrat du rapprochement si l'écriture
  # extournée y figurait. Interne.
  module Relink
    alias Acc = Partiduo::Api::Accounting
    alias FieldError = Partiduo::Api::FieldError

    # Écart de dates admis entre la ligne du relevé et l'écriture : un mois
    # (une correction garde en général la date ; une saisie à la main peut
    # dater l'opération du jour du paiement plutôt que de son débit).
    DAYS = 31

    # Écriture retenue, ou les erreurs (champ `entry_id`).
    def self.check(actor : Partiduo::Api::Actor, row : Line, entry_id : Int64) : {Acc::EntryView?, Array(FieldError)}
      entry = begin
        Acc.entry(actor, entry_id)
      rescue Partiduo::Api::NotFound
        return {nil, [Records.error("entry_id", "relink.entry_unknown", {"id" => entry_id.to_s})]}
      end
      errors = [] of FieldError
      if entry.cancelled? || entry.reversal?
        errors << Records.error("entry_id", "relink.entry_cancelled")
      elsif entry.ledger_id != row.ledger_id
        errors << Records.error("entry_id", "relink.ledger")
      else
        amount = bank_amount(actor, entry)
        if amount != row.amount!
          errors << Records.error("entry_id", "relink.amount", {"amount" => amount.to_s, "expected" => row.amount!.to_s})
        end
        if (entry.date - row.date!).abs > DAYS.days
          errors << Records.error("entry_id", "relink.date", {"days" => DAYS.to_s})
        end
        if Line.filter(entry_id: entry.id).exclude(id: row.id).exists?
          errors << Records.error("entry_id", "relink.entry_taken")
        end
      end
      {errors.empty? ? entry : nil, errors}
    end

    # Mouvement de l'écriture sur le compte de banque du journal (entrée
    # positive, sortie négative), comme le montant d'une ligne importée.
    def self.bank_amount(actor : Partiduo::Api::Actor, entry : Acc::EntryView) : BigDecimal
      number = Acc.ledger(actor, entry.ledger_id).default_account.try(&.number)
      lines = entry.lines.select { |line| number.nil? || line.account_number == number }
      lines.sum(BigDecimal.new(0)) { |line| line.debit - line.credit }
    end

    # Refait le relevé pointé de l'import quand l'écriture extournée de la
    # ligne y figure : le relevé est défait, puis repointé avec ses
    # écritures, l'extourne et la nouvelle écriture (le total ne change pas,
    # les montants étant égaux). Rend les erreurs du rapprochement.
    def self.repoint(actor : Partiduo::Api::Actor, row : Line, entry : Acc::EntryView) : Array(FieldError)
      reversed_id = row.reversed_entry_id.try(&.to_i64) || return [] of FieldError
      import = Import.filter(id: row.import_id).first || return [] of FieldError
      statement_id = import.statement_id.try(&.to_i64) || return [] of FieldError
      detail = begin
        Acc.bank_statement(actor, statement_id)
      rescue Partiduo::Api::NotFound
        return [] of FieldError
      end
      ids = detail.lines.map(&.entry_id)
      return [] of FieldError unless ids.includes?(reversed_id)
      reversal_id = Acc.entry(actor, reversed_id).reversed_by_id
      ids << reversal_id if reversal_id
      ids << entry.id
      statement = detail.statement
      undone = Acc.unreconcile(actor, statement_id)
      return undone.errors if undone.failure?
      redone = Acc.reconcile(actor, Acc::ReconcileInput.new(ledger_id: statement.ledger_id, reference: statement.reference,
        entry_ids: ids, start_balance: statement.start_balance, end_balance: statement.end_balance,
        attachment_id: statement.attachment_id))
      return redone.errors if redone.failure?
      Import.filter(statement_id: statement_id).update(statement_id: redone.value!.id)
      [] of FieldError
    end

    # La ligne devient transférée, rattachée à l'écriture.
    def self.apply(actor : Partiduo::Api::Actor, row : Line, entry : Acc::EntryView) : Nil
      row.status = "transferred"
      row.entry_id = entry.id
      row.match_line_id = nil
      row.transferred_by_id = actor.user_id
      row.transferred_at = Partiduo::Config.now
      Records.store_error(row, nil)
      row.save!
    end
  end
end

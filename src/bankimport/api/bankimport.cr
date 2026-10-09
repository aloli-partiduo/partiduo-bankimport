# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Contrat public de l'extension d'import des relevés bancaires (ADR-011
  # D6), sur le modèle de `Partiduo::Api` (DECISIONS C2 du cœur) : acteur en
  # premier argument, contrôle d'accès en première ligne (extension active
  # et permission), objets de vue immuables, toute écriture par une commande
  # qui rend un `Result` avec ses erreurs par champ, dans une transaction.
  # L'interface de l'extension (`ui/bulma/`) ne voit que ce module et
  # `Partiduo::Api`. Une extension qui en dépend (`partiduo-perso`,
  # `depends_on "BANKIMPORT"`) l'emploie de même.
  #
  # Référence : `doc/api/bankimport.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction
    alias Acc = Partiduo::Api::Accounting

    MODULE_CODE = Bankimport::CODE
    READ        = "bankimport.read"
    IMPORT      = "bankimport.import"
    ADMIN       = "bankimport.admin"

    # Permission du socle exigée en plus pour importer : le fichier est
    # conservé en pièce jointe (D-BKI-003, D-BKI-004).
    ATTACHMENT_PERMISSION = "core.attachment.write"

    MAX_LIMIT = 1000

    # --- Formats CSV ---------------------------------------------------------------

    def self.formats(actor : Actor) : Array(FormatView)
      authorize!(actor, READ)
      CsvFormat.all.order(:name, :id).to_a.map { |row| Records.format_view(row) }
    end

    def self.format(actor : Actor, id : Int64) : FormatView
      authorize!(actor, READ)
      Records.format_view(Records.format!(id))
    end

    def self.check_format(actor : Actor, input : FormatInput, id : Int64? = nil) : Result(Nil)
      authorize!(actor, ADMIN)
      errors = Checks.format_errors(actor, input, id)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    def self.create_format(actor : Actor, input : FormatInput) : Result(FormatView)
      authorize!(actor, ADMIN)
      errors = Checks.format_errors(actor, input, nil)
      return Result(FormatView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Checks.apply_format(CsvFormat.new, input)
        row.save!
        Result(FormatView).success(Records.format_view(row))
      end
    end

    def self.update_format(actor : Actor, id : Int64, input : FormatInput) : Result(FormatView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.format!(id)
        errors = Checks.format_errors(actor, input, id)
        next Result(FormatView).failure(errors) unless errors.empty?
        Checks.apply_format(row, input).save!
        Result(FormatView).success(Records.format_view(row))
      end
    end

    # Supprime un format ; les imports qui l'ont employé le perdent de vue
    # (leurs lignes restent).
    def self.delete_format(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        Records.format!(id).delete
        Result(Nil).success(nil)
      end
    end

    # Premières lignes d'un fichier d'exemple découpées selon le séparateur
    # et l'encodage, pour régler les colonnes d'un format.
    def self.sample(actor : Actor, content : Bytes, separator : String, encoding : String) : Array(Array(String))
      authorize!(actor, READ)
      return [] of Array(String) unless SEPARATORS.includes?(separator) && ENCODINGS.includes?(encoding)
      Parsers::CsvReader.sample(content[0, Math.min(content.size, MAX_BYTES)], separator, encoding)
    end

    # --- Import ----------------------------------------------------------------------

    # Genre reconnu au contenu (`csv`, `ofx`, `qif`).
    def self.detect_kind(actor : Actor, content : Bytes) : String
      authorize!(actor, READ)
      Importer.detect_kind(content)
    end

    # Lit le fichier sans rien écrire : lignes, doublons, anomalies.
    def self.preview(actor : Actor, input : ImportInput) : Result(PreviewView)
      authorize!(actor, IMPORT)
      errors = [] of FieldError
      Records.financial_ledger(actor, input.ledger_id, "ledger_id", errors)
      kind, parsed, _format = Importer.read(input, errors)
      return Result(PreviewView).failure(errors) unless errors.empty? && parsed
      fatal = Importer.issues(parsed).select(&.field.==("content"))
      return Result(PreviewView).failure(fatal) unless fatal.empty?
      Result(PreviewView).success(Importer.preview(kind, parsed, input.ledger_id, Importer.same_file(input.ledger_id, input.content)))
    end

    # Importe le fichier (D-BKI-005) : pièce jointe du socle, lignes en
    # attente (doublons écartés, contreparties proposées par les règles,
    # écritures déjà passées signalées). Les lignes illisibles sont
    # ignorées ; elles figurent dans l'aperçu. Rien n'est passé en
    # comptabilité. Exige aussi `core.attachment.write`.
    #
    # Erreurs : `bankimport.errors.ledger.*`, `.file.*` (`blank`,
    # `too_large`, `binary`, `empty`, `not_ofx`, `not_qif`,
    # `malformed_csv`, `already_imported`, `too_many_lines`), `.format.*`,
    # `.choice.invalid` ; celles du socle pour la pièce jointe.
    def self.import_file(actor : Actor, input : ImportInput) : Result(ImportView)
      authorize!(actor, IMPORT)
      Guard.authorize!(actor, ATTACHMENT_PERMISSION)
      errors = [] of FieldError
      ledger = Records.financial_ledger(actor, input.ledger_id, "ledger_id", errors)
      kind, parsed, format = Importer.read(input, errors)
      return Result(ImportView).failure(errors) unless errors.empty? && parsed && ledger
      fatal = Importer.issues(parsed).select(&.field.==("content"))
      return Result(ImportView).failure(fatal) unless fatal.empty?
      if !input.allow_same_file && (same = Importer.same_file(input.ledger_id, input.content))
        date = (same.created_at || Time.utc).to_s("%Y-%m-%d")
        return Result(ImportView).failure(Records.error("content", "file.already_imported", {"date" => date, "id" => same.id.to_s}))
      end

      Transaction.run do
        stored = Partiduo::Api::Core.store_attachment(actor, Partiduo::Api::Core::AttachmentInput.new(
          input.filename.strip, Importer.content_type(kind, input.content), IO::Memory.new(input.content)))
        next Result(ImportView).failure(stored.errors) if stored.failure?
        row = Importer.record!(actor, input, kind, parsed, format, stored.value!.id)
        Result(ImportView).success(import_view(actor, row, ledger))
      end
    end

    def self.imports(actor : Actor, ledger_id : Int64? = nil, offset : Int32 = 0, limit : Int32 = 100) : Array(ImportView)
      authorize!(actor, READ)
      ledgers = Records.visible_ledgers(actor).to_h { |ledger| {ledger.id, ledger.code} }
      return [] of ImportView if ledgers.empty?
      rows = Import.filter(ledger_id__in: ledger_id ? ledgers.keys & [ledger_id] : ledgers.keys).order("-created_at", "-id")
      Records.import_views(page(rows, offset, limit), ledgers)
    end

    def self.import_detail(actor : Actor, id : Int64) : ImportView
      authorize!(actor, READ)
      ledgers = Records.visible_ledgers(actor).to_h { |ledger| {ledger.id, ledger.code} }
      Records.import_views([Records.import!(actor, id)], ledgers).first
    end

    # Fichier importé, relu dans les pièces jointes du socle : nom, type et
    # contenu. Exige aussi `core.attachment.read`.
    def self.import_content(actor : Actor, id : Int64) : {String, String, Bytes}?
      authorize!(actor, READ)
      row = Records.import!(actor, id)
      attachment_id = row.attachment_id.try(&.to_i64) || return
      view = Partiduo::Api::Core.attachment(actor, attachment_id)
      {view.filename, view.content_type, Partiduo::Api::Core.attachment_content(actor, attachment_id)}
    rescue Partiduo::Api::NotFound
      nil
    end

    # Supprime un import dont aucune ligne n'a été transférée, avec ses
    # lignes et son fichier (si plus rien ne le cite). `bankimport.admin`.
    def self.delete_import(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.import!(actor, id)
        if Line.filter(import_id: id, status: "transferred").exists? || row.statement_id
          next Result(Nil).failure(Records.error(FieldError::BASE, "import.in_use"))
        end
        attachment_id = row.attachment_id.try(&.to_i64)
        row.delete
        if attachment_id && actor.can?(ATTACHMENT_PERMISSION)
          Partiduo::Api::Core.delete_attachment(actor, attachment_id)
        end
        Result(Nil).success(nil)
      end
    end

    # --- Zone d'attente ---------------------------------------------------------------

    def self.lines(actor : Actor, query : LineQuery = LineQuery.new) : Array(LineView)
      authorize!(actor, READ)
      rows = line_rows(actor, query) || return [] of LineView
      Records.line_views(actor, page(rows.order(:date, :id), query.offset, query.limit))
    end

    def self.count_lines(actor : Actor, query : LineQuery = LineQuery.new) : Int64
      authorize!(actor, READ)
      line_rows(actor, query).try(&.count.to_i64) || 0_i64
    end

    def self.line(actor : Actor, id : Int64) : LineView
      authorize!(actor, READ)
      Records.line_view(actor, Records.line!(actor, id))
    end

    # Choisit la contrepartie d'une ligne à traiter (fiche *ou* compte) ;
    # `learn` : en tire une règle (D-BKI-006). Un lettrage proposé est
    # repris s'il est donné, sinon proposé quand une seule écriture ouverte
    # de la fiche a le montant de la ligne.
    def self.set_counterpart(actor : Actor, id : Int64, input : CounterpartInput) : Result(LineView)
      authorize!(actor, IMPORT)
      errors = [] of FieldError
      Checks.counterpart_errors(actor, input.card_code, input.account, errors)
      return Result(LineView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Records.line!(actor, id, lock: true)
        next Result(LineView).failure(Records.error(FieldError::BASE, "line.not_pending")) unless row.status == "pending"
        row.card_code = input.card_code.strip.empty? ? "" : Partiduo::Api::Cards.format_code(input.card_code.strip)
        row.account = input.account.strip
        row.rule_id = nil
        row.match_line_id = nil
        Records.store_error(row, nil)
        if match = input.match_line_id
          unless Categorizer.open_items(actor, row).any?(&.line_id.==(match))
            next Result(LineView).failure(Records.error("match_line_id", "line.match_invalid"))
          end
          row.match_line_id = match
        end
        row.save!
        Importer.suggest_matches(actor, [row]) if input.match_line_id.nil?
        Categorizer.learn(actor, row) if input.learn
        Result(LineView).success(Records.line_view(actor, row))
      end
    end

    # Retire la contrepartie proposée d'une ligne à traiter.
    def self.clear_counterpart(actor : Actor, id : Int64) : Result(LineView)
      authorize!(actor, IMPORT)
      Transaction.run do
        row = Records.line!(actor, id, lock: true)
        next Result(LineView).failure(Records.error(FieldError::BASE, "line.not_pending")) unless row.status == "pending"
        row.card_code = ""
        row.account = ""
        row.rule_id = nil
        row.match_line_id = nil
        Records.store_error(row, nil)
        row.save!
        Result(LineView).success(Records.line_view(actor, row))
      end
    end

    # Écritures ouvertes de la fiche de la ligne, de même montant.
    def self.open_items(actor : Actor, id : Int64) : Array(OpenItemView)
      authorize!(actor, READ)
      Categorizer.open_items(actor, Records.line!(actor, id))
    end

    # Écarte des lignes à traiter (D-BKI-005) : elles ne seront pas
    # transférées, mais restent pour l'historique et la détection des
    # doublons ; `restore` les rend à traiter. Rend le nombre de lignes.
    def self.discard(actor : Actor, ids : Array(Int64)) : Result(Int32)
      change_status(actor, ids, from: %w[pending], to: "discarded")
    end

    # Rend à traiter des lignes écartées, ou des doublons qu'on juge
    # distincts (un FITID déjà présent dans le journal l'interdit).
    def self.restore(actor : Actor, ids : Array(Int64)) : Result(Int32)
      change_status(actor, ids, from: %w[discarded duplicate], to: "pending")
    end

    # Supprime les lignes écartées et les doublons d'un journal (ou de tous) :
    # un nouvel import pourra les proposer de nouveau. `bankimport.admin`.
    def self.purge(actor : Actor, ledger_id : Int64? = nil) : Result(Int32)
      authorize!(actor, ADMIN)
      Transaction.run do
        ids = Records.visible_ledger_ids(actor)
        ids &= [ledger_id] if ledger_id
        rows = Line.filter(ledger_id__in: ids, status__in: %w[discarded duplicate])
        count = rows.count.to_i32
        Line.filter(duplicate_of_id__in: rows.pluck(:id).map(&.first.as(Int64))).update(duplicate_of_id: nil) if count > 0
        rows.delete
        Result(Int32).success(count)
      end
    end

    # Applique les règles aux lignes à traiter sans contrepartie (toutes
    # celles des journaux visibles, ou celles données). Rend le nombre de
    # lignes catégorisées.
    def self.apply_rules(actor : Actor, ids : Array(Int64)? = nil) : Result(Int32)
      authorize!(actor, IMPORT)
      Transaction.run do
        rows = Line.filter(ledger_id__in: Records.visible_ledger_ids(actor), status: "pending")
        rows = rows.filter(id__in: ids) if ids
        list = rows.order(:date, :id).to_a
        count = Categorizer.apply(list)
        Importer.suggest_matches(actor, list)
        Result(Int32).success(count)
      end
    end

    # Transfère des lignes à traiter dans leur journal financier (D-BKI-008),
    # une écriture par ligne par `Partiduo::Api::Accounting.post_financial`,
    # pièce jointe de l'import rattachée, lettrage proposé appliqué. Les
    # lignes sans contrepartie ou refusées par la Comptabilité restent à
    # traiter, avec leur erreur. Exige aussi `accounting.entry.post` et
    # l'écriture dans le journal.
    def self.transfer(actor : Actor, ids : Array(Int64)) : Result(TransferReportView)
      authorize!(actor, IMPORT)
      return Result(TransferReportView).failure(Records.error("ids", "line.none_selected")) if ids.empty?
      rows = Line.filter(id__in: ids.uniq, ledger_id__in: Records.visible_ledger_ids(actor)).order(:date, :id).to_a
      done, failed = Transfer.run(actor, rows)
      Result(TransferReportView).success(TransferReportView.new(Records.line_views(actor, done), Records.line_views(actor, failed)))
    end

    # --- Pointage ---------------------------------------------------------------------

    # Pointe le relevé d'un import (D-BKI-010) : ses lignes transférées, non
    # encore rapprochées, sont rattachées au relevé `reference` par le
    # rapprochement de la Comptabilité (`reconcile`), avec les soldes donnés
    # et le fichier importé en pièce jointe. Exige aussi
    # `accounting.matching.write`. Les erreurs du rapprochement sont celles
    # de la Comptabilité (`accounting.errors.reconciliation.*`).
    def self.reconcile(actor : Actor, id : Int64, input : ReconcileInput) : Result(ImportView)
      authorize!(actor, IMPORT)
      row = Records.import!(actor, id)
      ledger_id = row.ledger_id!.to_i64
      if row.statement_id
        return Result(ImportView).failure(Records.error(FieldError::BASE, "reconcile.already"))
      end
      open = Acc.reconciliation(actor, ledger_id).unreconciled.map(&.entry_id).to_set
      entry_ids = Line.filter(import_id: id, status: "transferred").to_a.compact_map(&.entry_id.try(&.to_i64)).select { |entry| open.includes?(entry) }
      return Result(ImportView).failure(Records.error(FieldError::BASE, "reconcile.nothing")) if entry_ids.empty?
      Transaction.run do
        result = Acc.reconcile(actor, Acc::ReconcileInput.new(ledger_id: ledger_id, reference: input.reference,
          entry_ids: entry_ids, start_balance: input.start_balance, end_balance: input.end_balance,
          attachment_id: row.attachment_id.try(&.to_i64)))
        next Result(ImportView).failure(result.errors) if result.failure?
        statement = result.value!
        row.statement_id = statement.id
        row.statement_reference = statement.reference
        row.start_balance = input.start_balance
        row.end_balance = input.end_balance
        row.save!
        Result(ImportView).success(import_view(actor, row, nil))
      end
    end

    # --- Règles de catégorisation ---------------------------------------------------

    def self.rules(actor : Actor) : Array(RuleView)
      authorize!(actor, READ)
      Categorizer.ordered_rules.map { |row| Records.rule_view(row) } +
        Rule.filter(active: false).order(:position, :id).to_a.map { |row| Records.rule_view(row) }
    end

    def self.rule(actor : Actor, id : Int64) : RuleView
      authorize!(actor, READ)
      Records.rule_view(Records.rule!(id))
    end

    def self.create_rule(actor : Actor, input : RuleInput) : Result(RuleView)
      authorize!(actor, ADMIN)
      errors = Checks.rule_errors(actor, input)
      return Result(RuleView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Checks.apply_rule(Rule.new(learned: false, hits: 0, created_by_id: actor.user_id), input)
        row.save!
        Result(RuleView).success(Records.rule_view(row))
      end
    end

    # Modifie une règle ; une règle apprise modifiée devient une règle saisie.
    def self.update_rule(actor : Actor, id : Int64, input : RuleInput) : Result(RuleView)
      authorize!(actor, ADMIN)
      errors = Checks.rule_errors(actor, input)
      return Result(RuleView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Checks.apply_rule(Records.rule!(id), input)
        row.learned = false
        row.save!
        Result(RuleView).success(Records.rule_view(row))
      end
    end

    # Supprime une règle ; les lignes qu'elle a catégorisées gardent leur
    # contrepartie.
    def self.delete_rule(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        Records.rule!(id).delete
        Result(Nil).success(nil)
      end
    end

    # --- Tableau de bord ---------------------------------------------------------------

    # Lignes à traiter des journaux visibles, pour la tuile et le compteur du
    # menu ; `nil` si l'extension est inactive ou l'acteur sans droit.
    def self.tile(actor : Actor) : TileView?
      return unless Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
      rows = Line.filter(ledger_id__in: Records.visible_ledger_ids(actor), status: "pending").to_a
      ready = rows.count { |row| !row.card_code.to_s.empty? || !row.account.to_s.empty? }
      TileView.new(rows.size, ready, rows.min_of?(&.date!))
    end

    def self.pending_count(actor : Actor) : Int64?
      tile(actor).try(&.pending_count.to_i64)
    end

    # --- Outils ------------------------------------------------------------------------

    private def self.authorize!(actor : Actor, permission : String) : Nil
      Guard.authorize!(actor, permission, module_code: MODULE_CODE)
    end

    private def self.page(rows, offset : Int32, limit : Int32)
      start = Math.max(offset, 0)
      rows[start...(start + limit.clamp(1, MAX_LIMIT))].to_a
    end

    private def self.import_view(actor : Actor, row : Import, ledger : Acc::LedgerView?) : ImportView
      ledgers = ledger ? {ledger.id => ledger.code} : Records.visible_ledgers(actor).to_h { |item| {item.id, item.code} }
      Records.import_views([row], ledgers).first
    end

    private def self.line_rows(actor : Actor, query : LineQuery)
      ids = Records.visible_ledger_ids(actor)
      if ledger_id = query.ledger_id
        ids &= [ledger_id]
      end
      return if ids.empty?
      rows = Line.filter(ledger_id__in: ids)
      query.import_id.try { |import_id| rows = rows.filter(import_id: import_id) }
      query.status.try { |status| rows = rows.filter(status: status) }
      rows = rows.filter(card_code: "", account: "") if query.unassigned_only
      if text = query.search.try(&.strip).presence
        rows = rows.filter do
          q(label__icontains: text) | q(extra__icontains: text) | q(counterparty__icontains: text) | q(reference__icontains: text)
        end
      end
      rows
    end

    private def self.change_status(actor : Actor, ids : Array(Int64), from : Array(String), to : String) : Result(Int32)
      authorize!(actor, IMPORT)
      return Result(Int32).failure(Records.error("ids", "line.none_selected")) if ids.empty?
      Transaction.run do
        rows = Line.filter(id__in: ids.uniq, ledger_id__in: Records.visible_ledger_ids(actor), status__in: from).lock.to_a
        conflict = rows.find do |row|
          to == "pending" && !row.fitid.to_s.empty? &&
            Line.filter(ledger_id: row.ledger_id, fitid: row.fitid).exclude(id: row.id).exclude(status: "duplicate").exists?
        end
        if conflict
          next Result(Int32).failure(Records.error("ids", "line.fitid_taken", {"fitid" => conflict.fitid.to_s}))
        end
        rows.each do |row|
          row.status = to
          row.duplicate_of_id = nil if to == "pending"
          row.save!
        end
        Result(Int32).success(rows.size)
      end
    end
  end
end

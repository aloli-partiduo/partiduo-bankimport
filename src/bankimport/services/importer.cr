# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Lecture et enregistrement d'un fichier de relevé (D-BKI-002, D-BKI-005,
  # D-BKI-007) : genre reconnu, lecture, doublons, pièce jointe du socle,
  # lignes en attente, règles, écritures déjà passées signalées. Interne.
  module Importer
    alias Api = Bankimport::Api
    alias FieldError = Partiduo::Api::FieldError

    # Genre reconnu au contenu : en-tête OFX, `!Type` d'un QIF, CSV sinon.
    def self.detect_kind(bytes : Bytes) : String
      text = Parsers::Text.guess(bytes[0, Math.min(bytes.size, 4096)])
      return "ofx" if Parsers::OfxReader.ofx?(text)
      return "qif" if Parsers::QifReader.qif?(text)
      "csv"
    end

    # Lecture sans écriture : genre, résultat de la lecture, format CSV
    # employé ; erreurs de saisie dans `errors`.
    def self.read(input : Api::ImportInput, errors : Array(FieldError)) : {String, Parsers::Parsed?, CsvFormat?}
      content_errors(input, errors)
      # Sans contenu lisible, le genre et le format ne se discutent pas.
      return {input.kind, nil, nil} unless errors.empty?
      kind = input.kind == "auto" ? detect_kind(input.content) : input.kind
      unless Api::KINDS.includes?(kind)
        errors << Records.error("kind", "choice.invalid", {"value" => kind})
        return {kind, nil, nil}
      end
      format = kind == "csv" ? csv_format(input, errors) : nil
      if kind == "qif" && !Api::DATE_FORMATS.includes?(input.date_format)
        errors << Records.error("date_format", "choice.invalid", {"value" => input.date_format})
      end
      return {kind, nil, format} unless errors.empty?

      parsed = case kind
               when "ofx" then Parsers::OfxReader.parse(input.content)
               when "qif" then Parsers::QifReader.parse(input.content, input.date_format)
               else            Parsers::CsvReader.parse(input.content, Records.settings(format || return {kind, nil, nil}))
               end
      if parsed.lines.size > Api::MAX_LINES
        errors << Records.error("content", "file.too_many_lines", {"max" => Api::MAX_LINES.to_s})
      end
      {kind, parsed, format}
    end

    private def self.content_errors(input : Api::ImportInput, errors : Array(FieldError)) : Nil
      content = input.content
      if content.empty?
        errors << Records.error("content", "file.blank")
      elsif content.size > Api::MAX_BYTES
        errors << Records.error("content", "file.too_large", {"max" => (Api::MAX_BYTES // (1024 * 1024)).to_s})
      elsif content.includes?(0_u8)
        errors << Records.error("content", "file.binary")
      end
      errors << Records.error("filename", "file.filename.blank") if input.filename.strip.empty?
    end

    private def self.csv_format(input : Api::ImportInput, errors : Array(FieldError)) : CsvFormat?
      if id = input.format_id
        CsvFormat.filter(id: id).first || (errors << Records.error("format_id", "format.unknown"); nil)
      else
        errors << Records.error("format_id", "format.blank")
        nil
      end
    end

    # Anomalies de lecture en erreurs du contrat : `content` pour le
    # fichier, `lines[<rang>]` pour une ligne.
    def self.issues(parsed : Parsers::Parsed) : Array(FieldError)
      parsed.issues.map do |issue|
        field = issue.position.zero? ? "content" : "lines[#{issue.position}]"
        FieldError.new(field, issue.key, issue.params.merge({"line" => issue.position.to_s}))
      end
    end

    def self.same_file(ledger_id : Int64, content : Bytes) : Import?
      Import.filter(ledger_id: ledger_id, sha256: Digest::SHA256.hexdigest(content)).order(:id).first
    end

    def self.preview(kind : String, parsed : Parsers::Parsed, ledger_id : Int64, same : Import?) : Api::PreviewView
      duplicates = Duplicates.detect(ledger_id, parsed.lines)
      lines = parsed.lines.map_with_index do |line, index|
        Api::PreviewLineView.new(position: line.position, date: line.date, amount: line.amount, label: line.label,
          extra: line.extra, reference: line.reference, fitid: line.fitid, duplicate: !duplicates[index].nil?,
          payee: line.payee, iban: line.iban)
      end
      Api::PreviewView.new(kind: kind, lines: lines, issues: issues(parsed), same_file_import_id: same.try(&.id.try(&.to_i64)),
        account_number: parsed.account_number, end_balance: parsed.end_balance, statement_on: parsed.statement_on)
    end

    # Type MIME sous lequel le socle conserve le fichier (D-BKI-014) : les
    # types des relevés que le socle admet depuis A-BKI-1 (D-AMD-001 du
    # cœur). Les fichiers conservés avant restent en `text/plain` ou
    # `application/xml` : ils se relisent de même (`import_content`).
    def self.content_type(kind : String) : String
      case kind
      when "ofx" then "application/x-ofx"
      when "qif" then "application/qif"
      else            "text/csv"
      end
    end

    # Enregistre l'import et ses lignes (dans la transaction de l'appelant).
    def self.record!(actor : Partiduo::Api::Actor, input : Api::ImportInput, kind : String, parsed : Parsers::Parsed,
                     format : CsvFormat?, attachment_id : Int64) : Import
      row = Import.create!(
        ledger_id: input.ledger_id, kind: kind, format_id: format.try(&.id), filename: input.filename.strip[0, 255],
        attachment_id: attachment_id, sha256: Digest::SHA256.hexdigest(input.content),
        account_number: parsed.account_number, currency_code: parsed.currency_code, end_balance: parsed.end_balance,
        start_balance: parsed.start_balance, statement_on: parsed.statement_on, line_count: parsed.lines.size,
        duplicate_count: 0, created_by_id: actor.user_id, statement_reference: "",
      )
      duplicates = Duplicates.detect(input.ledger_id, parsed.lines)
      created_by_fitid = {} of String => Int64
      lines = parsed.lines.map_with_index do |line, index|
        duplicate_of = duplicates[index]
        duplicate_of = created_by_fitid[line.fitid]? if duplicate_of == 0
        status = duplicates[index].nil? ? "pending" : "duplicate"
        created = Line.create!(
          import_id: row.id, ledger_id: input.ledger_id, position: line.position, date: line.date, amount: line.amount,
          label: line.label, extra: line.extra, reference: line.reference, fitid: line.fitid,
          counterparty: line.counterparty, payee: line.payee, iban: line.iban,
          fingerprint: Duplicates.fingerprint(line.date, line.amount, line.label),
          status: status, duplicate_of_id: duplicate_of, card_code: "", account: "", error_key: "", error_params: "",
        )
        created_by_fitid[line.fitid] ||= created.id!.to_i64 unless line.fitid.empty? || status == "duplicate"
        created
      end
      row.duplicate_count = lines.count(&.status.==("duplicate"))
      row.save!
      pending = lines.select(&.status.==("pending"))
      Categorizer.apply(actor, pending)
      suggest_matches(actor, pending)
      Duplicates.flag_recorded(actor, pending)
      row
    end

    # Lettrage proposé : une seule écriture ouverte de la fiche, de même
    # montant (D-BKI-006).
    def self.suggest_matches(actor : Partiduo::Api::Actor, rows : Array(Line)) : Nil
      rows.each do |row|
        next if row.card_code.to_s.empty? || row.match_line_id
        items = Categorizer.open_items(actor, row)
        next unless items.size == 1
        row.match_line_id = items.first.line_id
        row.save!
      end
    end
  end
end

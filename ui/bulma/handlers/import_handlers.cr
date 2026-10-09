# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Ui
    # `/ext/BANKIMPORT/import` : import d'un relevé (ADR-011 D6), en deux
    # temps sur le même écran — fichier (ou texte collé), journal, genre et
    # format ; puis aperçu des lignes lues (doublons et anomalies signalés)
    # et import. Le fichier passe d'une étape à l'autre encodé en base64.
    # Rien n'est passé en comptabilité : les lignes vont dans la zone
    # d'attente.
    class ImportHandler < Handler
      PREVIEW_ROWS = 300

      def get
        show_start(nil, 200, default_values)
      end

      def post
        upload = request.data.fetch("file", nil).as?(Marten::HTTP::UploadedFile)
        content, filename = read_content(upload)
        values = submitted(filename)
        return show_start(I18n.t("bankimport_ui.import.too_large"), 422, values) if content.size > Api::MAX_BYTES
        input = Api::ImportInput.new(ledger_id: id_field("ledger_id") || 0_i64, filename: filename, content: content,
          kind: values["kind"], format_id: id_field("format_id"), date_format: values["date_format"],
          allow_same_file: field("allow_same_file") == "1")
        if field("step") == "import"
          result = Api.import_file(actor, input)
          if result.success?
            view = result.value!
            flash["success"] = I18n.t("bankimport_ui.import.done", count: view.pending_count, duplicates: view.duplicate_count)
            return go(Ui.url("import_detail", id: view.id))
          end
          preview = Api.preview(actor, input)
          return show_preview(input, preview.value!, values, messages(result)) if preview.success?
          return show_start(messages(result), 422, values)
        end
        preview = Api.preview(actor, input)
        return show_start(messages(preview), 422, values) if preview.failure?
        show_preview(input, preview.value!, values, nil)
      ensure
        upload.try { |file| file.io.delete rescue nil }
      end

      private def default_values : Hash(String, String)
        ledger = query("ledger").presence || ledgers.first?.try(&.id.to_s) || ""
        format = Api.formats(actor).find { |item| item.ledger_id.to_s == ledger } || Api.formats(actor).first?
        {"ledger_id" => ledger, "kind" => "auto", "format_id" => format.try(&.id.to_s) || "", "date_format" => "dd/mm/yyyy",
         "filename" => ""}
      end

      private def submitted(filename : String) : Hash(String, String)
        {"ledger_id" => field("ledger_id"), "kind" => field("kind").presence || "auto", "format_id" => field("format_id"),
         "date_format" => field("date_format").presence || "dd/mm/yyyy", "filename" => filename}
      end

      # Contenu : fichier déposé, sinon reçu de l'aperçu (base64), sinon
      # texte collé ; et nom du fichier.
      private def read_content(upload : Marten::HTTP::UploadedFile?) : {Bytes, String}
        if upload && upload.size > 0
          io = upload.io
          io.rewind
          return {io.getb_to_end, upload.filename.presence || pasted_name}
        end
        if payload = field("payload").presence
          bytes = begin
            Base64.decode(payload)
          rescue Base64::Error
            Bytes.empty
          end
          return {bytes, field("filename").presence || pasted_name}
        end
        {field("content", strip: false).to_slice, field("filename").presence || pasted_name}
      end

      private def pasted_name : String
        "#{I18n.t("bankimport_ui.import.pasted_name")}-#{Partiduo::Api::Core.today.to_s("%Y%m%d")}.txt"
      end

      private def base_values : Hash(String, (String | Array(Screen::Crumb) | Array(Row))?)
        {
          "title"  => I18n.t("bankimport.menu.bankimport_import"),
          "crumbs" => crumbs({I18n.t("bankimport.menu.bankimport_import"), nil}).as(Array(Screen::Crumb)),
        } of String => (String | Array(Screen::Crumb) | Array(Row))?
      end

      private def show_start(error : String?, status : Int32, values : Hash(String, String)) : Marten::HTTP::Response
        page_values = base_values
        page_values["step"] = "start"
        page_values["error"] = error
        page_values["ledgers"] = choice_rows(ledger_options, values["ledger_id"])
        page_values["kinds"] = choice_rows([option("auto", I18n.t("bankimport_ui.import.kind_auto"))] +
                                           code_options(Api::KINDS, "bankimport.kinds"), values["kind"])
        formats = Api.formats(actor).map do |item|
          option(item.id.to_s, item.institution.empty? ? item.name : "#{item.name} · #{item.institution}")
        end
        page_values["formats"] = choice_rows([blank_option] + formats, values["format_id"])
        page_values["date_formats"] = choice_rows(date_format_options, values["date_format"])
        page_values["no_ledger"] = Ui.flag(ledgers.empty?)
        page_values["no_format"] = Ui.flag(Api.formats(actor).empty?)
        page_values["can_admin"] = Ui.flag(can_admin?)
        page("bankimport/import.html", page_values, status: status)
      end

      private def show_preview(input : Api::ImportInput, preview : Api::PreviewView, values : Hash(String, String),
                               error : String?) : Marten::HTTP::Response
        page_values = base_values
        page_values["step"] = "preview"
        page_values["error"] = error
        page_values["payload"] = Base64.strict_encode(input.content)
        page_values["filename"] = input.filename
        page_values["ledger_id"] = values["ledger_id"]
        page_values["ledger"] = ledgers.find { |ledger| ledger.id == input.ledger_id }.try { |ledger| "#{ledger.code} · #{ledger.name}" }
        page_values["kind"] = preview.kind
        page_values["kind_label"] = I18n.t("bankimport.kinds.#{preview.kind}")
        page_values["format_id"] = values["format_id"]
        page_values["date_format"] = values["date_format"]
        page_values["summary"] = I18n.t("bankimport_ui.import.summary", count: preview.lines.size, fresh: preview.new_count,
          duplicates: preview.duplicate_count)
        page_values["same_file"] = preview.same_file_import_id.try { |id| Ui.url("import_detail", id: id) }
        page_values["account_number"] = preview.account_number.presence
        page_values["end_balance"] = preview.end_balance.try { |amount| fmt.amount(amount) }
        page_values["issues"] = preview.issues.map { |issue| Ui.row({"message" => fmt.message(issue)}) }
        page_values["rows"] = preview.lines.first(PREVIEW_ROWS).map do |line|
          Ui.row({"position" => line.position.to_s, "date" => fmt.date(line.date), "amount" => fmt.amount(line.amount),
                  "direction" => line.amount > 0 ? "in" : "out", "label" => line.label, "extra" => line.extra.presence,
                  "reference" => line.reference.presence, "duplicate" => Ui.flag(line.duplicate)})
        end
        page_values["truncated"] = preview.lines.size > PREVIEW_ROWS ? I18n.t("bankimport_ui.import.truncated", count: PREVIEW_ROWS) : nil
        page_values["importable"] = preview.new_count > 0 ? I18n.t("bankimport_ui.import.submit", count: preview.new_count) : nil
        page("bankimport/import.html", page_values, status: error ? 422 : 200)
      end
    end
  end
end

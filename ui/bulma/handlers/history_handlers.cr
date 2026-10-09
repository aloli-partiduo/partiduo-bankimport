# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Ui
    # `/ext/BANKIMPORT/imports` : historique des imports (D-BKI-007) —
    # fichier, genre, journal, date, période couverte, lignes lues, à
    # traiter, transférées, doublons ; relevé pointé. Liste triable,
    # filtrable et exportable.
    class ImportsHandler < Handler
      def get
        columns = [
          Table::Column.new("created", I18n.t("bankimport_ui.imports.created"), "mono"),
          Table::Column.new("filename", I18n.t("bankimport_ui.imports.filename")),
          Table::Column.new("kind", I18n.t("bankimport_ui.imports.kind"), secondary: true),
          Table::Column.new("ledger", I18n.t("bankimport_ui.imports.ledger"), "mono"),
          Table::Column.new("period", I18n.t("bankimport_ui.imports.period"), secondary: true),
          Table::Column.new("lines", I18n.t("bankimport_ui.imports.lines"), "number"),
          Table::Column.new("pending", I18n.t("bankimport_ui.imports.pending"), "number"),
          Table::Column.new("transferred", I18n.t("bankimport_ui.imports.transferred"), "number"),
          Table::Column.new("duplicates", I18n.t("bankimport_ui.imports.duplicates"), "number"),
          Table::Column.new("statement", I18n.t("bankimport_ui.imports.statement")),
        ]
        rows = Api.imports(actor, query("ledger").to_i64?, limit: 1000).map do |view|
          url = Ui.url("import_detail", id: view.id)
          Table::Row.new([
            Table::Cell.new(fmt.date(view.created_at), url, sort: view.created_at.to_s("%Y-%m-%d %H:%M:%S")),
            Table::Cell.new(view.filename, url),
            Table::Cell.new(I18n.t(view.kind_key)),
            Table::Cell.new(view.ledger_code),
            Table::Cell.new(view.first_date.try { |first| "#{fmt.date(first)} – #{fmt.date(view.last_date)}" } || "",
              sort: view.first_date.try(&.to_s("%Y-%m-%d")) || ""),
            Table::Cell.new(view.line_count.to_s, sort: BigDecimal.new(view.line_count)),
            Table::Cell.new(view.pending_count.to_s, sort: BigDecimal.new(view.pending_count)),
            Table::Cell.new(view.transferred_count.to_s, sort: BigDecimal.new(view.transferred_count)),
            Table::Cell.new(view.duplicate_count.to_s, sort: BigDecimal.new(view.duplicate_count)),
            Table::Cell.new(view.statement_reference),
          ])
        end
        table = Table.new(I18n.t("bankimport.menu.bankimport_history"), columns, rows, Ui.url("imports"),
          empty_message: I18n.t("bankimport_ui.imports.none"), id: "bki-imports")
        actions = can_import? ? [link_action("bankimport.menu.bankimport_import", Ui.url("import"), "primary", "upload")] : [] of Screen::Action
        list_page(I18n.t("bankimport.menu.bankimport_history"), table, crumbs({I18n.t("bankimport.menu.bankimport_history"), nil}),
          "bankimport_ui.imports.csv_name", actions)
      end
    end

    # `/ext/BANKIMPORT/imports/<id>` : un import — fichier, journal, compte
    # et solde lus, compteurs, lignes ; pointage du relevé (rapprochement de
    # la Comptabilité) ; téléchargement du fichier ; suppression tant
    # qu'aucune ligne n'a été transférée.
    class ImportDetailHandler < Handler
      def get
        render_detail(Api.import_detail(actor, id_param))
      end

      def render_detail(view : Api::ImportView, error : String? = nil, status : Int32 = 200,
                        values = {} of String => String) : Marten::HTTP::Response
        lines = Api.lines(actor, Api::LineQuery.new(import_id: view.id, status: nil, limit: Api::MAX_LIMIT))
        page("bankimport/import_detail.html", {
          "title"          => view.filename,
          "crumbs"         => crumbs({I18n.t("bankimport.menu.bankimport_history"), Ui.url("imports")}, {view.filename, nil}),
          "actions"        => detail_actions(view),
          "import"         => Present.import(view, fmt),
          "account_number" => view.account_number.presence,
          "end_balance"    => view.end_balance.try { |amount| fmt.amount(amount) },
          "total_in"       => fmt.amount(view.total_in),
          "total_out"      => fmt.amount(view.total_out),
          "format_name"    => view.format_name,
          "rows"           => lines.map { |line| Present.line(line, fmt, false) },
          "can_reconcile"  => Ui.flag(can_import? && !view.reconciled? && view.transferred_count > 0),
          "reconcile_url"  => Ui.url("import_reconcile", id: view.id),
          "reference"      => values["reference"]? || default_reference(view),
          "start_balance"  => values["start_balance"]? || view.start_balance.try { |amount| fmt.input_number(amount) } || "",
          "end_balance_in" => values["end_balance"]? || view.end_balance.try { |amount| fmt.input_number(amount) } || "",
          "error"          => error,
        }, status: status)
      end

      private def detail_actions(view : Api::ImportView) : Array(Screen::Action)
        actions = [] of Screen::Action
        actions << link_action("bankimport_ui.imports.process", "#{Ui.url("lines")}?import=#{view.id}", "primary", "check") if view.pending_count > 0
        actions << link_action("bankimport_ui.imports.download", Ui.url("import_file", id: view.id), "", "download") if view.attachment_id
        if can_admin? && view.transferred_count.zero? && !view.reconciled?
          actions << post_action("bankimport_ui.imports.delete", Ui.url("import_delete", id: view.id), "bankimport_ui.imports.delete_confirm",
            "danger", "x")
        end
        actions
      end

      private def default_reference(view : Api::ImportView) : String
        date = view.statement_on || view.last_date || view.created_at
        "#{view.ledger_code}-#{date.to_s("%Y%m%d")}-#{view.id}"[0, 40]
      end
    end

    # Fichier importé, relu dans les pièces jointes du socle.
    class ImportFileHandler < Handler
      def get
        found = Api.import_content(actor, id_param)
        return PartiduoUi::ErrorPage.render(request, 404) if found.nil?
        filename, content_type, bytes = found
        response = Marten::HTTP::Response.new(String.new(bytes), content_type: content_type)
        response.headers["Content-Disposition"] = %(attachment; filename="#{filename.gsub(/["\\\r\n]/, "_")}")
        response
      rescue Partiduo::Api::AccessDenied
        PartiduoUi::ErrorPage.render(request, 403)
      end
    end

    # Pointe le relevé de l'import (`Api.reconcile`).
    class ImportReconcileHandler < ImportDetailHandler
      def get
        go(Ui.url("import_detail", id: id_param))
      end

      def post
        view = Api.import_detail(actor, id_param)
        values = {"reference" => field("reference"), "start_balance" => field("start_balance"), "end_balance" => field("end_balance")}
        start, finish = decimal_field("start_balance"), decimal_field("end_balance")
        if (start.nil? && !field("start_balance").empty?) || (finish.nil? && !field("end_balance").empty?)
          return render_detail(view, I18n.t("bankimport_ui.imports.invalid_amount"), 422, values)
        end
        result = Api.reconcile(actor, view.id, Api::ReconcileInput.new(field("reference"), start, finish))
        return render_detail(view, messages(result), 422, values) if result.failure?
        flash["success"] = I18n.t("bankimport_ui.flash.reconciled", reference: result.value!.statement_reference)
        go(Ui.url("import_detail", id: view.id))
      rescue ex : Partiduo::Api::Forbidden
        flash["danger"] = I18n.t(ex.key)
        go(Ui.url("import_detail", id: id_param))
      end
    end

    class ImportDeleteHandler < Handler
      def get
        go(Ui.url("imports"))
      end

      def post
        result = Api.delete_import(actor, id_param)
        return after(result, "bankimport_ui.flash.import_deleted", Ui.url("imports")) if result.success?
        after(result, "", Ui.url("import_detail", id: id_param))
      end
    end
  end
end

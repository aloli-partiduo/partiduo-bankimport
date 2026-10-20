# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Ui
    # `/ext/BANKIMPORT/lines` : zone d'attente (ADR-011 D6). Filtres
    # (journal, statut, import, texte, sans contrepartie) ; pour chaque ligne
    # à traiter, la contrepartie proposée — par une règle ou choisie ici,
    # fiche ou compte, enregistrée en HTMX sans recharger la page — ;
    # actions groupées sur les lignes cochées : transférer, écarter,
    # reprendre, appliquer les règles.
    class LinesHandler < Handler
      STATUSES = Api::STATUSES

      def get
        status = query("status").presence || "pending"
        status = "pending" unless status == "all" || STATUSES.includes?(status)
        query_input = Api::LineQuery.new(ledger_id: query("ledger").to_i64?, import_id: query("import").to_i64?,
          status: status == "all" ? nil : status, search: query("q").presence, unassigned_only: query("unassigned") == "1",
          limit: 500)
        views = Api.lines(actor, query_input)
        total = Api.count_lines(actor, query_input)
        page("bankimport/lines.html", {
          "title"     => I18n.t("bankimport.menu.bankimport_lines"),
          "crumbs"    => crumbs({I18n.t("bankimport.menu.bankimport_lines"), nil}),
          "actions"   => header_actions,
          "rows"      => views.map { |view| Present.line(view, fmt, can_import?) },
          "summary"   => I18n.t("bankimport_ui.lines.summary", count: total),
          "truncated" => total > views.size ? I18n.t("bankimport_ui.lines.truncated", count: views.size) : nil,
          "ledgers"   => choice_rows(ledger_options(blank: true), query("ledger")),
          "statuses"  => choice_rows([option("all", I18n.t("bankimport_ui.lines.all_statuses"))] +
                                    code_options(STATUSES, "bankimport.statuses"), status),
          "q"          => query("q"),
          "import"     => query("import"),
          "unassigned" => Ui.flag(query("unassigned") == "1"),
          "can_import" => Ui.flag(can_import?),
          "can_admin"  => Ui.flag(can_admin?),
          "pending"    => Ui.flag(status == "pending"),
          "restorable" => Ui.flag(status == "discarded" || status == "duplicate" || status == "all"),
          "cards"      => card_list,
          "accounts"   => account_list,
          "next"       => request.full_path,
        })
      end

      private def header_actions : Array(Screen::Action)
        actions = [] of Screen::Action
        actions << link_action("bankimport.menu.bankimport_import", Ui.url("import"), "primary", "upload") if can_import?
        actions << post_action("bankimport_ui.lines.purge", Ui.url("purge"), "bankimport_ui.lines.purge_confirm", "", "x") if can_admin?
        actions
      end

      # Fiches et comptes proposés à la saisie de la contrepartie (listes
      # `datalist`) ; rien si l'acteur ne peut pas les lire.
      private def card_list : Array(Row)
        Partiduo::Api::Cards.cards(actor, Partiduo::Api::Cards::CardQuery.new(limit: 1000)).map do |card|
          Ui.row({"value" => card.code, "label" => card.name})
        end
      rescue Partiduo::Api::AccessDenied
        [] of Row
      end

      private def account_list : Array(Row)
        Acc.chart(actor).compact_map do |line|
          account = line.account
          Ui.row({"value" => account.number, "label" => account.label}) if account.direct_use
        end
      rescue Partiduo::Api::AccessDenied
        [] of Row
      end
    end

    # Contrepartie d'une ligne (formulaire de la ligne) : fiche *ou* compte,
    # bénéficiaire, règle apprise si « Mémoriser » est coché. En HTMX, la
    # ligne mise à jour (ou refusée, avec son message) remplace l'ancienne.
    class LineHandler < Handler
      def get
        go(Ui.url("lines"))
      end

      def post
        input = Api::CounterpartInput.new(card_code: field("card_code"), account: field("account"),
          learn: field("learn") == "1", payee: request.data.has_key?("payee") ? field("payee") : nil)
        result = Api.set_counterpart(actor, id_param, input)
        if htmx?
          view = result.success? ? result.value! : Api.line(actor, id_param)
          return fragment(view, result.success? ? nil : messages(result), result.success? ? 200 : 422)
        end
        after(result, "bankimport_ui.flash.counterpart", back(Ui.url("lines")))
      end

      def fragment(view : Api::LineView, error : String?, status : Int32) : Marten::HTTP::Response
        render("bankimport/_line.html", {
          "line"       => Present.line(view, fmt, can_import?),
          "form_error" => error,
          "can_import" => Ui.flag(can_import?),
          "next"       => field("next"),
        }, status: status)
      end
    end

    # Retire la contrepartie proposée d'une ligne.
    class LineClearHandler < LineHandler
      def post
        result = Api.clear_counterpart(actor, id_param)
        if htmx?
          view = result.success? ? result.value! : Api.line(actor, id_param)
          return fragment(view, result.success? ? nil : messages(result), result.success? ? 200 : 422)
        end
        after(result, "bankimport_ui.flash.cleared", back(Ui.url("lines")))
      end
    end

    # Rattache une ligne à traiter à l'écriture déjà passée qui la porte
    # (A-PER-3, D-BKI-015) : l'écriture signalée, ou celle qui corrige
    # l'écriture extournée. En HTMX, la ligne remplace l'ancienne.
    class LineRelinkHandler < LineHandler
      def post
        entry_id = field("entry_id").strip.to_i64?
        if entry_id.nil?
          message = fmt.message(Partiduo::Api::FieldError.new("entry_id", "bankimport.errors.relink.entry_unknown",
            {"id" => field("entry_id").strip}))
          return fragment(Api.line(actor, id_param), message, 422) if htmx?
          flash["danger"] = message
          return go(back(Ui.url("lines")))
        end
        result = Api.relink(actor, id_param, entry_id)
        if htmx?
          view = result.success? ? result.value! : Api.line(actor, id_param)
          return fragment(view, result.success? ? nil : messages(result), result.success? ? 200 : 422)
        end
        after(result, "bankimport_ui.flash.relinked", back(Ui.url("lines")))
      end
    end

    # Actions groupées sur les lignes cochées.
    class LinesActionHandler < Handler
      def get
        go(Ui.url("lines"))
      end

      def post
        ids = checked_ids
        url = back(Ui.url("lines"))
        case field("action")
        when "transfer"
          result = Api.transfer(actor, ids)
          if result.failure?
            flash["danger"] = messages(result)
            return go(url)
          end
          report = result.value!
          flash["success"] = I18n.t("bankimport_ui.flash.transferred", count: report.transferred.size) unless report.transferred.empty?
          flash["danger"] = I18n.t("bankimport_ui.flash.transfer_failed", count: report.failed.size) unless report.failed.empty?
          go(url)
        when "discard"
          result = Api.discard(actor, ids)
          after_count(result, "bankimport_ui.flash.discarded", url)
        when "restore"
          result = Api.restore(actor, ids)
          after_count(result, "bankimport_ui.flash.restored", url)
        when "apply_rules"
          result = Api.apply_rules(actor, ids.empty? ? nil : ids)
          after_count(result, "bankimport_ui.flash.categorized", url)
        else
          go(url)
        end
      end
    end

    # Supprime les lignes écartées et les doublons des journaux visibles.
    class PurgeHandler < Handler
      def get
        go(Ui.url("lines"))
      end

      def post
        result = Api.purge(actor, field("ledger").to_i64?)
        after_count(result, "bankimport_ui.flash.purged", Ui.url("lines"))
      end
    end
  end
end

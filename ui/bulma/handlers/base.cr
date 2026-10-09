# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Ui
    # Base des écrans de l'extension, sur celle des écrans du référentiel de
    # l'interface (listes, formulaires des gabarits `ui/reference/*.html`) :
    # fil d'Ariane « Relevés bancaires › … », listes de choix, lecture des
    # champs. L'accès a déjà été contrôlé par `PartiduoUi::ExtensionHandler`
    # à partir du montage ; `Bankimport::Api` vérifie encore la permission de
    # chaque commande.
    abstract class Handler < PartiduoUi::ReferenceHandler
      alias Api = Bankimport::Api
      alias Acc = Partiduo::Api::Accounting
      alias Form = PartiduoUi::Form
      alias Table = PartiduoUi::Table
      alias Screen = PartiduoUi::Screen

      def actor : Partiduo::Api::Actor
        current.actor
      end

      def crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("bankimport.menu.bankimport")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def settings_crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("core.menu.settings")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def can_import? : Bool
        can?(Api::IMPORT)
      end

      def can_admin? : Bool
        can?(Api::ADMIN)
      end

      @ledgers : Array(Acc::LedgerView)?

      # Journaux financiers ouverts à l'acteur.
      def ledgers : Array(Acc::LedgerView)
        @ledgers ||= begin
          Acc.ledgers(actor, Acc::LedgerKind::Financial, enabled_only: true)
        rescue Partiduo::Api::AccessDenied
          [] of Acc::LedgerView
        end
      end

      # --- Lecture des champs ---------------------------------------------------------

      def id_field(name : String) : Int64?
        field(name).to_i64?
      end

      def int_field(name : String) : Int32?
        field(name).to_i32?
      end

      def decimal_field(name : String) : BigDecimal?
        text = field(name)
        text.empty? ? nil : fmt.parse_decimal(text)
      end

      # Identifiants cochés (`ids`, répété).
      def checked_ids : Array(Int64)
        values = request.data.fetch_all("ids", [] of String) || [] of String
        values.compact_map(&.to_s.to_i64?).uniq!
      end

      # --- Listes de choix -------------------------------------------------------------

      def blank_option(label_key : String = "bankimport_ui.forms.none") : Form::Option
        option("", I18n.t(label_key))
      end

      def ledger_options(blank : Bool = false) : Array(Form::Option)
        list = ledgers.map { |ledger| option(ledger.id.to_s, "#{ledger.code} · #{ledger.name}") }
        blank ? [blank_option("bankimport_ui.forms.all_ledgers")] + list : list
      end

      def code_options(codes : Array(String), scope : String) : Array(Form::Option)
        codes.map { |code| option(code, I18n.t("#{scope}.#{code}")) }
      end

      def date_format_options : Array(Form::Option)
        Api::DATE_FORMATS.map { |code| option(code, Ui.date_format_label(code)) }
      end

      def choice_rows(options : Array(Form::Option), selected : String) : Array(Row)
        options.map { |item| Ui.row({"value" => item.value, "label" => item.label, "selected" => Ui.flag(item.value == selected)}) }
      end

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      # Redirection après une commande, avec le message du résultat.
      def after(result, success_key : String, url : String, params = {} of String => String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key, params)
        else
          flash["danger"] = messages(result)
        end
        go(url)
      end

      # Idem pour une commande qui rend un nombre de lignes (pluriel).
      def after_count(result, success_key : String, url : String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key, count: result.value!)
        else
          flash["danger"] = messages(result)
        end
        go(url)
      end

      # Retour sûr (`next`), à défaut l'adresse donnée.
      def back(default : String) : String
        PartiduoUi::Navigation.safe_path(field("next").presence || query("next").presence) || default
      end
    end

    # `/ext/BANKIMPORT/` : les lignes à traiter.
    class IndexHandler < Handler
      def get
        go(Ui.url("lines"))
      end
    end
  end
end

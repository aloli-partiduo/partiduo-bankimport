# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom (un
    # grand `Hash` n'est pas lu par les gabarits Marten, B-EINV-001 du cœur).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)
      getter children : Hash(String, Array(Row))

      def initialize(values : Hash(String, String) | Hash(String, String?), @children = {} of String => Array(Row))
        @values = values.transform_values(&.as(String?))
      end

      def resolve_template_attribute(key : String)
        if list = children[key]?
          list.empty? ? nil : list
        else
          values[key]?
        end
      end
    end

    def self.row(values : Hash(String, String) | Hash(String, String?), children = {} of String => Array(Row)) : Row
      Row.new(values, children)
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("bankimport:#{name}", **params)
    end

    def self.flag(value : Bool) : String?
      value ? "1" : nil
    end

    # Horodatage du contrat (UTC) présenté dans le fuseau du dossier
    # (`Partiduo::Api::Core.time_zone`) : date de la langue et heure. Un
    # import fait le 13 octobre à 0 h 30 à Paris n'apparaît pas au 12.
    def self.stamp(fmt : PartiduoUi::Format, value : Time) : String
      fmt.datetime(value, Partiduo::Api::Core.time_zone)
    end

    # Format de date affiché dans la langue (`dd/mm/yyyy` → `JJ/MM/AAAA`).
    def self.date_format_label(code : String) : String
      day, month, year = I18n.t("bankimport_ui.date_letters").split(',')
      code.gsub("dd", day * 2).gsub("mm", month * 2).gsub("yyyy", year * 4).gsub("yy", year * 2)
    end

    # Classe Bulma du statut d'une ligne.
    def self.status_class(status : String) : String
      case status
      when "transferred" then "is-success"
      when "duplicate"   then "is-warning"
      when "discarded"   then "is-light"
      else                    "is-info"
      end
    end

    # Présentation des vues du contrat (interne à l'interface).
    module Present
      alias Api = Bankimport::Api

      def self.line(view : Api::LineView, fmt : PartiduoUi::Format, can_import : Bool) : Row
        counterpart = if !view.card_code.empty?
                        [view.card_code, view.card_name].compact.join(" · ")
                      elsif !view.account.empty?
                        [view.account, view.account_label].compact.join(" · ")
                      end
        Ui.row({
          "id"           => view.id.to_s,
          "date"         => fmt.date(view.date),
          "iso_date"     => view.date.to_s("%Y-%m-%d"),
          "amount"       => fmt.amount(view.amount),
          "direction"    => view.inflow? ? "in" : "out",
          "label"        => view.label,
          "extra"        => view.extra.presence,
          "reference"    => view.reference.presence,
          "counterparty" => view.counterparty.presence,
          "status"       => view.status,
          "status_label" => I18n.t(view.status_key),
          "status_class" => Ui.status_class(view.status),
          "pending"      => Ui.flag(view.pending?),
          "ready"        => Ui.flag(view.ready?),
          "card_code"    => view.card_code,
          "account"      => view.account,
          "counterpart"  => counterpart,
          "from_rule"    => Ui.flag(!view.rule_id.nil?),
          "matched"      => Ui.flag(!view.match_line_id.nil?),
          "recorded"     => Ui.flag(!view.recorded_entry_id.nil?),
          "reversed"     => Ui.flag(!view.reversed_entry_id.nil?),
          "error"        => view.error.try { |error| fmt.message(error) },
          "entry_id"     => view.entry_id.try(&.to_s),
          "entry_url"    => view.entry_id.try { |id| Marten.routes.reverse("accounting:entry", id: id) },
          "update_url"   => Ui.url("line", id: view.id),
          "clear_url"    => Ui.url("line_clear", id: view.id),
          "import_url"   => Ui.url("import_detail", id: view.import_id),
          "can_import"   => Ui.flag(can_import && view.pending?),
          "selectable"   => Ui.flag(can_import && view.status != "transferred"),
        })
      end

      def self.import(view : Api::ImportView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "id"          => view.id.to_s,
          "url"         => Ui.url("import_detail", id: view.id),
          "filename"    => view.filename,
          "kind"        => I18n.t(view.kind_key),
          "ledger"      => view.ledger_code,
          "created"     => Ui.stamp(fmt, view.created_at),
          "period"      => view.first_date.try { |first| "#{fmt.date(first)} – #{fmt.date(view.last_date)}" },
          "lines"       => view.line_count.to_s,
          "pending"     => view.pending_count.to_s,
          "transferred" => view.transferred_count.to_s,
          "duplicates"  => view.duplicate_count.to_s,
          "reconciled"  => Ui.flag(view.reconciled?),
          "statement"   => view.statement_reference.presence,
        })
      end
    end
  end
end

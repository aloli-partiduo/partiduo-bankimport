# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Ui
    # `/ext/BANKIMPORT/formats` : formats CSV par établissement
    # (`bankimport.admin`, D-BKI-002).
    class FormatsHandler < Handler
      def get
        columns = [
          Table::Column.new("name", I18n.t("bankimport_ui.formats.name")),
          Table::Column.new("institution", I18n.t("bankimport_ui.formats.institution")),
          Table::Column.new("separator", I18n.t("bankimport_ui.formats.separator"), secondary: true),
          Table::Column.new("date_format", I18n.t("bankimport_ui.formats.date_format"), "mono", secondary: true),
          Table::Column.new("amount", I18n.t("bankimport_ui.formats.amount_mode"), secondary: true),
          Table::Column.new("imports", I18n.t("bankimport_ui.formats.imports"), "number"),
        ]
        rows = Api.formats(actor).map do |view|
          url = Ui.url("format_edit", id: view.id)
          mode = view.amount_column ? "bankimport_ui.formats.mode_signed" : "bankimport_ui.formats.mode_split"
          Table::Row.new([
            Table::Cell.new(view.name, url),
            Table::Cell.new(view.institution),
            Table::Cell.new(I18n.t("bankimport.separators.#{view.separator}")),
            Table::Cell.new(Ui.date_format_label(view.date_format)),
            Table::Cell.new(I18n.t(mode)),
            Table::Cell.new(view.import_count.to_s, sort: BigDecimal.new(view.import_count)),
          ])
        end
        table = Table.new(I18n.t("bankimport.menu.bankimport_formats"), columns, rows, Ui.url("formats"),
          empty_message: I18n.t("bankimport_ui.formats.none"), id: "bki-formats")
        list_page(I18n.t("bankimport.menu.bankimport_formats"), table,
          settings_crumbs({I18n.t("bankimport.menu.bankimport_formats"), nil}), "bankimport_ui.formats.csv_name",
          [link_action("bankimport_ui.formats.new", Ui.url("format_new"), "primary", "plus")],
          intro: I18n.t("bankimport_ui.formats.intro"))
      end
    end

    # Formulaire d'un format CSV (création, modification).
    abstract class FormatScreen < Handler
      COLUMNS = %w[date_column label_column amount_column debit_column credit_column extra_column reference_column
        counterparty_column iban_column]
      FIELDS = %w[name institution ledger_id separator encoding skip_lines date_format decimal_separator thousands_separator
        negate] + COLUMNS

      def values_of(view : Api::FormatView?) : Hash(String, String)
        unless view
          return {"separator" => "semicolon", "encoding" => "utf-8", "skip_lines" => "1", "date_format" => "dd/mm/yyyy",
                  "decimal_separator" => "comma", "thousands_separator" => "none", "date_column" => "1",
                  "label_column" => "2", "amount_column" => "3"}
        end
        {
          "name" => view.name, "institution" => view.institution, "ledger_id" => view.ledger_id.to_s,
          "separator" => view.separator, "encoding" => view.encoding, "skip_lines" => view.skip_lines.to_s,
          "date_format" => view.date_format, "decimal_separator" => view.decimal_separator,
          "thousands_separator" => view.thousands_separator, "negate" => view.negate ? "1" : "",
          "date_column" => view.date_column.to_s, "label_column" => view.label_column.to_s,
          "amount_column" => view.amount_column.to_s, "debit_column" => view.debit_column.to_s,
          "credit_column" => view.credit_column.to_s, "extra_column" => view.extra_column.to_s,
          "reference_column" => view.reference_column.to_s, "counterparty_column" => view.counterparty_column.to_s,
          "iban_column" => view.iban_column.to_s,
        }
      end

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name)} }
      end

      def format_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        general = [
          Form::Field.new("name", I18n.t("bankimport_ui.formats.name"), value: value.call("name"), required: true, maxlength: 100),
          Form::Field.new("institution", I18n.t("bankimport_ui.formats.institution"), value: value.call("institution"), maxlength: 100),
          Form::Field.new("ledger_id", I18n.t("bankimport_ui.formats.ledger"), "select", value.call("ledger_id"),
            options: [blank_option] + ledger_options, help: I18n.t("bankimport_ui.formats.ledger_help")),
        ]
        reading = [
          Form::Field.new("separator", I18n.t("bankimport_ui.formats.separator"), "select", value.call("separator"),
            options: code_options(Api::SEPARATORS, "bankimport.separators"), required: true),
          Form::Field.new("encoding", I18n.t("bankimport_ui.formats.encoding"), "select", value.call("encoding"),
            options: code_options(Api::ENCODINGS, "bankimport.encodings"), required: true),
          Form::Field.new("skip_lines", I18n.t("bankimport_ui.formats.skip_lines"), "number", value.call("skip_lines"),
            mono: true, help: I18n.t("bankimport_ui.formats.skip_lines_help")),
          Form::Field.new("date_format", I18n.t("bankimport_ui.formats.date_format"), "select", value.call("date_format"),
            options: date_format_options, required: true),
          Form::Field.new("decimal_separator", I18n.t("bankimport_ui.formats.decimal_separator"), "select",
            value.call("decimal_separator"), options: code_options(Api::DECIMAL_SEPARATORS, "bankimport.decimal_separators")),
          Form::Field.new("thousands_separator", I18n.t("bankimport_ui.formats.thousands_separator"), "select",
            value.call("thousands_separator"), options: code_options(Api::THOUSANDS_SEPARATORS, "bankimport.thousands_separators")),
          Form::Field.new("negate", I18n.t("bankimport_ui.formats.negate"), "checkbox", value.call("negate")),
        ]
        columns = COLUMNS.map do |name|
          Form::Field.new(name, I18n.t("bankimport_ui.formats.columns.#{name}"), "number", value.call(name), mono: true,
            required: name.in?("date_column", "label_column"))
        end
        Form.new([Form::Group.new(nil, general), Form::Group.new(I18n.t("bankimport_ui.formats.reading"), reading),
                  Form::Group.new(I18n.t("bankimport_ui.formats.columns_legend"), columns)])
      end

      def read_input(form : Form) : Api::FormatInput?
        columns = COLUMNS.to_h do |name|
          text = field(name)
          number = text.empty? ? nil : text.to_i32?
          form.add_error(name, I18n.t("ui.forms.invalid_integer")) if number.nil? && !text.empty?
          {name, number}
        end
        skip = int_field("skip_lines")
        form.add_error("skip_lines", I18n.t("ui.forms.invalid_integer")) if skip.nil? && !field("skip_lines").empty?
        form.add_error("date_column", I18n.t("bankimport_ui.formats.column_required")) if columns["date_column"].nil?
        form.add_error("label_column", I18n.t("bankimport_ui.formats.column_required")) if columns["label_column"].nil?
        date_column, label_column = columns["date_column"], columns["label_column"]
        return if form.invalid || date_column.nil? || label_column.nil?
        Api::FormatInput.new(name: field("name"), institution: field("institution"), ledger_id: id_field("ledger_id"),
          separator: field("separator"), encoding: field("encoding"), skip_lines: skip || 0,
          date_format: field("date_format"), decimal_separator: field("decimal_separator"),
          thousands_separator: field("thousands_separator"), negate: field("negate") == "1",
          date_column: date_column, label_column: label_column,
          amount_column: columns["amount_column"], debit_column: columns["debit_column"],
          credit_column: columns["credit_column"], extra_column: columns["extra_column"],
          reference_column: columns["reference_column"], counterparty_column: columns["counterparty_column"],
          iban_column: columns["iban_column"])
      end

      def format_crumbs(title : String) : Array(Screen::Crumb)
        settings_crumbs({I18n.t("bankimport.menu.bankimport_formats"), Ui.url("formats")}, {title, nil})
      end
    end

    class FormatNewHandler < FormatScreen
      def get
        show(format_form(values_of(nil)))
      end

      def post
        form = format_form(submitted)
        if input = read_input(form)
          result = Api.create_format(actor, input)
          if result.success?
            flash["success"] = I18n.t("bankimport_ui.flash.saved")
            return go(Ui.url("formats"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("bankimport_ui.formats.new")
        form_page(title, format_crumbs(title), form, Ui.url("format_new"), I18n.t("ui.forms.create"), Ui.url("formats"),
          intro: I18n.t("bankimport_ui.formats.form_intro"))
      end
    end

    class FormatEditHandler < FormatScreen
      def get
        view = Api.format(actor, id_param)
        show(view, format_form(values_of(view)))
      end

      def post
        view = Api.format(actor, id_param)
        form = format_form(submitted)
        if input = read_input(form)
          result = Api.update_format(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("bankimport_ui.flash.saved")
            return go(Ui.url("formats"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::FormatView, form : Form) : Marten::HTTP::Response
        actions = [post_action("bankimport_ui.formats.delete", Ui.url("format_delete", id: view.id),
          "bankimport_ui.formats.delete_confirm", "danger", "x")]
        form_page(view.name, format_crumbs(view.name), form, Ui.url("format_edit", id: view.id), I18n.t("ui.forms.save"),
          Ui.url("formats"), actions, intro: I18n.t("bankimport_ui.formats.form_intro"))
      end
    end

    class FormatDeleteHandler < Handler
      def get
        go(Ui.url("formats"))
      end

      def post
        after(Api.delete_format(actor, id_param), "bankimport_ui.flash.deleted", Ui.url("formats"))
      end
    end

    # `/ext/BANKIMPORT/rules` : règles de catégorisation (`bankimport.admin`,
    # D-BKI-006), saisies ou apprises, dans leur ordre d'essai.
    class RulesHandler < Handler
      def get
        columns = [
          Table::Column.new("position", I18n.t("bankimport_ui.rules.position"), "number"),
          Table::Column.new("label", I18n.t("bankimport_ui.rules.label_contains")),
          Table::Column.new("amount", I18n.t("bankimport_ui.rules.amount"), "number"),
          Table::Column.new("direction", I18n.t("bankimport_ui.rules.direction"), secondary: true),
          Table::Column.new("target", I18n.t("bankimport_ui.rules.target")),
          Table::Column.new("payee", I18n.t("bankimport_ui.rules.payee"), secondary: true),
          Table::Column.new("origin", I18n.t("bankimport_ui.rules.origin"), secondary: true),
          Table::Column.new("hits", I18n.t("bankimport_ui.rules.hits"), "number"),
        ]
        rows = Api.rules(actor).map do |view|
          url = Ui.url("rule_edit", id: view.id)
          origin = I18n.t(view.learned ? "bankimport_ui.rules.learned" : "bankimport_ui.rules.manual")
          Table::Row.new([
            Table::Cell.new(view.position.to_s, sort: BigDecimal.new(view.position)),
            Table::Cell.new(view.label_contains.presence || "—", url),
            Table::Cell.new(view.amount.try { |amount| fmt.amount(amount) } || "", sort: view.amount || BigDecimal.new(0)),
            Table::Cell.new(I18n.t(view.direction_key)),
            Table::Cell.new(view.card_code.presence || view.account, tag: view.active ? nil : I18n.t("bankimport_ui.rules.inactive")),
            Table::Cell.new(view.payee),
            Table::Cell.new(origin),
            Table::Cell.new(view.hits.to_s, sort: BigDecimal.new(view.hits)),
          ], view.active ? "" : "pd-muted")
        end
        table = Table.new(I18n.t("bankimport.menu.bankimport_rules"), columns, rows, Ui.url("rules"),
          empty_message: I18n.t("bankimport_ui.rules.none"), id: "bki-rules")
        list_page(I18n.t("bankimport.menu.bankimport_rules"), table,
          settings_crumbs({I18n.t("bankimport.menu.bankimport_rules"), nil}), "bankimport_ui.rules.csv_name",
          [link_action("bankimport_ui.rules.new", Ui.url("rule_new"), "primary", "plus")],
          intro: I18n.t("bankimport_ui.rules.intro"))
      end
    end

    abstract class RuleScreen < Handler
      FIELDS = %w[label_contains amount direction card_code account payee ledger_id position active]

      def values_of(view : Api::RuleView?) : Hash(String, String)
        return {"direction" => "any", "position" => "100", "active" => "1"} unless view
        {
          "label_contains" => view.label_contains, "amount" => view.amount.try { |amount| fmt.input_number(amount) } || "",
          "direction" => view.direction, "card_code" => view.card_code, "account" => view.account, "payee" => view.payee,
          "ledger_id" => view.ledger_id.to_s, "position" => view.position.to_s, "active" => view.active ? "1" : "",
        }
      end

      def submitted : Hash(String, String)
        FIELDS.to_h { |name| {name, field(name)} }
      end

      def rule_form(values : Hash(String, String)) : Form
        value = ->(name : String) { values[name]? || "" }
        conditions = [
          Form::Field.new("label_contains", I18n.t("bankimport_ui.rules.label_contains"), value: value.call("label_contains"),
            maxlength: 120, wide: true, help: I18n.t("bankimport_ui.rules.label_contains_help")),
          Form::Field.new("amount", I18n.t("bankimport_ui.rules.amount"), value: value.call("amount"), mono: true,
            help: I18n.t("bankimport_ui.rules.amount_help")),
          Form::Field.new("direction", I18n.t("bankimport_ui.rules.direction"), "select", value.call("direction"),
            options: code_options(Api::DIRECTIONS, "bankimport.directions")),
          Form::Field.new("ledger_id", I18n.t("bankimport_ui.rules.ledger"), "select", value.call("ledger_id"),
            options: ledger_options(blank: true)),
        ]
        target = [
          Form::Field.new("card_code", I18n.t("bankimport_ui.rules.card_code"), value: value.call("card_code"), mono: true,
            maxlength: 64, help: I18n.t("bankimport_ui.rules.target_help")),
          Form::Field.new("account", I18n.t("bankimport_ui.rules.account"), value: value.call("account"), mono: true, maxlength: 40),
          Form::Field.new("payee", I18n.t("bankimport_ui.rules.payee"), value: value.call("payee"), maxlength: 120,
            help: I18n.t("bankimport_ui.rules.payee_help")),
          Form::Field.new("position", I18n.t("bankimport_ui.rules.position"), "number", value.call("position"), mono: true),
          Form::Field.new("active", I18n.t("bankimport_ui.rules.active"), "checkbox", value.call("active")),
        ]
        Form.new([Form::Group.new(I18n.t("bankimport_ui.rules.conditions"), conditions),
                  Form::Group.new(I18n.t("bankimport_ui.rules.then"), target)])
      end

      def read_input(form : Form) : Api::RuleInput?
        amount = decimal_field("amount")
        form.add_error("amount", I18n.t("ui.forms.invalid_number")) if amount.nil? && !field("amount").empty?
        position = int_field("position")
        form.add_error("position", I18n.t("ui.forms.invalid_integer")) if position.nil? && !field("position").empty?
        return if form.invalid
        Api::RuleInput.new(label_contains: field("label_contains"), amount: amount, direction: field("direction"),
          card_code: field("card_code"), account: field("account"), ledger_id: id_field("ledger_id"),
          position: position || 100, active: field("active") == "1", payee: field("payee"))
      end

      def rule_crumbs(title : String) : Array(Screen::Crumb)
        settings_crumbs({I18n.t("bankimport.menu.bankimport_rules"), Ui.url("rules")}, {title, nil})
      end
    end

    class RuleNewHandler < RuleScreen
      def get
        show(rule_form(values_of(nil)))
      end

      def post
        form = rule_form(submitted)
        if input = read_input(form)
          result = Api.create_rule(actor, input)
          if result.success?
            flash["success"] = I18n.t("bankimport_ui.flash.saved")
            return go(Ui.url("rules"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("bankimport_ui.rules.new")
        form_page(title, rule_crumbs(title), form, Ui.url("rule_new"), I18n.t("ui.forms.create"), Ui.url("rules"))
      end
    end

    class RuleEditHandler < RuleScreen
      def get
        view = Api.rule(actor, id_param)
        show(view, rule_form(values_of(view)))
      end

      def post
        view = Api.rule(actor, id_param)
        form = rule_form(submitted)
        if input = read_input(form)
          result = Api.update_rule(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("bankimport_ui.flash.saved")
            return go(Ui.url("rules"))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::RuleView, form : Form) : Marten::HTTP::Response
        title = view.label_contains.presence || I18n.t("bankimport_ui.rules.untitled")
        actions = [post_action("bankimport_ui.rules.delete", Ui.url("rule_delete", id: view.id), "bankimport_ui.rules.delete_confirm",
          "danger", "x")]
        form_page(title, rule_crumbs(title), form, Ui.url("rule_edit", id: view.id), I18n.t("ui.forms.save"), Ui.url("rules"), actions)
      end
    end

    class RuleDeleteHandler < Handler
      def get
        go(Ui.url("rules"))
      end

      def post
        after(Api.delete_rule(actor, id_param), "bankimport_ui.flash.deleted", Ui.url("rules"))
      end
    end
  end
end

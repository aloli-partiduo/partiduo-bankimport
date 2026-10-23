# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Bankimport::SpecSupport
private alias Api = Bankimport::Api

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension BANKIMPORT : manifeste et activation (ADR-003 D2, ADR-011 D6)" do
  it "déclare une extension conforme au contrat du cœur, qui dépend de la Comptabilité" do
    manifest = Partiduo::Modules[Bankimport::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Bankimport::VERSION)
    Bankimport::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
    manifest.requires_core.should eq("~> 0.1")
    manifest.permissions.should eq(["bankimport.read", "bankimport.import", "bankimport.admin"])
    manifest.depends_on.should eq(["ACCOUNTING"])
    manifest.subscribed_events.should eq(["entry.cancelled"])
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route} }.should eq([
      {"BANKIMPORT", nil, nil},
      {"BANKIMPORT_IMPORT", "BANKIMPORT", "bankimport:import"},
      {"BANKIMPORT_LINES", "BANKIMPORT", "bankimport:lines"},
      {"BANKIMPORT_HISTORY", "BANKIMPORT", "bankimport:imports"},
      {"BANKIMPORT_FORMATS", "SETTINGS", "bankimport:formats"},
      {"BANKIMPORT_RULES", "SETTINGS", "bankimport:rules"},
    ])
    Partiduo::Modules.structure_errors.should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Bankimport::CODE, "ACCOUNTING"}).should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Bankimport::CODE}).should eq(["BANKIMPORT requiert ACCOUNTING, inactif"])
  end

  it "traduit son nom, ses permissions et ses menus dans chaque langue livrée" do
    manifest = Partiduo::Modules[Bankimport::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| I18n.t(key).should_not contain("missing") }
      end
    end
    I18n.with_locale("fr") { I18n.t("bankimport.menu.bankimport").should eq("Relevés bancaires") }
  end

  it "est inactive tant que l'instance ne l'active pas, puis se montre au menu « Relevés bancaires »" do
    PartiduoUi::Reference.provision
    S.user("alice@example.com", "Alice")
    S.user("bruno@example.com", "Bruno")
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.formats(S.reader) }
    Api.tile(S.reader).should be_nil
    Api.pending_count(S.reader).should be_nil
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("bankimport:lines")

    S.activate
    Partiduo::Modules.check!
    section = Partiduo::Api::Modules.menu(S.reader).find! { |item| item.code == "BANKIMPORT" }
    section.label_key.should eq("bankimport.menu.bankimport")
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should contain("bankimport:lines")
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("bankimport:import")
    menu_routes(Partiduo::Api::Modules.menu(S.accountant)).should contain("bankimport:formats")
  end

  it "range ses tables sous le préfixe bankimport_ et refuse en base les valeurs hors domaine" do
    [Bankimport::CsvFormat, Bankimport::Import, Bankimport::Line, Bankimport::Rule].map(&.db_table)
      .should eq(%w[bankimport_csv_format bankimport_import bankimport_line bankimport_rule])
    S.setup
    sql_error = ->(sql : String) do
      Marten::DB::Connection.default.open(&.exec(sql))
      nil
  rescue ex : PQ::PQError
    ex.message
    end
    sql_error.call("INSERT INTO bankimport_csv_format (name, institution, separator, encoding, skip_lines, date_format, " \
                   "decimal_separator, thousands_separator, date_column, label_column, negate, created_at, updated_at) " \
                   "VALUES ('X', '', 'semicolon', 'utf-8', 1, 'dd/mm/yyyy', 'comma', 'none', 1, 2, FALSE, now(), now())")
      .to_s.should contain("bankimport_csv_format_amount_check")
    sql_error.call("INSERT INTO bankimport_rule (label_contains, direction, card_code, account, position, active, learned, hits, " \
                   "created_at, updated_at) VALUES ('', 'any', '', '627', 1, TRUE, FALSE, 0, now(), now())")
      .to_s.should contain("bankimport_rule_condition_check")
    sql_error.call("INSERT INTO bankimport_rule (label_contains, direction, card_code, account, position, active, learned, hits, " \
                   "created_at, updated_at) VALUES ('EDF', 'any', 'EDF', '627', 1, TRUE, FALSE, 0, now(), now())")
      .to_s.should contain("bankimport_rule_target_check")
    format = S.split_format
    view = S.import("banque-du-centre.csv", format.id)
    sql_error.call("UPDATE bankimport_line SET status = 'transferred' WHERE import_id = #{view.id}")
      .to_s.should contain("bankimport_line_transferred_check")
    sql_error.call("UPDATE bankimport_line SET amount = 0 WHERE import_id = #{view.id}").to_s.should contain("bankimport_line_amount_check")
    sql_error.call("UPDATE bankimport_import SET kind = 'coda' WHERE id = #{view.id}").to_s.should contain("bankimport_import_kind_check")
  end
end

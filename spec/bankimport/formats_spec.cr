# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Bankimport::SpecSupport
private alias Api = Bankimport::Api

describe "Formats CSV par établissement (D-BKI-002)" do
  it "enregistre la correspondance des colonnes d'un établissement" do
    S.setup
    view = S.split_format
    view.name.should eq("Banque du Centre")
    view.amount_column.should be_nil
    {view.debit_column, view.credit_column, view.reference_column}.should eq({3, 4, 5})
    view.encoding.should eq("windows-1252")
    view.ledger_id.should eq(S.bank.id)
    Api.formats(S.reader).map(&.name).should eq(["Banque du Centre"])

    updated = Api.update_format(S.accountant, view.id, Api::FormatInput.new(name: "Banque du Centre (pro)", date_column: 1,
      label_column: 2, amount_column: 3, skip_lines: 2)).value!
    updated.name.should eq("Banque du Centre (pro)")
    updated.amount_column.should eq(3)
    updated.debit_column.should be_nil
  end

  it "refuse un format incomplet ou incohérent, avec ses erreurs par champ" do
    S.setup
    S.split_format
    result = Api.create_format(S.accountant, Api::FormatInput.new(name: "banque du centre", date_column: 1, label_column: 1,
      separator: "virgule", skip_lines: 60, decimal_separator: "dot", thousands_separator: "dot", ledger_id: 999_999_i64))
    result.failure?.should be_true
    result.error_keys.should contain("bankimport.errors.format.name.taken")
    result.error_keys.should contain("bankimport.errors.choice.invalid")
    result.error_keys.should contain("bankimport.errors.format.skip_lines.range")
    result.error_keys.should contain("bankimport.errors.format.thousands_separator.same")
    result.error_keys.should contain("bankimport.errors.format.amount_column.blank")
    result.error_keys.should contain("bankimport.errors.format.column.repeated")
    result.error_keys.should contain("bankimport.errors.ledger.invalid")

    both = Api.check_format(S.accountant, Api::FormatInput.new(name: "B", date_column: 1, label_column: 2, amount_column: 3,
      debit_column: 4, credit_column: 5))
    both.error_keys.should eq(["bankimport.errors.format.amount_column.both"])
    range = Api.check_format(S.accountant, Api::FormatInput.new(name: "B", date_column: 0, label_column: 2, amount_column: 99))
    range.errors_for("date_column").map(&.key).should eq(["bankimport.errors.format.column.range"])
    range.errors_for("amount_column").map(&.key).should eq(["bankimport.errors.format.column.range"])
  end

  it "découpe un fichier d'exemple pour régler les colonnes" do
    S.setup
    rows = Api.sample(S.reader, S.fixture("banque-du-centre.csv"), "semicolon", "windows-1252")
    rows.first.should eq(["Date", "Libellé", "Débit", "Crédit", "Référence"])
    rows[1][1].should eq("PRLV SEPA EDF CLIENTS PARTICULIERS 123456")
    Api.sample(S.reader, S.fixture("banque-du-centre.csv"), "virgule", "utf-8").should be_empty
  end

  it "supprime un format : les imports qui l'ont employé restent" do
    S.setup
    format = S.split_format
    view = S.import("banque-du-centre.csv", format.id)
    Api.delete_format(S.accountant, format.id).success?.should be_true
    Api.formats(S.accountant).should be_empty
    imported = Api.import_detail(S.accountant, view.id)
    imported.format_id.should be_nil
    imported.line_count.should eq(6)
  end
end

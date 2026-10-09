# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Bankimport::SpecSupport
private alias Api = Bankimport::Api

describe "Règles de catégorisation (D-BKI-006)" do
  it "propose une contrepartie aux lignes importées, sans rien passer en comptabilité" do
    S.setup
    S.card("SUPPLIER", "Électricité de France", "EDF")
    edf = Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "edf", direction: "out", card_code: "edf")).value!
    edf.card_code.should eq("EDF")
    Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "Frais tenue", account: "627"))
    Api.create_rule(S.accountant, Api::RuleInput.new(amount: S.d("4"), direction: "out", account: "627", position: 50))
    view = S.import("banque-du-centre.csv", S.split_format.id)
    lines = S.pending(view.id).index_by(&.label)
    lines["PRLV SEPA EDF CLIENTS PARTICULIERS 123456"].card_code.should eq("EDF")
    lines["PRLV SEPA EDF CLIENTS PARTICULIERS 123456"].card_name.should eq("Électricité de France")
    lines["PRLV SEPA EDF CLIENTS PARTICULIERS 123456"].rule_id.should eq(edf.id)
    lines["FRAIS TENUE DE COMPTE"].account.should eq("627")
    lines["FRAIS TENUE DE COMPTE"].account_label.should eq("Services bancaires et assimilés")
    lines[%(COTISATION CARTE "PRO" ÉPARGNE)].account.should eq("627")
    lines["VIR SEPA RECU MENUISERIE LEROUX FACT 2026-041"].ready?.should be_false
    lines.values.count(&.ready?).should eq(3)
    lines.values.all?(&.pending?).should be_true
    Api.rule(S.reader, edf.id).hits.should eq(1)
    present(Api.tile(S.reader)).ready_count.should eq(3)
  end

  it "compare sans majuscules ni accents, selon le sens et le journal" do
    S.setup
    Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "cafe de la gare", direction: "in", account: "627"))
    Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "TÉLÉPHONE", account: "627"))
    view = S.import("neobanque.csv", S.signed_format.id)
    lines = S.pending(view.id).index_by(&.label)
    lines["Café de la Gare"].ready?.should be_false
    lines["Abonnement Téléphone"].account.should eq("627")
  end

  it "apprend une règle du choix de l'utilisateur et l'applique aux lignes semblables" do
    S.setup
    S.card("SUPPLIER", "Carrefour", "CARREFOUR")
    view = S.import("banque-du-centre.csv", S.split_format.id)
    first, second = S.pending(view.id).select(&.label.==("CB CARREFOUR 04/09"))
    chosen = Api.set_counterpart(S.importer, first.id, Api::CounterpartInput.new(card_code: "carrefour")).value!
    chosen.card_code.should eq("CARREFOUR")
    chosen.ready?.should be_true
    rule = Api.rules(S.reader).find!(&.learned)
    {rule.label_contains, rule.direction, rule.card_code, rule.amount}.should eq({"CB CARREFOUR", "out", "CARREFOUR", nil})

    Api.apply_rules(S.importer).value!.should eq(1)
    Api.line(S.reader, second.id).card_code.should eq("CARREFOUR")
    Api.line(S.reader, second.id).rule_id.should eq(rule.id)

    # Un nouveau choix met à jour la règle apprise ; « Mémoriser » décoché n'apprend rien.
    Api.set_counterpart(S.importer, first.id, Api::CounterpartInput.new(account: "627")).value!
    Api.rules(S.reader).select(&.learned).map { |item| {item.label_contains, item.account} }.should eq([{"CB CARREFOUR", "627"}])
    edf = S.line("PRLV SEPA EDF")
    Api.set_counterpart(S.importer, edf.id, Api::CounterpartInput.new(account: "627", learn: false)).value!
    Api.rules(S.reader).size.should eq(1)
  end

  it "tire la clé d'une règle apprise des mots sans chiffre du libellé" do
    Bankimport::Categorizer.learned_key("PRLV SEPA EDF CLIENTS PARTICULIERS 123456").should eq("PRLV SEPA EDF CLIENTS")
    Bankimport::Categorizer.learned_key("CB Café 04/09 X").should eq("CB CAFE")
    Bankimport::Categorizer.learned_key("123 456").should eq("")
  end

  it "ne modifie jamais une règle saisie ; une règle apprise modifiée devient saisie" do
    S.setup
    manual = Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "FRAIS TENUE DE", direction: "out", account: "627")).value!
    view = S.import("banque-du-centre.csv", S.split_format.id)
    fees = S.pending(view.id).find! { |line| line.label == "FRAIS TENUE DE COMPTE" }
    Api.set_counterpart(S.importer, fees.id, Api::CounterpartInput.new(account: "627")).value!
    Api.rules(S.reader).map(&.id).should eq([manual.id])
    S.card("SUPPLIER", "Carrefour", "CARREFOUR")
    carrefour = S.pending(view.id).find!(&.label.starts_with?("CB CARREFOUR"))
    Api.set_counterpart(S.importer, carrefour.id, Api::CounterpartInput.new(card_code: "CARREFOUR")).value!
    learned = Api.rules(S.reader).find!(&.learned)
    updated = Api.update_rule(S.accountant, learned.id, Api::RuleInput.new(label_contains: "CARREFOUR", card_code: "CARREFOUR")).value!
    updated.learned.should be_false
    Api.delete_rule(S.accountant, updated.id).success?.should be_true
    Api.line(S.reader, carrefour.id).card_code.should eq("CARREFOUR")
  end

  it "refuse une règle sans condition, sans contrepartie ou avec une contrepartie inconnue" do
    S.setup
    keys = ->(input : Api::RuleInput) { Api.create_rule(S.accountant, input).error_keys }
    keys.call(Api::RuleInput.new(account: "627")).should eq(["bankimport.errors.rule.condition.blank"])
    keys.call(Api::RuleInput.new(label_contains: "X")).should eq(["bankimport.errors.counterpart.blank"])
    keys.call(Api::RuleInput.new(label_contains: "X", card_code: "EDF", account: "627")).should eq(["bankimport.errors.counterpart.both"])
    keys.call(Api::RuleInput.new(label_contains: "X", card_code: "INCONNU")).should eq(["bankimport.errors.counterpart.card_unknown"])
    keys.call(Api::RuleInput.new(label_contains: "X", account: "999999")).should eq(["bankimport.errors.counterpart.account_unknown"])
    keys.call(Api::RuleInput.new(label_contains: "X", account: "62")).should eq(["bankimport.errors.counterpart.account_not_direct"])
    keys.call(Api::RuleInput.new(amount: S.d("-4"), account: "627", direction: "sideways"))
      .should eq(["bankimport.errors.rule.amount.positive", "bankimport.errors.choice.invalid"])
    expect_raises(Partiduo::Api::Forbidden) { Api.create_rule(S.importer, Api::RuleInput.new(label_contains: "X", account: "627")) }
  end
end

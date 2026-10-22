# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Bankimport::SpecSupport
private alias Api = Bankimport::Api
private alias Acc = Partiduo::Api::Accounting
private alias P = Bankimport::Parsers

# Fiche fournisseur qui porte l'IBAN du cabinet Martin du relevé de virements.
private def martin_card : Partiduo::Api::Cards::CardView
  category = PartiduoUi::Reference.category("SUPPLIER")
  input = Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: "Cabinet Martin", code: "MARTIN",
    iban: "FR76 3000 4000 0312 3456 7890 143")
  Partiduo::Api::Cards.create_card(S.system, input).value!
end

# Ligne transférée contre le compte 627, puis son écriture extournée : la
# ligne est rendue à traiter (D-BKI-009). Rend la ligne et l'écriture
# extournée.
private def transferred_then_cancelled(label : String) : {Api::LineView, Int64}
  line = S.line(label)
  Api.set_counterpart(S.importer, line.id, Api::CounterpartInput.new(account: "627", learn: false)).value!
  entry_id = present(Api.transfer(S.importer, [line.id]).value!.transferred.first.entry_id)
  Acc.cancel_entry(S.accountant, Acc::CancelEntryInput.new(entry_id)).value!
  {Api.line(S.reader, line.id), entry_id}
end

# Second journal financier (livret), adossé à sa fiche Banque.
private def second_bank : Acc::LedgerView
  Acc.create_account(S.system, Acc::AccountInput.new(number: "510100", label: "Livret", parent: "51", direct_use: true)).value!
  category = Partiduo::Api::Cards.category_by_code(S.system, "BANK") || raise "catégorie BANK absente"
  card = Partiduo::Api::Cards.create_card(S.system, Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: "Livret"),
    account: "510100").value!
  Acc.create_ledger(S.system, Acc::LedgerInput.new(name: "Livret", kind: Acc::LedgerKind::Financial, bank_card: card.code,
    receipt_prefix: "L-", receipt_padding: 5)).value!
end

# Écriture du journal F01 passée hors de l'extension : `amount` signé pour la
# banque, contre le compte 627.
private def manual_entry(amount : String, day : String, ledger : Acc::LedgerView = S.bank) : Acc::EntryView
  input = Acc::FinancialInput.new(ledger_id: ledger.id, date: S.date(day),
    lines: [Acc::PaymentLineInput.new(S.d(amount), account: "627", label: "Saisie corrigée")], source: "spec:#{Random::Secure.hex(4)}")
  Acc.post_financial(S.accountant, input).value!.first
end

describe "Bénéficiaire des lignes et des règles (A-PER-2, D-BKI-012)" do
  it "lit le bénéficiaire des relevés : OFX NAME ou PAYEE, QIF P, colonne « tiers » d'un CSV" do
    ofx = P::OfxReader.parse(S.fixture("releve-virements.ofx"))
    ofx.lines.map(&.payee).should eq(["Cabinet Martin", "VIR SEPA COTISATION CLUB"])
    ofx.lines.first.label.should eq("Cabinet Martin")
    P::OfxReader.parse(S.fixture("releve.ofx")).lines.first.payee.should eq("PRLV SEPA EDF")
    P::QifReader.parse(S.fixture("releve.qif"), "dd/mm/yyyy").lines.map(&.payee)
      .should eq(["PRLV SEPA EDF", "MENUISERIE LEROUX", "FRAIS TENUE DE COMPTE"])
    csv = "Date;Libellé;Montant;Bénéficiaire;IBAN\n01/09/2026;VIR SEPA LOYER;-700,00;SCI Les Tilleuls;fr76 3000 4000 0312 3456 7890 143\n"
    settings = P::CsvSettings.new(date_column: 1, label_column: 2, amount_column: 3, counterparty_column: 4, iban_column: 5)
    line = P::CsvReader.parse(csv.to_slice, settings).lines.first
    {line.payee, line.iban}.should eq({"SCI Les Tilleuls", "FR7630004000031234567890143"})
  end

  it "pose le bénéficiaire d'une règle sur la ligne, cherche aussi dans le bénéficiaire, l'écrit dans l'écriture transférée" do
    S.setup
    rule = Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "edf", direction: "out", account: "603",
      payee: "  Électricité de France ")).value!
    rule.payee.should eq("Électricité de France")
    Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "cabinet martin", account: "641"))
    S.import("releve.ofx")
    edf = S.line("PRLV SEPA EDF")
    {edf.account, edf.payee, edf.rule_id}.should eq({"603", "Électricité de France", rule.id})
    S.line("CB CARREFOUR").payee.should eq("CB CARREFOUR")
    S.import("releve-virements.ofx")
    S.line("Cabinet Martin").account.should eq("641")

    entry_id = present(Api.transfer(S.importer, [edf.id]).value!.transferred.first.entry_id)
    Acc.entry(S.accountant, entry_id).label.should eq("Électricité de France · PRLV SEPA EDF")
    Api.lines_by_entry(S.reader, [entry_id, 999_999_i64]).transform_values(&.payee)
      .should eq({entry_id => "Électricité de France"})
    Api.lines(S.reader, Api::LineQuery.new(status: nil, search: "électricité")).map(&.id).should eq([edf.id])

    carrefour = S.line("CB CARREFOUR")
    Api.set_counterpart(S.importer, carrefour.id, Api::CounterpartInput.new(account: "627", learn: false)).value!
    other = present(Api.transfer(S.importer, [carrefour.id]).value!.transferred.first.entry_id)
    Acc.entry(S.accountant, other).label.should eq("CB CARREFOUR")
  end

  it "change le bénéficiaire d'une ligne et l'apprend avec la règle ; refuse un bénéficiaire trop long" do
    S.setup
    S.import("banque-du-centre.csv", S.split_format.id)
    first, second = S.pending.select(&.label.==("CB CARREFOUR 04/09"))
    chosen = Api.set_counterpart(S.importer, first.id, Api::CounterpartInput.new(account: "603", payee: "Carrefour Market")).value!
    chosen.payee.should eq("Carrefour Market")
    rule = Api.rules(S.reader).find!(&.learned)
    {rule.label_contains, rule.account, rule.payee}.should eq({"CB CARREFOUR", "603", "Carrefour Market"})
    Api.apply_rules(S.importer, [second.id]).value!.should eq(1)
    Api.line(S.reader, second.id).payee.should eq("Carrefour Market")

    kept = Api.set_counterpart(S.importer, second.id, Api::CounterpartInput.new(account: "627", learn: false)).value!
    kept.payee.should eq("Carrefour Market")
    cleared = Api.set_counterpart(S.importer, second.id, Api::CounterpartInput.new(account: "627", learn: false, payee: "")).value!
    cleared.payee.should eq("")
    Api.set_counterpart(S.importer, second.id, Api::CounterpartInput.new(account: "627", payee: "x" * 121))
      .error_keys.should eq(["bankimport.errors.payee.too_long"])
    Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "orange", account: "627", payee: "y" * 121))
      .error_keys.should eq(["bankimport.errors.payee.too_long"])
  end
end

describe "Fiche proposée par l'IBAN de la contrepartie (A-BKI-2, D-BKI-013)" do
  it "propose la fiche qui porte l'IBAN lu, à défaut de règle ; ignore un numéro de compte national" do
    S.setup
    martin_card
    S.import("releve-virements.ofx")
    martin = S.line("Cabinet Martin")
    {martin.iban, martin.card_code, martin.card_name, martin.rule_id}.should eq({"FR7630004000031234567890143", "MARTIN", "Cabinet Martin", nil})
    club = S.line("VIR SEPA COTISATION CLUB")
    {club.iban, club.card_code}.should eq({"", ""})
  end

  it "laisse la règle l'emporter sur l'IBAN" do
    S.setup
    martin_card
    Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "honoraires", account: "641"))
    S.import("releve-virements.ofx")
    S.line("Cabinet Martin").account.should eq("641")
  end

  it "ne propose rien à qui ne lit pas les fiches" do
    S.setup
    martin_card
    blind = S.actor("bruno@example.com", [Api::READ, Api::IMPORT] + S::CORE_PERMISSIONS - ["cards.card.read"])
    S.import("releve-virements.ofx", actor: blind)
    S.line("Cabinet Martin").card_code.should eq("")
  end
end

describe "Types des relevés conservés par le socle (A-BKI-1, D-BKI-014)" do
  it "conserve un OFX en application/x-ofx, un QIF en application/qif ; relit un relevé conservé en text/plain" do
    S.setup
    view = S.import("releve.ofx")
    reader = S.reader.copy_with(permissions: S.reader.permissions + Set{"core.attachment.read"})
    present(Api.import_content(reader, view.id))[1].should eq("application/x-ofx")

    old = Partiduo::Api::Core.store_attachment(S.accountant, Partiduo::Api::Core::AttachmentInput.new("ancien.qif",
      "text/plain", IO::Memory.new(S.fixture("releve.qif")))).value!
    Bankimport::Import.filter(id: view.id).update(attachment_id: old.id)
    filename, content_type, bytes = present(Api.import_content(reader, view.id))
    {filename, content_type}.should eq({"ancien.qif", "text/plain"})
    bytes.should eq(S.fixture("releve.qif"))
  end
end

describe "Ligne rattachée à l'écriture qui corrige la sienne (A-PER-3, D-BKI-015)" do
  it "rattache la ligne rendue à traiter à l'écriture qui corrige la sienne, sans nouvelle écriture" do
    S.setup
    S.import("releve.ofx")
    line, cancelled = transferred_then_cancelled("PRLV SEPA EDF")
    line.reversed_entry_id.should eq(cancelled)
    corrected = manual_entry("-84.20", "2026-09-01")
    relinked = Api.relink(S.importer, line.id, corrected.id).value!
    {relinked.status, relinked.entry_id, relinked.reversed_entry_id}.should eq({"transferred", corrected.id, cancelled})
    Api.lines_by_entry(S.reader, [corrected.id]).keys.should eq([corrected.id])
    count = Acc.entries(S.accountant, Acc::EntryQuery.new(ledger_id: S.bank.id)).size
    Api.transfer(S.importer, [line.id]).value!.transferred.should be_empty
    Acc.entries(S.accountant, Acc::EntryQuery.new(ledger_id: S.bank.id)).size.should eq(count)

    Acc.cancel_entry(S.accountant, Acc::CancelEntryInput.new(corrected.id)).value!
    Api.line(S.reader, line.id).reversed_entry_id.should eq(corrected.id)
  end

  it "rattache une ligne à l'écriture passée à la main qu'elle signale" do
    S.setup
    manual = manual_entry("-45.90", "2026-09-05")
    S.import("releve.ofx")
    flagged = S.pending.find! { |line| line.recorded_entry_id == manual.id }
    Api.relink(S.importer, flagged.id, manual.id).value!.status.should eq("transferred")
    other = S.pending.find! { |line| line.label == "CB CARREFOUR" }
    Api.relink(S.importer, other.id, manual.id).error_keys.should eq(["bankimport.errors.relink.entry_taken"])
  end

  it "refuse une écriture d'un autre journal, d'un autre montant, trop éloignée, extournée ou inconnue, et une ligne déjà transférée" do
    S.setup
    S.import("releve.ofx")
    line, cancelled = transferred_then_cancelled("PRLV SEPA EDF")
    check = ->(entry_id : Int64) { Api.relink(S.importer, line.id, entry_id).errors.map { |error| {error.field, error.key} } }
    check.call(cancelled).should eq([{"entry_id", "bankimport.errors.relink.entry_cancelled"}])
    check.call(manual_entry("-84.21", "2026-09-01").id).should eq([{"entry_id", "bankimport.errors.relink.amount"}])
    check.call(manual_entry("-84.20", "2026-10-05").id).should eq([{"entry_id", "bankimport.errors.relink.date"}])
    check.call(999_999_i64).should eq([{"entry_id", "bankimport.errors.relink.entry_unknown"}])
    check.call(manual_entry("-84.20", "2026-09-01", second_bank).id).should eq([{"entry_id", "bankimport.errors.relink.ledger"}])

    good = manual_entry("-84.20", "2026-09-02")
    Api.relink(S.importer, line.id, good.id).value!
    Api.relink(S.importer, line.id, good.id).error_keys.should eq(["bankimport.errors.line.not_pending"])
    expect_raises(Partiduo::Api::Forbidden) { Api.relink(S.reader, line.id, good.id) }
  end

  it "complète le relevé pointé de l'import avec l'extourne et la nouvelle écriture, sans le refaire" do
    S.setup
    view = S.import("releve.ofx")
    lines = S.pending(view.id)
    lines.each { |item| Api.set_counterpart(S.importer, item.id, Api::CounterpartInput.new(account: "627", learn: false)).value! }
    Api.transfer(S.importer, lines.map(&.id)).value!
    total = lines.sum(BigDecimal.new(0), &.amount)
    reconciled = Api.reconcile(S.importer, view.id, Api::ReconcileInput.new("RELEVE-09", S.d("1057.40") - total, S.d("1057.40"))).value!
    edf = S.line("PRLV SEPA EDF")
    old_entry = present(edf.entry_id)
    Acc.cancel_entry(S.accountant, Acc::CancelEntryInput.new(old_entry)).value!
    corrected = manual_entry("-84.20", "2026-09-01")
    Api.relink(S.importer, edf.id, corrected.id).value!

    detail = Api.import_detail(S.reader, view.id)
    detail.statement_reference.should eq("RELEVE-09")
    # Même relevé (contrat 0.18.0, `add_to_statement`) : identifiant gardé.
    detail.statement_id.should eq(reconciled.statement_id)
    statement = Acc.bank_statement(S.accountant, present(detail.statement_id))
    statement.statement.attachment_id.should eq(view.attachment_id)
    {statement.statement.start_balance, statement.statement.end_balance}.should eq({S.d("1057.40") - total, S.d("1057.40")})
    ids = statement.lines.map(&.entry_id)
    ids.should contain(corrected.id)
    ids.should contain(old_entry)
    ids.should contain(present(Acc.entry(S.accountant, old_entry).reversed_by_id))
    Acc.reconciliation(S.accountant, S.bank.id).unreconciled.should be_empty
  end
end

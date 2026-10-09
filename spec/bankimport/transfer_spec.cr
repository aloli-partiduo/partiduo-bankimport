# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Bankimport::SpecSupport
private alias Api = Bankimport::Api
private alias Acc = Partiduo::Api::Accounting

describe "Transfert vers le journal financier par le contrat de la Comptabilité (D-BKI-008)" do
  it "passe une écriture par ligne avec post_financial : banque contre contrepartie, pièce jointe de l'import" do
    S.setup
    S.card("SUPPLIER", "Électricité de France", "EDF")
    view = S.import("releve.ofx")
    edf = S.line("PRLV SEPA EDF")
    fees_input = Api::CounterpartInput.new(card_code: "EDF")
    Api.set_counterpart(S.importer, edf.id, fees_input).value!
    report = Api.transfer(S.importer, [edf.id]).value!
    report.failed.should be_empty
    line = report.transferred.first
    line.status.should eq("transferred")
    entry = Acc.entry(S.accountant, present(line.entry_id))
    entry.ledger_code.should eq("F01")
    entry.date.should eq(S.date("2026-09-01"))
    entry.source.should eq("bankimport:line:#{line.id}")
    entry.attachment_id.should eq(view.attachment_id)
    entry.label.should eq("PRLV SEPA EDF")
    supplier = entry.lines.find! { |item| item.card_code == "EDF" }
    {supplier.side, supplier.amount}.should eq({Acc::Side::Debit, S.d("84.20")})
    entry.lines.find! { |item| item.card_code != "EDF" }.side.should eq(Acc::Side::Credit)
    Api.import_detail(S.reader, view.id).transferred_count.should eq(1)
    Api.lines(S.reader).map(&.id).should_not contain(edf.id)
  end

  it "laisse à traiter une ligne sans contrepartie ou refusée par la Comptabilité, avec son erreur" do
    S.setup
    view = S.import("releve.ofx")
    lines = S.pending(view.id)
    fees = lines.find! { |line| line.label == "CB CARREFOUR" }
    Bankimport::Line.filter(id: fees.id).update(card_code: "DISPARU")
    report = Api.transfer(S.importer, lines.map(&.id)).value!
    report.transferred.should be_empty
    report.failed.size.should eq(4)
    refused = Api.line(S.reader, fees.id)
    refused.pending?.should be_true
    present(refused.error).key.should start_with("accounting.errors.")
    present(Api.line(S.reader, lines.first.id).error).key.should eq("bankimport.errors.counterpart.blank")
    Acc.entries(S.accountant, Acc::EntryQuery.new(ledger_id: S.bank.id)).should be_empty

    Api.set_counterpart(S.importer, fees.id, Api::CounterpartInput.new(account: "627")).value!.error.should be_nil
    Api.transfer(S.importer, [fees.id]).value!.transferred.size.should eq(1)
  end

  it "lettre l'encaissement avec la facture ouverte du client de même montant" do
    S.setup
    S.card("CUSTOMER", "Menuiserie Leroux", "LEROUX")
    sale = PartiduoUi::Books.sale("LEROUX", "1000", "2026-08-20")
    invoice_line = PartiduoUi::Books.line_of(sale, "LEROUX")
    S.import("releve.ofx")
    leroux = S.line("VIR MENUISERIE LEROUX")
    Api.open_items(S.reader.copy_with(permissions: S.reader.permissions + Set{"accounting.entry.read"}), leroux.id).should be_empty
    chosen = Api.set_counterpart(S.importer, leroux.id, Api::CounterpartInput.new(card_code: "LEROUX")).value!
    chosen.match_line_id.should eq(invoice_line.id)
    Api.open_items(S.importer, leroux.id).map(&.line_id).should eq([invoice_line.id])
    entry_id = present(Api.transfer(S.importer, [leroux.id]).value!.transferred.first.entry_id)
    entry = Acc.entry(S.accountant, entry_id)
    entry.lines.find! { |item| item.card_code == "LEROUX" }.matching_id.should_not be_nil
    Acc.entry(S.accountant, sale.id).lines.find! { |item| item.card_code == "LEROUX" }.matching_id.should_not be_nil

    other = S.line("PRLV SEPA EDF")
    Api.set_counterpart(S.importer, other.id, Api::CounterpartInput.new(account: "627", match_line_id: invoice_line.id))
      .error_keys.should eq(["bankimport.errors.line.match_invalid"])
  end

  it "rend la ligne à traiter quand son écriture est extournée (entry.cancelled)" do
    S.setup
    S.import("releve.ofx")
    fees = S.line("PRLV SEPA EDF")
    Api.set_counterpart(S.importer, fees.id, Api::CounterpartInput.new(account: "627")).value!
    entry_id = present(Api.transfer(S.importer, [fees.id]).value!.transferred.first.entry_id)
    Acc.cancel_entry(S.accountant, Acc::CancelEntryInput.new(entry_id)).success?.should be_true
    line = Api.line(S.reader, fees.id)
    line.pending?.should be_true
    line.entry_id.should be_nil
    line.reversed_entry_id.should eq(entry_id)
    line.account.should eq("627")
    Api.transfer(S.importer, [fees.id]).value!.transferred.size.should eq(1)
  end

  it "exige les droits de l'extension et ceux du cœur" do
    S.setup
    S.import("releve.ofx")
    fees = S.line("PRLV SEPA EDF")
    expect_raises(Partiduo::Api::Forbidden) { Api.set_counterpart(S.reader, fees.id, Api::CounterpartInput.new(account: "627")) }
    Api.set_counterpart(S.importer, fees.id, Api::CounterpartInput.new(account: "627")).value!
    expect_raises(Partiduo::Api::Forbidden) { Api.transfer(S.reader, [fees.id]) }
    no_post = S.actor("bruno@example.com", [Api::READ, Api::IMPORT, "accounting.ledger.read"])
    expect_raises(Partiduo::Api::Forbidden, /accounting.entry.post/) { Api.transfer(no_post, [fees.id]) }
    no_attachment = S.actor("bruno@example.com", [Api::READ, Api::IMPORT, "accounting.ledger.read"])
    expect_raises(Partiduo::Api::Forbidden, /core.attachment.write/) do
      Api.import_file(no_attachment, S.input("releve-v2.ofx"))
    end
    Api.line(S.reader, fees.id).pending?.should be_true
  end
end

describe "Pointage du relevé par le rapprochement de la Comptabilité (D-BKI-010)" do
  it "rattache les lignes transférées de l'import au relevé, soldes et fichier compris" do
    S.setup
    view = S.import("releve.ofx")
    lines = S.pending(view.id)
    lines.each { |line| Api.set_counterpart(S.importer, line.id, Api::CounterpartInput.new(account: "627", learn: false)).value! }
    Api.transfer(S.importer, lines.map(&.id)).value!.transferred.size.should eq(4)
    total = lines.sum(BigDecimal.new(0), &.amount)
    input = Api::ReconcileInput.new("RELEVE-2026-09", S.d("1057.40") - total, S.d("1057.40"))
    reconciled = Api.reconcile(S.importer, view.id, input).value!
    reconciled.reconciled?.should be_true
    reconciled.statement_reference.should eq("RELEVE-2026-09")
    statement = Acc.bank_statement(S.accountant, present(reconciled.statement_id))
    statement.statement.attachment_id.should eq(view.attachment_id)
    statement.lines.size.should eq(4)
    Acc.reconciliation(S.accountant, S.bank.id).unreconciled.should be_empty
    Api.reconcile(S.importer, view.id, input).error_keys.should eq(["bankimport.errors.reconcile.already"])
  end

  it "rend les refus du rapprochement (écart des soldes) et refuse un import sans ligne transférée" do
    S.setup
    view = S.import("releve.ofx")
    Api.reconcile(S.importer, view.id, Api::ReconcileInput.new("R1")).error_keys.should eq(["bankimport.errors.reconcile.nothing"])
    fees = S.line("PRLV SEPA EDF")
    Api.set_counterpart(S.importer, fees.id, Api::CounterpartInput.new(account: "627")).value!
    Api.transfer(S.importer, [fees.id]).value!
    mismatch = Api.reconcile(S.importer, view.id, Api::ReconcileInput.new("R1", S.d("1000"), S.d("1100")))
    mismatch.error_keys.should eq(["accounting.errors.reconciliation.mismatch"])
    Api.import_detail(S.reader, view.id).reconciled?.should be_false
  end
end

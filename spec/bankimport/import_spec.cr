# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Bankimport::SpecSupport
private alias Api = Bankimport::Api
private alias Acc = Partiduo::Api::Accounting

describe "Import des relevés : zone d'attente, doublons, historique (D-BKI-005, D-BKI-007)" do
  it "lit sans écrire à l'aperçu, doublons et anomalies signalés" do
    S.setup
    format = S.split_format
    preview = Api.preview(S.importer, S.input("banque-du-centre.csv", format_id: format.id)).value!
    preview.kind.should eq("csv")
    preview.lines.size.should eq(6)
    preview.new_count.should eq(6)
    preview.issues.map { |issue| {issue.field, issue.key} }.should eq([{"lines[8]", "bankimport.errors.line.zero"}])
    preview.same_file_import_id.should be_nil
    Bankimport::Line.all.count.should eq(0)
    Api.imports(S.reader).should be_empty
  end

  it "importe un CSV dans la zone d'attente : lignes à traiter, fichier conservé en pièce jointe par le socle" do
    S.setup
    format = S.split_format
    view = S.import("banque-du-centre.csv", format.id, actor: S.importer)
    view.kind.should eq("csv")
    view.format_name.should eq("Banque du Centre")
    view.ledger_code.should eq("F01")
    view.line_count.should eq(6)
    view.pending_count.should eq(6)
    view.duplicate_count.should eq(0)
    view.first_date.should eq(S.date("2026-09-01"))
    view.last_date.should eq(S.date("2026-09-08"))
    view.total_in.should eq(S.d("1200"))
    view.total_out.should eq(S.d("192.50"))

    attachment = Partiduo::Api::Core.attachment(S.accountant, present(view.attachment_id))
    attachment.filename.should eq("banque-du-centre.csv")
    attachment.content_type.should eq("text/csv")
    filename, content_type, bytes = present(Api.import_content(S.reader.copy_with(permissions: S.reader.permissions + Set{"core.attachment.read"}), view.id))
    {filename, content_type}.should eq({"banque-du-centre.csv", "text/csv"})
    bytes.should eq(S.fixture("banque-du-centre.csv"))

    lines = S.pending(view.id)
    lines.map(&.amount).should eq([S.d("-84.20"), S.d("1200"), S.d("-12.50"), S.d("-45.90"), S.d("-45.90"), S.d("-4")])
    lines.all?(&.pending?).should be_true
    lines.none?(&.ready?).should be_true
    Acc.entries(S.accountant, Acc::EntryQuery.new(ledger_id: S.bank.id)).should be_empty
    Api.imports(S.reader).map(&.id).should eq([view.id])
  end

  it "refuse un fichier déjà importé dans le journal, sauf demande expresse : ses lignes sont alors des doublons" do
    S.setup
    format = S.split_format
    first = S.import("banque-du-centre.csv", format.id)
    refused = Api.import_file(S.accountant, S.input("banque-du-centre.csv", format_id: format.id))
    refused.error_keys.should eq(["bankimport.errors.file.already_imported"])
    Api.preview(S.accountant, S.input("banque-du-centre.csv", format_id: format.id)).value!.same_file_import_id.should eq(first.id)

    again = S.import("banque-du-centre.csv", format.id, allow_same_file: true)
    again.duplicate_count.should eq(6)
    again.pending_count.should eq(0)
    duplicates = Api.lines(S.accountant, Api::LineQuery.new(import_id: again.id, status: "duplicate"))
    duplicates.compact_map(&.duplicate_of_id).sort!.should eq(S.pending(first.id).map(&.id).sort!)
  end

  it "écarte les lignes déjà importées par empreinte, en comptant les occurrences (date, montant, libellé)" do
    S.setup
    format = S.split_format
    S.import("banque-du-centre.csv", format.id)
    suite = S.import("banque-du-centre-suite.csv", format.id)
    suite.line_count.should eq(3)
    suite.duplicate_count.should eq(2)
    S.pending(suite.id).map(&.label).should eq(["PRLV SEPA ORANGE MOBILE 998877"])
  end

  it "écarte par FITID les opérations OFX déjà importées, et garde deux opérations identiques de FITID distincts" do
    S.setup
    view = S.import("releve.ofx")
    view.kind.should eq("ofx")
    view.account_number.should eq("00012345678")
    view.currency_code.should eq("EUR")
    view.end_balance.should eq(S.d("1057.40"))
    view.statement_on.should eq(S.date("2026-09-15"))
    view.pending_count.should eq(4)
    S.pending(view.id).count(&.label.==("CB CARREFOUR")).should eq(2)
    Partiduo::Api::Core.attachment(S.accountant, present(view.attachment_id)).content_type.should eq("text/plain")

    v2 = S.import("releve-v2.ofx")
    Partiduo::Api::Core.attachment(S.accountant, present(v2.attachment_id)).content_type.should eq("application/xml")

    again = S.import("releve.ofx", allow_same_file: true)
    again.duplicate_count.should eq(4)
    expect_raises(PQ::PQError, /bankimport_line_fitid_unique/) do
      Bankimport::Line.filter(import_id: again.id).first!.update!(status: "pending")
    end
  end

  it "importe un QIF selon l'ordre des dates choisi" do
    S.setup
    result = Api.import_file(S.accountant, Api::ImportInput.new(ledger_id: S.bank.id, filename: "releve.qif",
      content: S.fixture("releve.qif"), date_format: "dd/mm/yyyy"))
    view = result.value!
    view.kind.should eq("qif")
    S.pending(view.id).map(&.label).should eq(["PRLV SEPA EDF", "MENUISERIE LEROUX", "FRAIS TENUE DE COMPTE"])
  end

  it "refuse une saisie invalide sans rien écrire" do
    S.setup
    errors = ->(input : Api::ImportInput) { Api.preview(S.accountant, input).error_keys }
    errors.call(S.input("banque-du-centre.csv", kind: "csv")).should eq(["bankimport.errors.format.blank"])
    errors.call(S.input("banque-du-centre.csv", kind: "csv", format_id: 999_999_i64)).should eq(["bankimport.errors.format.unknown"])
    errors.call(S.input("vide.csv", content: Bytes.empty)).should eq(["bankimport.errors.file.blank"])
    errors.call(S.input("image.png", content: Bytes[0x89, 0x50, 0x00, 0x47])).should eq(["bankimport.errors.file.binary"])
    errors.call(S.input("releve.ofx", kind: "coda")).should eq(["bankimport.errors.choice.invalid"])
    errors.call(S.input("faux.ofx", kind: "ofx", content: "bonjour".to_slice)).should eq(["bankimport.errors.file.not_ofx"])
    errors.call(S.input("releve.ofx").copy_with(ledger_id: Acc.ledger_by_code(S.system, "V01").id))
      .should eq(["bankimport.errors.ledger.invalid"])
    Bankimport::Import.all.count.should eq(0)
  end

  it "signale une écriture semblable déjà passée à la main dans le journal, sans écarter la ligne" do
    S.setup
    supplier = S.card("SUPPLIER", "Électricité de France", "EDF")
    manual = Acc.post_financial(S.system, Acc::FinancialInput.new(ledger_id: S.bank.id, date: S.date("2026-09-01"),
      lines: [Acc::PaymentLineInput.new(S.d("-84.20"), card: supplier.code, label: "Facture EDF")])).value!.first
    view = S.import("releve.ofx")
    edf = S.pending(view.id).find! { |line| line.label == "PRLV SEPA EDF" }
    edf.recorded_entry_id.should eq(manual.id)
    edf.pending?.should be_true
    S.pending(view.id).count(&.recorded_entry_id).should eq(1)
  end

  it "écarte, reprend et purge des lignes ; reprend un doublon jugé distinct" do
    S.setup
    format = S.split_format
    S.import("banque-du-centre.csv", format.id)
    suite = S.import("banque-du-centre-suite.csv", format.id)
    edf = S.line("PRLV SEPA EDF")
    Api.discard(S.importer, [edf.id]).value!.should eq(1)
    Api.line(S.reader, edf.id).status.should eq("discarded")
    Api.lines(S.reader).map(&.id).should_not contain(edf.id)
    Api.restore(S.importer, [edf.id]).value!.should eq(1)
    Api.line(S.reader, edf.id).pending?.should be_true
    Api.discard(S.importer, [] of Int64).error_keys.should eq(["bankimport.errors.line.none_selected"])

    duplicate = Api.lines(S.reader, Api::LineQuery.new(import_id: suite.id, status: "duplicate")).first
    Api.restore(S.importer, [duplicate.id]).value!.should eq(1)
    Api.line(S.reader, duplicate.id).duplicate_of_id.should be_nil

    Api.discard(S.importer, [edf.id]).value!.should eq(1)
    Api.purge(S.accountant).value!.should eq(2)
    expect_raises(Partiduo::Api::NotFound) { Api.line(S.reader, edf.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.purge(S.importer) }
  end

  it "refuse de reprendre un doublon OFX dont le FITID est déjà dans le journal" do
    S.setup
    S.import("releve.ofx")
    again = S.import("releve.ofx", allow_same_file: true)
    duplicate = Api.lines(S.reader, Api::LineQuery.new(import_id: again.id, status: "duplicate")).first
    Api.restore(S.importer, [duplicate.id]).error_keys.should eq(["bankimport.errors.line.fitid_taken"])
  end

  it "supprime un import sans ligne transférée, avec son fichier ; garde un import transféré" do
    S.setup
    format = S.split_format
    view = S.import("banque-du-centre.csv", format.id)
    attachment_id = present(view.attachment_id)
    Api.delete_import(S.accountant, view.id).success?.should be_true
    Bankimport::Line.all.count.should eq(0)
    expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Core.attachment(S.accountant, attachment_id) }

    kept = S.import("banque-du-centre.csv", format.id)
    fees = S.line("FRAIS TENUE")
    Api.set_counterpart(S.importer, fees.id, Api::CounterpartInput.new(account: "627")).value!
    Api.transfer(S.importer, [fees.id]).value!.transferred.size.should eq(1)
    Api.delete_import(S.accountant, kept.id).error_keys.should eq(["bankimport.errors.import.in_use"])
  end

  it "ne montre que les journaux financiers visibles de l'acteur" do
    S.setup
    S.import("releve.ofx")
    blind = S.actor("bruno@example.com", [Api::READ])
    Api.lines(blind).should be_empty
    Api.imports(blind).should be_empty
    Api.count_lines(S.reader).should eq(4)
  end
end

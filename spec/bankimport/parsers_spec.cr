# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Bankimport::SpecSupport
private alias P = Bankimport::Parsers

describe "Lecture des relevés (D-BKI-002)" do
  describe "montants" do
    it "lit les montants en BigDecimal, signe en tête ou en fin, parenthèses, devise et espaces" do
      P::Amounts.parse("1 234,56", ',').should eq(S.d("1234.56"))
      P::Amounts.parse("-84,20", ',').should eq(S.d("-84.20"))
      P::Amounts.parse("84,20-", ',').should eq(S.d("-84.20"))
      P::Amounts.parse("(12,50)", ',').should eq(S.d("-12.50"))
      P::Amounts.parse("1.234,56 €", ',', '.').should eq(S.d("1234.56"))
      P::Amounts.parse("1'234.50", '.', '\'').should eq(S.d("1234.50"))
      P::Amounts.parse("+3 000,00", ',').should eq(S.d("3000"))
      P::Amounts.parse("12,50,3", ',').should be_nil
      P::Amounts.parse("abc", ',').should be_nil
      P::Amounts.parse("", ',').should be_nil
    end

    it "reconnaît le séparateur décimal d'un OFX ou d'un QIF" do
      P::Amounts.parse("-12,50").should eq(S.d("-12.5"))
      P::Amounts.parse("1,200.00").should eq(S.d("1200"))
      P::Amounts.parse("1.200,00").should eq(S.d("1200"))
      P::Amounts.parse("1.234.567").should eq(S.d("1234567"))
      P::Amounts.parse("300").should eq(S.d("300"))
    end
  end

  describe "dates" do
    it "lit les dates selon l'ordre du format, quel que soit le séparateur" do
      P::Dates.parse("05/09/2026", "dd/mm/yyyy").should eq(S.date("2026-09-05"))
      P::Dates.parse("05.09.26", "dd.mm.yy").should eq(S.date("2026-09-05"))
      P::Dates.parse("01/09'26", "dd/mm/yyyy").should eq(S.date("2026-09-01"))
      P::Dates.parse("09/05/2026", "mm/dd/yyyy").should eq(S.date("2026-09-05"))
      P::Dates.parse("2026-09-05", "yyyy-mm-dd").should eq(S.date("2026-09-05"))
      P::Dates.parse("20260905", "yyyymmdd").should eq(S.date("2026-09-05"))
      P::Dates.parse("05/09/99", "dd/mm/yy").should eq(S.date("1999-09-05"))
      P::Dates.compact("20260903120000[0:GMT]").should eq(S.date("2026-09-03"))
      P::Dates.parse("31/02/2026", "dd/mm/yyyy").should be_nil
      P::Dates.parse("32/09/2026", "dd/mm/yyyy").should be_nil
      P::Dates.parse("05/09/2026", "inconnu").should be_nil
    end
  end

  describe "CSV" do
    it "lit un relevé Windows-1252 à colonnes débit et crédit, en-tête sauté, ligne de solde signalée" do
      settings = P::CsvSettings.new(encoding: "windows-1252", date_column: 1, label_column: 2, amount_column: nil,
        debit_column: 3, credit_column: 4, reference_column: 5)
      parsed = P::CsvReader.parse(S.fixture("banque-du-centre.csv"), settings)
      parsed.lines.size.should eq(6)
      edf = parsed.lines.first
      edf.position.should eq(2)
      edf.date.should eq(S.date("2026-09-01"))
      edf.amount.should eq(S.d("-84.20"))
      edf.label.should eq("PRLV SEPA EDF CLIENTS PARTICULIERS 123456")
      edf.reference.should eq("R0001")
      parsed.lines[1].amount.should eq(S.d("1200"))
      parsed.lines[5].label.should eq(%(COTISATION CARTE "PRO" ÉPARGNE))
      parsed.issues.map { |issue| {issue.position, issue.key} }.should eq([{8, "bankimport.errors.line.zero"}])
    end

    it "lit un relevé UTF-8 à montant signé (marque d'ordre, guillemets, point décimal, dates ISO)" do
      settings = P::CsvSettings.new(separator: "comma", date_format: "yyyy-mm-dd", decimal_separator: "dot",
        date_column: 1, label_column: 2, amount_column: 3, extra_column: 4)
      parsed = P::CsvReader.parse(S.fixture("neobanque.csv"), settings)
      parsed.lines.map { |line| {line.label, line.amount, line.extra} }.should eq([
        {"Café de la Gare", S.d("-3.80"), "Paiement carte"},
        {"Remboursement Dupont, cadeau", S.d("25"), "Virement instantané"},
        {"Abonnement Téléphone", S.d("-19.99"), ""},
      ])
      parsed.issues.should be_empty
    end

    it "inverse le signe d'un relevé de carte et signale les lignes illisibles" do
      settings = P::CsvSettings.new(separator: "semicolon", date_column: 1, label_column: 2, amount_column: 3, negate: true,
        skip_lines: 0)
      parsed = P::CsvReader.parse("05/09/2026;Achat;12,00\nxx;Autre;1,00\n06/09/2026;Montant;abc\n06/09/2026;;3,00\n".to_slice, settings)
      parsed.lines.map(&.amount).should eq([S.d("-12")])
      parsed.issues.map(&.key).should eq(["bankimport.errors.line.date", "bankimport.errors.line.amount", "bankimport.errors.line.label"])
      parsed.issues.first.params["value"].should eq("xx")
    end

    it "signale un fichier sans opération" do
      parsed = P::CsvReader.parse("Date;Libellé;Montant\n".to_slice, P::CsvSettings.new)
      parsed.fatal?.should be_true
      parsed.issues.first.key.should eq("bankimport.errors.file.empty")
    end
  end

  describe "OFX" do
    it "lit un OFX 1 (SGML, Windows-1252) : opérations, FITID, compte, devise et solde de fin" do
      parsed = P::OfxReader.parse(S.fixture("releve.ofx"))
      parsed.issues.should be_empty
      parsed.account_number.should eq("00012345678")
      parsed.currency_code.should eq("EUR")
      parsed.end_balance.should eq(S.d("1057.40"))
      parsed.statement_on.should eq(S.date("2026-09-15"))
      parsed.lines.map(&.fitid).should eq(%w[F202609010001 F202609030001 F202609050001 F202609050002])
      leroux = parsed.lines[1]
      leroux.date.should eq(S.date("2026-09-03"))
      leroux.amount.should eq(S.d("1200"))
      leroux.label.should eq("VIR MENUISERIE LEROUX")
      leroux.extra.should eq("Facture 2026-041 réglée")
      parsed.lines[2].reference.should eq("0042")
    end

    it "lit un OFX 2 (XML, UTF-8), entités et virgule décimale comprises" do
      parsed = P::OfxReader.parse(S.fixture("releve-v2.ofx"))
      parsed.lines.map { |line| {line.label, line.amount, line.fitid} }.should eq([
        {"Frais & commissions", S.d("-12.50"), "X-1"},
        {"Remise de chèques", S.d("300"), "X-2"},
      ])
      parsed.account_number.should eq("FR7612345000010001234567890")
      parsed.end_balance.should eq(S.d("2287.50"))
    end

    it "refuse un fichier qui n'est pas un OFX" do
      P::OfxReader.parse("bonjour".to_slice).issues.first.key.should eq("bankimport.errors.file.not_ofx")
    end
  end

  describe "QIF" do
    it "lit un QIF bancaire : date à apostrophe, montant T ou U, bénéficiaire, mémo, numéro, catégorie" do
      parsed = P::QifReader.parse(S.fixture("releve.qif"), "dd/mm/yyyy")
      parsed.lines.map { |line| {line.date, line.amount, line.label} }.should eq([
        {S.date("2026-09-01"), S.d("-84.20"), "PRLV SEPA EDF"},
        {S.date("2026-09-03"), S.d("1200"), "MENUISERIE LEROUX"},
        {S.date("2026-09-05"), S.d("-12.50"), "FRAIS TENUE DE COMPTE"},
      ])
      parsed.lines[0].extra.should eq("CLIENTS PARTICULIERS · Énergie")
      parsed.lines[1].reference.should eq("2026-041")
      parsed.issues.map(&.key).should eq(["bankimport.errors.line.date"])
    end

    it "saute les sections qui ne sont pas des comptes de trésorerie" do
      text = "!Type:Cat\nNAlimentation\n^\n!Type:Invst\nD01/09/2026\nT-10\nPAction\n^\n!Type:CCard\nD02/09/2026\nT-5,00\nPCafé\n^\n"
      parsed = P::QifReader.parse(text.to_slice, "dd/mm/yyyy")
      parsed.lines.map(&.label).should eq(["Café"])
    end

    it "reconnaît le genre au contenu" do
      Bankimport::Importer.detect_kind(S.fixture("releve.ofx")).should eq("ofx")
      Bankimport::Importer.detect_kind(S.fixture("releve-v2.ofx")).should eq("ofx")
      Bankimport::Importer.detect_kind(S.fixture("releve.qif")).should eq("qif")
      Bankimport::Importer.detect_kind(S.fixture("neobanque.csv")).should eq("csv")
    end
  end
end

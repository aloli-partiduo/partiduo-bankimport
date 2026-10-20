# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/BANKIMPORT/` servie en `GET` (liste tirée du routeur de Marten),
# obtenue en fr, en et nl par un administrateur, sur deux imports (l'un
# pointé, aux lignes dans chaque état : à traiter, contrepartie proposée,
# transférée puis extournée, écartée ; l'autre par un format CSV, à pointer), deux formats et deux
# règles. Contrôle de l'interface (`PartiduoUi::Translations`) : ni
# marqueur de traduction absente, ni clé brute, ni interpolation non
# résolue, et toute route atteinte par les liens des pages.

private alias S = Bankimport::SpecSupport
private alias Api = Bankimport::Api

describe "Traductions des écrans BANKIMPORT (fr, en, nl)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    browser = PartiduoUi::Books.admin
    S.user("bruno@example.com", "Bruno")
    S.activate

    view = S.import("releve.ofx")
    edf = S.line("PRLV SEPA EDF")
    Api.set_counterpart(S.accountant, edf.id, Api::CounterpartInput.new(account: "627", learn: true)).value!
    others = S.pending(view.id).reject(&.id.==(edf.id))
    Api.set_counterpart(S.accountant, others[0].id, Api::CounterpartInput.new(account: "627", learn: false)).value!
    # Ligne transférée dont l'écriture a été extournée : à rattacher.
    entry_id = present(Api.transfer(S.accountant, [others[0].id]).value!.transferred.first.entry_id)
    Partiduo::Api::Accounting.cancel_entry(S.system, Partiduo::Api::Accounting::CancelEntryInput.new(entry_id)).value!
    Api.discard(S.accountant, [others[1].id]).value!
    Api.reconcile(S.accountant, view.id, Api::ReconcileInput.new("R-09", S.d("33.40"), S.d("1057.40")))
    split = S.split_format
    S.signed_format
    csv = S.import("banque-du-centre.csv", format_id: split.id)
    # Ligne transférée d'un relevé pas encore pointé : formulaire de pointage.
    first = S.pending(csv.id).first
    Api.set_counterpart(S.accountant, first.id, Api::CounterpartInput.new(account: "627", learn: false)).value!
    Api.transfer(S.accountant, [first.id]).value!
    Api.create_rule(S.accountant, Api::RuleInput.new(label_contains: "FRAIS", direction: "out", account: "627", payee: "Banque")).value!

    explorer = PartiduoUi::Translations::Explorer.new(&.name.starts_with?("bankimport:"))
    # Rattachement d'une ligne, que l'écran des lignes n'appelle qu'en POST
    # (HTMX) ; son GET renvoie aux lignes.
    explorer.crawl(browser, "BANKIMPORT", ["/ext/BANKIMPORT/lines/#{others[0].id}/relink"])
    puts "\nTraductions de BANKIMPORT : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end

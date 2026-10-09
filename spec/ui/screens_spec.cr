# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Bankimport::SpecSupport
private alias Api = Bankimport::Api

# Administrateur connecté (profil ADMIN : toutes les permissions), dossier
# provisionné, extension active.
private def signed_in : PartiduoUi::Browser
  browser = PartiduoUi::Books.admin
  S.user("bruno@example.com", "Bruno")
  S.activate
  browser
end

private def form_body(values : Hash(String, String | Array(String))) : String
  URI::Params.build do |params|
    values.each do |key, value|
      value.is_a?(Array) ? value.each { |item| params.add(key, item) } : params.add(key, value)
    end
  end
end

describe "Écrans des relevés bancaires sous /ext/BANKIMPORT/ (ADR-011 D6, ADR-005)" do
  it "est montée sous le code de l'extension, avec ses permissions par route" do
    Marten.routes.reverse("bankimport:lines").should eq("/ext/BANKIMPORT/lines")
    Marten.routes.reverse("bankimport:import_detail", id: 4).should eq("/ext/BANKIMPORT/imports/4")
    mount = PartiduoUi::Extensions["BANKIMPORT"]? || raise("interface non montée")
    mount.permission.should eq("bankimport.read")
    mount.permission_for("bankimport:import").should eq("bankimport.import")
    mount.permission_for("bankimport:line").should eq("bankimport.import")
    mount.permission_for("bankimport:lines").should eq("bankimport.read")
    mount.permission_for("bankimport:rules").should eq("bankimport.admin")
    mount.permission_for("bankimport:purge").should eq("bankimport.admin")
  end

  it "n'existe pas tant que l'extension est inactive (404) et renvoie un anonyme vers la connexion" do
    browser = PartiduoUi::Books.admin
    browser.get("/ext/BANKIMPORT/lines").status.should eq(404)
    S.activate
    response = PartiduoUi::Browser.new.get("/ext/BANKIMPORT/lines")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FBANKIMPORT%2Flines")
  end

  it "importe un relevé collé en deux temps : aperçu, puis import dans la zone d'attente" do
    browser = signed_in
    browser.get("/ext/BANKIMPORT/").headers["Location"].should eq("/ext/BANKIMPORT/lines")
    start = browser.get("/ext/BANKIMPORT/import").html
    start.should contain("<h1>Importer un relevé")
    start.should contain("Reconnu au contenu")
    start.should contain("F01")
    content = String.new(S.fixture("releve-v2.ofx"))
    preview = browser.post("/ext/BANKIMPORT/import", {"step" => "preview", "ledger_id" => S.bank.id.to_s, "kind" => "auto",
                                                      "format_id" => "", "date_format" => "dd/mm/yyyy", "content" => content})
    preview.status.should eq(200)
    html = preview.html
    html.should contain("2 opérations lues : 2 nouvelle(s), 0 doublon(s)")
    html.should contain("Frais & commissions")
    html.should contain("FR7612345000010001234567890")
    html.should contain("Importer 2 lignes")
    payload = html.match!(/name="payload" value="([^"]+)"/)[1]
    filename = html.match!(/name="filename" value="([^"]+)"/)[1]

    done = browser.post("/ext/BANKIMPORT/import", {"step" => "import", "ledger_id" => S.bank.id.to_s, "kind" => "ofx",
                                                   "format_id" => "", "date_format" => "dd/mm/yyyy", "payload" => payload,
                                                   "filename" => filename})
    done.status.should eq(302)
    detail = browser.follow(done).html
    detail.should contain("Relevé importé : 2 lignes à traiter, 0 doublon(s) écarté(s).")
    detail.should contain("Remise de chèques")
    detail.should contain("Traiter les lignes")
    Api.imports(S.system).first.filename.should start_with("releve-colle-")
  end

  it "signale à l'aperçu une saisie refusée (422)" do
    browser = signed_in
    response = browser.post("/ext/BANKIMPORT/import", {"step" => "preview", "ledger_id" => S.bank.id.to_s, "kind" => "csv",
                                                       "format_id" => "", "content" => "a;b;c"})
    response.status.should eq(422)
    response.html.should contain("Choisissez le format CSV de l'établissement.")
  end

  it "traite les lignes : contrepartie en HTMX, règle apprise, transfert groupé, compteur et tuile" do
    browser = signed_in
    view = S.import("releve.ofx")
    edf = S.line("PRLV SEPA EDF")
    lines = browser.get("/ext/BANKIMPORT/lines").html
    lines.should contain("<h1>Lignes à traiter")
    lines.should contain("4 lignes")
    lines.should contain(%(id="bki-line-#{edf.id}"))
    lines.should contain(%(hx-post="/ext/BANKIMPORT/lines/#{edf.id}"))
    lines.should contain(%(<datalist id="bki-accounts">))
    lines.should contain(%(<option value="627">Services bancaires et assimilés</option>))

    fragment = browser.htmx_post("/ext/BANKIMPORT/lines/#{edf.id}", {"card_code" => "", "account" => "627", "learn" => "1"})
    fragment.status.should eq(200)
    row = fragment.html
    row.should start_with(%(<tr id="bki-line-#{edf.id}"))
    row.should contain("627 · Services bancaires et assimilés")
    row.should_not contain("<html")
    Api.rules(S.system).map(&.label_contains).should eq(["PRLV SEPA EDF"])

    refused = browser.htmx_post("/ext/BANKIMPORT/lines/#{edf.id}", {"card_code" => "INCONNU", "account" => ""})
    refused.status.should eq(422)
    refused.html.should contain("Aucune fiche n'a le code INCONNU.")

    dashboard = browser.get("/").html
    dashboard.should contain(%(data-pd-count="BANKIMPORT_LINES">4</span>))
    dashboard.should contain("4 lignes de relevé à traiter")
    dashboard.should contain(%(data-module="BANKIMPORT"))
    dashboard.should contain("dont 1 avec contrepartie proposée")

    ids = [edf.id.to_s]
    moved = browser.perform_raw("/ext/BANKIMPORT/lines/action", form_body({"action" => "transfer", "ids" => ids, "next" => "/ext/BANKIMPORT/lines"}))
    moved.status.should eq(302)
    after = browser.follow(moved).html
    after.should contain("1 ligne transférée en comptabilité.")
    after.should contain("3 lignes")
    Api.line(S.system, edf.id).status.should eq("transferred")

    others = S.pending(view.id).map(&.id.to_s)
    failed = browser.perform_raw("/ext/BANKIMPORT/lines/action", form_body({"action" => "transfer", "ids" => others}))
    browser.follow(failed).html.should contain("3 lignes refusées : voir leur message.")
    discard = browser.perform_raw("/ext/BANKIMPORT/lines/action", form_body({"action" => "discard", "ids" => others[0, 1]}))
    browser.follow(discard).html.should contain("1 ligne écartée.")
  end

  it "montre l'historique, le détail d'un import, son fichier, et pointe le relevé" do
    browser = signed_in
    view = S.import("releve.ofx")
    S.pending(view.id).each { |line| Api.set_counterpart(S.system, line.id, Api::CounterpartInput.new(account: "627", learn: false)) }
    Api.transfer(S.system, S.pending(view.id).map(&.id))
    history = browser.get("/ext/BANKIMPORT/imports").html
    history.should contain("<h1>Historique des imports")
    history.should contain("releve.ofx")
    history.should contain(%(href="/ext/BANKIMPORT/imports/#{view.id}"))
    browser.get("/ext/BANKIMPORT/imports?format=csv").content.should contain("releve.ofx")

    detail = browser.get("/ext/BANKIMPORT/imports/#{view.id}").html
    detail.should contain("00012345678")
    detail.should contain("1 057,40")
    file = browser.get("/ext/BANKIMPORT/imports/#{view.id}/file")
    file.status.should eq(200)
    file.headers["Content-Disposition"].should eq(%(attachment; filename="releve.ofx"))
    file.content.to_slice.should eq(S.fixture("releve.ofx"))

    refused = browser.post("/ext/BANKIMPORT/imports/#{view.id}/reconcile", {"reference" => "R-09", "start_balance" => "0", "end_balance" => "1"})
    refused.status.should eq(422)
    refused.html.should contain("Pointer le relevé")
    done = browser.post("/ext/BANKIMPORT/imports/#{view.id}/reconcile", {"reference" => "R-09", "start_balance" => "33,40", "end_balance" => "1 057,40"})
    done.status.should eq(302)
    browser.follow(done).html.should contain("Relevé R-09 pointé.")
    Api.import_detail(S.system, view.id).reconciled?.should be_true
  end

  it "paramètre les formats CSV et les règles (bankimport.admin)" do
    browser = signed_in
    browser.get("/ext/BANKIMPORT/formats").html.should contain("Aucun format : créez celui de votre établissement.")
    form = browser.get("/ext/BANKIMPORT/formats/new").html
    form.should contain("JJ/MM/AAAA")
    form.should contain("Rang des colonnes")
    created = browser.post("/ext/BANKIMPORT/formats/new", {"name" => "Banque du Centre", "institution" => "BDC",
                                                           "separator" => "semicolon", "encoding" => "windows-1252",
                                                           "skip_lines" => "1", "date_format" => "dd/mm/yyyy",
                                                           "decimal_separator" => "comma", "thousands_separator" => "none",
                                                           "date_column" => "1", "label_column" => "2", "debit_column" => "3",
                                                           "credit_column" => "4"})
    created.status.should eq(302)
    browser.follow(created).html.should contain("Banque du Centre")
    refused = browser.post("/ext/BANKIMPORT/formats/new", {"name" => "", "date_column" => "1", "label_column" => "x"})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez un nombre entier.")

    rule = browser.post("/ext/BANKIMPORT/rules/new", {"label_contains" => "FRAIS", "direction" => "out", "account" => "627",
                                                      "position" => "10", "active" => "1"})
    rule.status.should eq(302)
    rules = browser.follow(rule).html
    rules.should contain("FRAIS")
    rules.should contain("Saisie")
    browser.post("/ext/BANKIMPORT/rules/new", {"label_contains" => "", "account" => ""}).status.should eq(422)
  end

  it "refuse les écrans de paramétrage à qui ne peut que consulter (403)" do
    PartiduoUi::Reference.provision
    PartiduoUi::Reference.fiscal_year(2026)
    profile = PartiduoUi::Accounts.profile("Lecture relevés", ["bankimport.read", "accounting.ledger.read"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    S.activate
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/ext/BANKIMPORT/lines").status.should eq(200)
    browser.get("/ext/BANKIMPORT/formats").status.should eq(403)
    browser.get("/ext/BANKIMPORT/import").status.should eq(403)
  end
end

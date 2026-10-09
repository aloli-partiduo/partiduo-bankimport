# SPDX-License-Identifier: AGPL-3.0-or-later

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration.
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end

# Valeur attendue présente : échoue clairement sinon (plutôt que `not_nil!`).
def present(value : T?) : T forall T
  value.nil? ? raise("valeur attendue, nil obtenu") : value
end

module Bankimport
  # Outils des specs : dossier provisionné par le contrat du cœur
  # (journal financier F01 adossé à sa fiche Banque), extension activée,
  # acteurs, formats, imports des fichiers d'exemple.
  module SpecSupport
    alias Api = Bankimport::Api
    alias Acc = Partiduo::Api::Accounting

    FIXTURES = File.join(ROOT, "spec", "fixtures")

    # Permissions du cœur d'un comptable qui importe et transfère.
    CORE_PERMISSIONS = ["core.attachment.read", "core.attachment.write", "accounting.ledger.read", "accounting.entry.read",
                        "accounting.entry.post", "accounting.entry.cancel", "accounting.account.read",
                        "accounting.matching.write", "cards.card.read"]

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    def self.fixture(name : String) : Bytes
      File.open(File.join(FIXTURES, name), &.getb_to_end)
    end

    # Dossier FR (plan comptable, journaux, fiches), exercice 2026,
    # utilisateurs de test, extension active.
    def self.setup : Nil
      PartiduoUi::Reference.provision
      PartiduoUi::Reference.fiscal_year(2026)
      user("alice@example.com", "Alice")
      user("bruno@example.com", "Bruno")
      activate
    end

    def self.activate : Nil
      Partiduo::Api::Modules.activate(system, Bankimport::CODE).value!
    end

    def self.user(email : String, first_name : String) : Int64
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first_name, last_name: "Test", role: "member",
        profile_id: PartiduoUi::Accounts.profile_id("ADMIN"), password: PartiduoUi::Accounts::PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!.user.id
    end

    def self.user_id(email : String) : Int64
      Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    end

    # Acteur d'une session au niveau le plus haut (passkey) : les droits par
    # journal du socle le traitent comme une session ordinaire.
    def self.actor(email : String, permissions : Array(String)) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id(email), permissions, level: 3)
    end

    # Comptable : toute l'extension et les droits du cœur qu'elle emploie.
    def self.accountant : Partiduo::Api::Actor
      actor("alice@example.com", [Api::READ, Api::IMPORT, Api::ADMIN] + CORE_PERMISSIONS)
    end

    # Importe et traite, sans paramétrer.
    def self.importer : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, Api::IMPORT] + CORE_PERMISSIONS)
    end

    def self.reader : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, "accounting.ledger.read"])
    end

    def self.bank : Acc::LedgerView
      Acc.ledger_by_code(system, "F01")
    end

    # Format CSV « banque française » : `Date;Libellé;Débit;Crédit;Référence`,
    # Windows-1252, une ligne d'en-tête.
    def self.split_format : Api::FormatView
      input = Api::FormatInput.new(name: "Banque du Centre", institution: "Banque du Centre", date_column: 1,
        label_column: 2, debit_column: 3, credit_column: 4, reference_column: 5, encoding: "windows-1252",
        ledger_id: bank.id)
      Api.create_format(accountant, input).value!
    end

    # Format CSV « montant signé » : `date,description,amount,memo`, UTF-8,
    # dates ISO, point décimal.
    def self.signed_format : Api::FormatView
      input = Api::FormatInput.new(name: "Néobanque", date_column: 1, label_column: 2, amount_column: 3, extra_column: 4,
        separator: "comma", date_format: "yyyy-mm-dd", decimal_separator: "dot")
      Api.create_format(accountant, input).value!
    end

    def self.input(name : String, kind : String = "auto", format_id : Int64? = nil, content : Bytes? = nil,
                   allow_same_file : Bool = false) : Api::ImportInput
      Api::ImportInput.new(ledger_id: bank.id, filename: name, content: content || fixture(name), kind: kind,
        format_id: format_id, allow_same_file: allow_same_file)
    end

    def self.import(name : String, format_id : Int64? = nil, actor : Partiduo::Api::Actor = accountant,
                    allow_same_file : Bool = false) : Api::ImportView
      result = Api.import_file(actor, input(name, format_id: format_id, allow_same_file: allow_same_file))
      raise "import refusé : #{result.error_keys.join(", ")}" if result.failure?
      result.value!
    end

    def self.pending(import_id : Int64? = nil) : Array(Api::LineView)
      Api.lines(accountant, Api::LineQuery.new(import_id: import_id))
    end

    def self.line(label : String) : Api::LineView
      Api.lines(accountant, Api::LineQuery.new(status: nil)).find(&.label.includes?(label)) ||
        raise "ligne « #{label} » absente"
    end

    def self.card(category : String, name : String, code : String) : Partiduo::Api::Cards::CardView
      PartiduoUi::Books.card(category, name, code)
    end
  end
end

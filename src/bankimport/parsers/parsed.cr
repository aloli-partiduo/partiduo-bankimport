# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Lecture des fichiers de relevé (D-BKI-002) : CSV paramétrable, OFX,
  # QIF. Chaque lecteur rend un `Parsed` — lignes lues et anomalies par
  # ligne — sans rien écrire. Montants en `BigDecimal`, jamais en flottant.
  # Interne.
  module Parsers
    # Ligne lue dans un fichier. `position` : rang de la ligne (CSV, QIF) ou
    # de l'opération (OFX) dans le fichier, à partir de 1. `payee` :
    # bénéficiaire que le fichier nomme (OFX `NAME` ou `PAYEE`, QIF `P`,
    # colonne « tiers » d'un CSV) ; `iban` : IBAN de la contrepartie quand le
    # fichier le porte (OFX `BANKACCTTO`, colonne IBAN d'un CSV), sous sa
    # forme compacte.
    record ParsedLine,
      position : Int32,
      date : Time,
      amount : BigDecimal,
      label : String,
      extra : String = "",
      reference : String = "",
      fitid : String = "",
      counterparty : String = "",
      payee : String = "",
      iban : String = ""

    # Anomalie d'une ligne (`position` > 0) ou du fichier (`position` = 0) :
    # clé i18n complète et paramètres, comme `Partiduo::Api::FieldError`.
    record Issue, position : Int32, key : String, params : Hash(String, String) = {} of String => String

    # Résultat d'une lecture : lignes, anomalies, et ce que le fichier dit
    # du compte (OFX : numéro, devise, solde de fin et sa date).
    class Parsed
      getter lines = [] of ParsedLine
      getter issues = [] of Issue
      property account_number : String = ""
      property currency_code : String = ""
      property start_balance : BigDecimal? = nil
      property end_balance : BigDecimal? = nil
      property statement_on : Time? = nil

      def issue(position : Int32, key : String, params = {} of String => String) : Nil
        @issues << Issue.new(position, "bankimport.errors.#{key}", params)
      end

      # Anomalie qui empêche toute lecture du fichier.
      def fatal? : Bool
        @issues.any?(&.position.zero?)
      end
    end

    # Libellé ramené à une seule ligne, sans espaces superflus, borné.
    def self.clean(text : String, max : Int32 = 255) : String
      text.gsub(/[[:cntrl:]]/, " ").gsub(/\s+/, " ").strip[0, max]
    end

    # IBAN sous sa forme compacte (majuscules, sans espaces, points ni
    # tirets), ou chaîne vide si le texte n'en a pas la forme (deux lettres,
    # deux chiffres, 11 à 30 caractères alphanumériques) : un numéro de
    # compte national n'est pas un IBAN et ne doit rien proposer.
    def self.iban(text : String) : String
      compact = text.upcase.gsub(/[\s.\-]/, "")
      compact.matches?(/\A[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\z/) ? compact : ""
    end

    # Entités XML et SGML courantes d'un OFX.
    def self.unescape(text : String) : String
      text.gsub("&lt;", "<").gsub("&gt;", ">").gsub("&quot;", "\"").gsub("&apos;", "'").gsub("&nbsp;", " ").gsub("&amp;", "&")
    end
  end
end

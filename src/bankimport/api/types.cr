# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Api
    # Genres de fichier (D-BKI-002). Libellé : `bankimport.kinds.<code>`.
    KINDS = %w[csv ofx qif]

    # Statuts d'une ligne (D-BKI-005). Libellé : `bankimport.statuses.<code>`.
    STATUSES = %w[pending transferred duplicate discarded]

    # Sens d'une règle : entrée en banque, sortie, l'un ou l'autre.
    # Libellé : `bankimport.directions.<code>`.
    DIRECTIONS = %w[any in out]

    # Réglages d'un format CSV. Libellés : `bankimport.separators.<code>`,
    # `bankimport.encodings.<code>`, `bankimport.decimal_separators.<code>`,
    # `bankimport.thousands_separators.<code>`. Les formats de date ont pour
    # code leur gabarit anglais (`dd/mm/yyyy`), que l'interface traduit.
    SEPARATORS           = Parsers::CsvReader::SEPARATORS.keys
    ENCODINGS            = Parsers::Text::ENCODINGS
    DECIMAL_SEPARATORS   = Parsers::Amounts::SEPARATORS.keys
    THOUSANDS_SEPARATORS = Parsers::Amounts::THOUSANDS.keys
    DATE_FORMATS         = Parsers::Dates::FORMATS.keys

    # Taille maximale d'un fichier de relevé (5 Mio) et nombre de lignes.
    MAX_BYTES = 5 * 1024 * 1024
    MAX_LINES = 10_000

    # Plus grand rang de colonne d'un format CSV.
    MAX_COLUMN = 60

    # --- Entrées ---------------------------------------------------------------

    # Format CSV d'un établissement (D-BKI-002). Le montant est lu dans
    # `amount_column` (signé), ou dans `debit_column` et `credit_column` ;
    # `negate` inverse le signe lu (relevé de carte : dépense positive).
    record FormatInput,
      name : String,
      date_column : Int32,
      label_column : Int32,
      amount_column : Int32? = nil,
      debit_column : Int32? = nil,
      credit_column : Int32? = nil,
      extra_column : Int32? = nil,
      reference_column : Int32? = nil,
      counterparty_column : Int32? = nil,
      institution : String = "",
      ledger_id : Int64? = nil,
      separator : String = "semicolon",
      encoding : String = "utf-8",
      skip_lines : Int32 = 1,
      date_format : String = "dd/mm/yyyy",
      decimal_separator : String = "comma",
      thousands_separator : String = "none",
      negate : Bool = false

    # Fichier à importer dans le journal financier `ledger_id`.
    #
    # * `kind` : `csv`, `ofx`, `qif`, ou `auto` (reconnu au contenu : en-tête
    #   OFX, `!Type` d'un QIF, CSV sinon) ;
    # * `format_id` : format CSV de l'établissement (obligatoire pour un CSV) ;
    # * `date_format` : ordre des dates d'un QIF (le fichier ne le dit pas) ;
    # * `allow_same_file` : importer un fichier déjà importé dans ce journal
    #   (ses lignes seront des doublons, sauf celles qu'on aurait purgées).
    record ImportInput,
      ledger_id : Int64,
      filename : String,
      content : Bytes,
      kind : String = "auto",
      format_id : Int64? = nil,
      date_format : String = "dd/mm/yyyy",
      allow_same_file : Bool = false

    # Recherche dans la zone d'attente : journal, import, statut (`nil` :
    # tous), texte (libellé, information, tiers, référence), lignes sans
    # contrepartie seulement.
    record LineQuery,
      ledger_id : Int64? = nil,
      import_id : Int64? = nil,
      status : String? = "pending",
      search : String? = nil,
      unassigned_only : Bool = false,
      offset : Int32 = 0,
      limit : Int32 = 200

    # Contrepartie choisie pour une ligne : fiche (quick code) *ou* compte ;
    # `match_line_id` : ligne d'écriture ouverte de la fiche à lettrer au
    # transfert ; `learn` : en tirer une règle de catégorisation (D-BKI-006).
    record CounterpartInput,
      card_code : String = "",
      account : String = "",
      match_line_id : Int64? = nil,
      learn : Bool = true

    # Règle de catégorisation (D-BKI-006) : au moins une condition (libellé
    # qui contient, montant absolu égal), une contrepartie (fiche *ou*
    # compte) ; `ledger_id` nul : tous les journaux.
    record RuleInput,
      label_contains : String = "",
      amount : BigDecimal? = nil,
      direction : String = "any",
      card_code : String = "",
      account : String = "",
      ledger_id : Int64? = nil,
      position : Int32 = 100,
      active : Bool = true

    # Pointage du relevé d'un import (D-BKI-010) : référence du relevé et
    # soldes de début et de fin, passés au rapprochement de la Comptabilité.
    record ReconcileInput,
      reference : String,
      start_balance : BigDecimal? = nil,
      end_balance : BigDecimal? = nil

    # --- Vues ------------------------------------------------------------------

    record FormatView,
      id : Int64,
      name : String,
      institution : String,
      ledger_id : Int64?,
      separator : String,
      encoding : String,
      skip_lines : Int32,
      date_format : String,
      decimal_separator : String,
      thousands_separator : String,
      date_column : Int32,
      label_column : Int32,
      amount_column : Int32?,
      debit_column : Int32?,
      credit_column : Int32?,
      extra_column : Int32?,
      reference_column : Int32?,
      counterparty_column : Int32?,
      negate : Bool,
      import_count : Int32

    # Import (historique, D-BKI-007) et état de ses lignes.
    record ImportView,
      id : Int64,
      ledger_id : Int64,
      ledger_code : String,
      kind : String,
      format_id : Int64?,
      format_name : String?,
      filename : String,
      attachment_id : Int64?,
      account_number : String,
      currency_code : String,
      start_balance : BigDecimal?,
      end_balance : BigDecimal?,
      statement_on : Time?,
      line_count : Int32,
      duplicate_count : Int32,
      pending_count : Int32,
      transferred_count : Int32,
      discarded_count : Int32,
      first_date : Time?,
      last_date : Time?,
      total_in : BigDecimal,
      total_out : BigDecimal,
      statement_id : Int64?,
      statement_reference : String,
      created_by_id : Int64?,
      created_at : Time do
      def reconciled? : Bool
        !statement_id.nil?
      end

      def kind_key : String
        "bankimport.kinds.#{kind}"
      end
    end

    # Ligne de la zone d'attente. `card_name`, `account_label` : relus dans
    # le cœur quand l'acteur peut les lire ; `error` : refus du dernier
    # transfert.
    record LineView,
      id : Int64,
      import_id : Int64,
      ledger_id : Int64,
      position : Int32,
      date : Time,
      amount : BigDecimal,
      label : String,
      extra : String,
      reference : String,
      fitid : String,
      counterparty : String,
      status : String,
      card_code : String,
      card_name : String?,
      account : String,
      account_label : String?,
      rule_id : Int64?,
      match_line_id : Int64?,
      duplicate_of_id : Int64?,
      recorded_entry_id : Int64?,
      entry_id : Int64?,
      reversed_entry_id : Int64?,
      error : Partiduo::Api::FieldError? do
      def pending? : Bool
        status == "pending"
      end

      # Contrepartie choisie (fiche ou compte) : la ligne peut être transférée.
      def ready? : Bool
        pending? && (!card_code.empty? || !account.empty?)
      end

      def inflow? : Bool
        amount > 0
      end

      def status_key : String
        "bankimport.statuses.#{status}"
      end
    end

    # Ligne lue à l'aperçu d'un import, avant écriture ; `duplicate` : elle
    # serait écartée comme doublon.
    record PreviewLineView,
      position : Int32,
      date : Time,
      amount : BigDecimal,
      label : String,
      extra : String,
      reference : String,
      fitid : String,
      duplicate : Bool

    # Aperçu d'un import : genre reconnu, lignes, anomalies (champ
    # `lines[<rang>]` ou `content`), import antérieur du même fichier,
    # compte et solde lus dans un OFX.
    record PreviewView,
      kind : String,
      lines : Array(PreviewLineView),
      issues : Array(Partiduo::Api::FieldError),
      same_file_import_id : Int64?,
      account_number : String,
      end_balance : BigDecimal?,
      statement_on : Time? do
      def new_count : Int32
        lines.count { |line| !line.duplicate }
      end

      def duplicate_count : Int32
        lines.count(&.duplicate)
      end
    end

    # Bilan d'un transfert : lignes passées, lignes refusées (avec leur
    # erreur).
    record TransferReportView, transferred : Array(LineView), failed : Array(LineView)

    record RuleView,
      id : Int64,
      ledger_id : Int64?,
      label_contains : String,
      amount : BigDecimal?,
      direction : String,
      card_code : String,
      account : String,
      position : Int32,
      active : Bool,
      learned : Bool,
      hits : Int32,
      last_used_at : Time? do
      def direction_key : String
        "bankimport.directions.#{direction}"
      end
    end

    # Écriture ouverte (non lettrée) de la fiche d'une ligne, de même
    # montant : proposée au lettrage du transfert.
    record OpenItemView,
      line_id : Int64,
      entry_id : Int64,
      date : Time,
      ledger_code : String,
      receipt : String?,
      label : String,
      amount : BigDecimal

    # Tuile du tableau de bord : lignes à traiter, dont celles qui ont une
    # contrepartie proposée.
    record TileView, pending_count : Int32, ready_count : Int32, oldest_date : Time?
  end
end

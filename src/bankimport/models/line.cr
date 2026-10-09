# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Ligne d'un relevé importé, dans la zone d'attente (D-BKI-005) :
  # date, montant signé (positif : entrée en banque), libellé, information
  # complémentaire, référence de l'opération, identifiant FITID d'un OFX,
  # tiers lu dans le fichier.
  #
  # * `status` : `pending` (à traiter), `transferred` (écriture passée,
  #   `entry_id`), `duplicate` (doublon écarté à l'import, `duplicate_of_id`),
  #   `discarded` (écartée par l'utilisateur) ;
  # * contrepartie proposée : fiche (`card_code`) ou compte (`account`),
  #   par une règle (`rule_id`) ou par l'utilisateur ; `match_line_id` :
  #   ligne d'écriture ouverte à lettrer au transfert ;
  # * `recorded_entry_id` : écriture du journal de même date et de même
  #   montant, déjà en comptabilité (signalée, pas écartée) ;
  # * `fingerprint` : date, montant et libellé normalisé (doublons) ;
  # * `error_key`, `error_params` : refus du dernier transfert, à corriger ;
  # * `reversed_entry_id` : écriture transférée puis extournée (D-BKI-009).
  #
  # Interne.
  class Line < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :import_id, :big_int, index: true
    field :ledger_id, :big_int, index: true
    field :position, :int
    field :date, :date
    field :amount, :decimal, max_digits: 20, decimal_places: 4
    field :label, :string, max_size: 255
    field :extra, :text, blank: true, default: ""
    field :reference, :string, max_size: 64, blank: true, default: ""
    field :fitid, :string, max_size: 255, blank: true, default: ""
    field :counterparty, :string, max_size: 255, blank: true, default: ""
    field :fingerprint, :string, max_size: 64, index: true
    field :status, :string, max_size: 16, default: "pending"
    field :card_code, :string, max_size: 64, blank: true, default: ""
    field :account, :string, max_size: 40, blank: true, default: ""
    field :rule_id, :big_int, blank: true, null: true
    field :match_line_id, :big_int, blank: true, null: true
    field :duplicate_of_id, :big_int, blank: true, null: true
    field :recorded_entry_id, :big_int, blank: true, null: true
    field :entry_id, :big_int, blank: true, null: true, index: true
    field :reversed_entry_id, :big_int, blank: true, null: true
    field :error_key, :string, max_size: 200, blank: true, default: ""
    field :error_params, :text, blank: true, default: ""
    field :transferred_by_id, :big_int, blank: true, null: true
    field :transferred_at, :date_time, blank: true, null: true

    with_timestamp_fields
  end
end

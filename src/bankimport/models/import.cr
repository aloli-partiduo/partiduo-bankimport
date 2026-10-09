# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Un fichier importé (historique, D-BKI-007) : journal visé, genre du
  # fichier (`csv`, `ofx`, `qif`), format CSV employé, nom du fichier,
  # pièce jointe du socle qui le conserve (`attachment_id`, sans clé
  # étrangère : D-BKI-003), empreinte SHA-256 (un même fichier importé deux
  # fois est signalé), compte et soldes lus dans un OFX, compteurs de
  # lignes, relevé du rapprochement de la Comptabilité une fois pointé
  # (`statement_id`). Interne.
  class Import < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :ledger_id, :big_int, index: true
    field :kind, :string, max_size: 8
    field :format_id, :big_int, blank: true, null: true
    field :filename, :string, max_size: 255
    field :attachment_id, :big_int, blank: true, null: true
    field :sha256, :string, max_size: 64, index: true
    field :account_number, :string, max_size: 64, blank: true, default: ""
    field :currency_code, :string, max_size: 3, blank: true, default: ""
    field :start_balance, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :end_balance, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :statement_on, :date, blank: true, null: true
    field :line_count, :int, default: 0
    field :duplicate_count, :int, default: 0
    field :statement_id, :big_int, blank: true, null: true
    field :statement_reference, :string, max_size: 40, blank: true, default: ""
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end

# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Format CSV d'un établissement (D-BKI-002) : séparateur de champs,
  # encodage, lignes d'en-tête à sauter, format de date, séparateurs
  # décimal et de milliers, rang (à partir de 1) de chaque colonne. Le
  # montant est lu dans une colonne signée, ou dans deux colonnes « débit »
  # et « crédit ». `ledger_id` : journal financier proposé à l'import.
  # Interne.
  class CsvFormat < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :name, :string, max_size: 100
    field :institution, :string, max_size: 100, blank: true, default: ""
    field :ledger_id, :big_int, blank: true, null: true
    field :separator, :string, max_size: 16, default: "semicolon"
    field :encoding, :string, max_size: 16, default: "utf-8"
    field :skip_lines, :int, default: 1
    field :date_format, :string, max_size: 16, default: "dd/mm/yyyy"
    field :decimal_separator, :string, max_size: 16, default: "comma"
    field :thousands_separator, :string, max_size: 16, default: "none"
    field :date_column, :int
    field :amount_column, :int, blank: true, null: true
    field :debit_column, :int, blank: true, null: true
    field :credit_column, :int, blank: true, null: true
    field :label_column, :int
    field :extra_column, :int, blank: true, null: true
    field :reference_column, :int, blank: true, null: true
    field :counterparty_column, :int, blank: true, null: true
    field :negate, :bool, default: false

    with_timestamp_fields
  end
end

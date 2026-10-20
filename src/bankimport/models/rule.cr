# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Règle de catégorisation (D-BKI-006) : « le libellé contient… », « le
  # montant vaut… », sens (entrée, sortie ou les deux), journal (ou tous),
  # alors telle fiche (`card_code`) ou tel compte (`account`), et tel
  # bénéficiaire (`payee`, facultatif, A-PER-2). Apprise d'un
  # choix de l'utilisateur (`learned`) ou saisie ; `hits` et `last_used_at`
  # comptent les propositions faites. Les règles sont essayées par
  # `position`, puis de la plus précise à la plus générale. Interne.
  class Rule < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :ledger_id, :big_int, blank: true, null: true
    field :label_contains, :string, max_size: 120, blank: true, default: ""
    field :amount, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :direction, :string, max_size: 8, default: "any"
    field :card_code, :string, max_size: 64, blank: true, default: ""
    field :account, :string, max_size: 40, blank: true, default: ""
    field :position, :int, default: 100
    field :active, :bool, default: true
    field :learned, :bool, default: false
    field :hits, :int, default: 0
    field :last_used_at, :date_time, blank: true, null: true
    field :created_by_id, :big_int, blank: true, null: true
    field :payee, :string, max_size: 120, blank: true, default: ""

    with_timestamp_fields
  end
end

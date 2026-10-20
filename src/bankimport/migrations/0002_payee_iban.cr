# SPDX-License-Identifier: AGPL-3.0-or-later

# Bénéficiaire et IBAN de la contrepartie (A-PER-2, A-BKI-2, D-BKI-012,
# D-BKI-013).
#
# * `bankimport_line.payee` : bénéficiaire de la ligne ; `iban` : IBAN de la
#   contrepartie lu dans le fichier. Reprise des lignes existantes : le
#   tiers lu d'un CSV ou d'un QIF (`counterparty`) ; pour un OFX, le
#   libellé (balise `NAME`, que le lecteur prenait déjà pour libellé). Les
#   anciens relevés ne donnent pas d'IBAN : vide.
# * `bankimport_rule.payee` : bénéficiaire posé par la règle (vide : celui
#   du fichier est gardé).
# * `bankimport_csv_format.iban_column` : colonne de l'IBAN, contrôlée
#   comme les autres rangs.
class Migration::Bankimport::V0002 < Marten::Migration
  depends_on :bankimport, "0001_create_bankimport"

  def plan
    add_column :bankimport_line, :payee, :string, max_size: 255, default: ""
    add_column :bankimport_line, :iban, :string, max_size: 34, default: ""
    add_column :bankimport_rule, :payee, :string, max_size: 120, default: ""
    add_column :bankimport_csv_format, :iban_column, :int, null: true

    execute(<<-SQL, "SELECT 1")
      UPDATE bankimport_line l SET payee = CASE WHEN i.kind = 'ofx' THEN l.label ELSE l.counterparty END
        FROM bankimport_import i WHERE i.id = l.import_id
      SQL
    execute(<<-SQL, <<-SQL)
      ALTER TABLE bankimport_csv_format
        ADD CONSTRAINT bankimport_csv_format_iban_column_check CHECK (coalesce(iban_column, 1) >= 1)
      SQL
      ALTER TABLE bankimport_csv_format DROP CONSTRAINT IF EXISTS bankimport_csv_format_iban_column_check
      SQL
  end
end

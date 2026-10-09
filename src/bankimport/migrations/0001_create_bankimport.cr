# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension d'import des relevés bancaires (ADR-011 D6) :
# formats CSV, imports, lignes en attente, règles de catégorisation.
#
# Intégrité en base : genres de fichier, statuts, sens et réglages de format
# contrôlés ; montant d'une ligne non nul ; une ligne transférée porte son
# écriture ; une règle a au moins une condition et une contrepartie ; un
# FITID n'est présent qu'une fois par journal hors doublons écartés. Les
# liens vers le cœur (journal, écriture, pièce jointe, relevé) sont des
# identifiants relus par le contrat, sans clé étrangère (D-BKI-003).
class Migration::Bankimport::V0001 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE bankimport_csv_format
        ADD CONSTRAINT bankimport_csv_format_name_check CHECK (btrim(name) <> ''),
        ADD CONSTRAINT bankimport_csv_format_separator_check CHECK (separator IN ('comma', 'semicolon', 'tab', 'pipe')),
        ADD CONSTRAINT bankimport_csv_format_encoding_check CHECK (encoding IN ('utf-8', 'windows-1252')),
        ADD CONSTRAINT bankimport_csv_format_decimal_check CHECK (decimal_separator IN ('comma', 'dot')),
        ADD CONSTRAINT bankimport_csv_format_thousands_check CHECK (thousands_separator IN ('none', 'space', 'dot', 'comma', 'apostrophe')),
        ADD CONSTRAINT bankimport_csv_format_skip_check CHECK (skip_lines BETWEEN 0 AND 50),
        ADD CONSTRAINT bankimport_csv_format_columns_check CHECK (date_column >= 1 AND label_column >= 1
          AND coalesce(amount_column, 1) >= 1 AND coalesce(debit_column, 1) >= 1 AND coalesce(credit_column, 1) >= 1
          AND coalesce(extra_column, 1) >= 1 AND coalesce(reference_column, 1) >= 1 AND coalesce(counterparty_column, 1) >= 1),
        ADD CONSTRAINT bankimport_csv_format_amount_check CHECK (amount_column IS NOT NULL OR (debit_column IS NOT NULL AND credit_column IS NOT NULL))
      SQL
    {"CREATE UNIQUE INDEX bankimport_csv_format_name_unique ON bankimport_csv_format (lower(name))",
     "DROP INDEX IF EXISTS bankimport_csv_format_name_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE bankimport_import
        ADD CONSTRAINT bankimport_import_kind_check CHECK (kind IN ('csv', 'ofx', 'qif')),
        ADD CONSTRAINT bankimport_import_format_fk FOREIGN KEY (format_id) REFERENCES bankimport_csv_format (id) ON DELETE SET NULL,
        ADD CONSTRAINT bankimport_import_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE bankimport_rule
        ADD CONSTRAINT bankimport_rule_direction_check CHECK (direction IN ('any', 'in', 'out')),
        ADD CONSTRAINT bankimport_rule_condition_check CHECK (btrim(label_contains) <> '' OR amount IS NOT NULL),
        ADD CONSTRAINT bankimport_rule_target_check CHECK ((card_code <> '') <> (account <> '')),
        ADD CONSTRAINT bankimport_rule_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE bankimport_line
        ADD CONSTRAINT bankimport_line_status_check CHECK (status IN ('pending', 'transferred', 'duplicate', 'discarded')),
        ADD CONSTRAINT bankimport_line_amount_check CHECK (amount <> 0),
        ADD CONSTRAINT bankimport_line_transferred_check CHECK ((status = 'transferred') = (entry_id IS NOT NULL)),
        ADD CONSTRAINT bankimport_line_target_check CHECK (card_code = '' OR account = ''),
        ADD CONSTRAINT bankimport_line_import_fk FOREIGN KEY (import_id) REFERENCES bankimport_import (id) ON DELETE CASCADE,
        ADD CONSTRAINT bankimport_line_rule_fk FOREIGN KEY (rule_id) REFERENCES bankimport_rule (id) ON DELETE SET NULL,
        ADD CONSTRAINT bankimport_line_duplicate_fk FOREIGN KEY (duplicate_of_id) REFERENCES bankimport_line (id) ON DELETE SET NULL,
        ADD CONSTRAINT bankimport_line_transferred_by_fk FOREIGN KEY (transferred_by_id) REFERENCES auth_user (id)
      SQL
    {"CREATE UNIQUE INDEX bankimport_line_fitid_unique ON bankimport_line (ledger_id, fitid) " \
     "WHERE fitid <> '' AND status <> 'duplicate'", "DROP INDEX IF EXISTS bankimport_line_fitid_unique"},
    {"CREATE INDEX bankimport_line_status_idx ON bankimport_line (ledger_id, status, date)",
     "DROP INDEX IF EXISTS bankimport_line_status_idx"},
  ]

  def plan
    create_table :bankimport_csv_format do
      column :id, :big_int, primary_key: true, auto: true
      column :name, :string, max_size: 100
      column :institution, :string, max_size: 100, default: ""
      column :ledger_id, :big_int, null: true
      column :separator, :string, max_size: 16, default: "semicolon"
      column :encoding, :string, max_size: 16, default: "utf-8"
      column :skip_lines, :int, default: 1
      column :date_format, :string, max_size: 16, default: "dd/mm/yyyy"
      column :decimal_separator, :string, max_size: 16, default: "comma"
      column :thousands_separator, :string, max_size: 16, default: "none"
      column :date_column, :int
      column :amount_column, :int, null: true
      column :debit_column, :int, null: true
      column :credit_column, :int, null: true
      column :label_column, :int
      column :extra_column, :int, null: true
      column :reference_column, :int, null: true
      column :counterparty_column, :int, null: true
      column :negate, :bool, default: false
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :bankimport_import do
      column :id, :big_int, primary_key: true, auto: true
      column :ledger_id, :big_int, index: true
      column :kind, :string, max_size: 8
      column :format_id, :big_int, null: true
      column :filename, :string, max_size: 255
      column :attachment_id, :big_int, null: true
      column :sha256, :string, max_size: 64, index: true
      column :account_number, :string, max_size: 64, default: ""
      column :currency_code, :string, max_size: 3, default: ""
      column :start_balance, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :end_balance, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :statement_on, :date, null: true
      column :line_count, :int, default: 0
      column :duplicate_count, :int, default: 0
      column :statement_id, :big_int, null: true
      column :statement_reference, :string, max_size: 40, default: ""
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :bankimport_rule do
      column :id, :big_int, primary_key: true, auto: true
      column :ledger_id, :big_int, null: true
      column :label_contains, :string, max_size: 120, default: ""
      column :amount, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :direction, :string, max_size: 8, default: "any"
      column :card_code, :string, max_size: 64, default: ""
      column :account, :string, max_size: 40, default: ""
      column :position, :int, default: 100
      column :active, :bool, default: true
      column :learned, :bool, default: false
      column :hits, :int, default: 0
      column :last_used_at, :date_time, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :bankimport_line do
      column :id, :big_int, primary_key: true, auto: true
      column :import_id, :big_int, index: true
      column :ledger_id, :big_int, index: true
      column :position, :int
      column :date, :date
      column :amount, :decimal, max_digits: 20, decimal_places: 4
      column :label, :string, max_size: 255
      column :extra, :text, default: ""
      column :reference, :string, max_size: 64, default: ""
      column :fitid, :string, max_size: 255, default: ""
      column :counterparty, :string, max_size: 255, default: ""
      column :fingerprint, :string, max_size: 64, index: true
      column :status, :string, max_size: 16, default: "pending"
      column :card_code, :string, max_size: 64, default: ""
      column :account, :string, max_size: 40, default: ""
      column :rule_id, :big_int, null: true
      column :match_line_id, :big_int, null: true
      column :duplicate_of_id, :big_int, null: true
      column :recorded_entry_id, :big_int, null: true
      column :entry_id, :big_int, null: true, index: true
      column :reversed_entry_id, :big_int, null: true
      column :error_key, :string, max_size: 200, default: ""
      column :error_params, :text, default: ""
      column :transferred_by_id, :big_int, null: true
      column :transferred_at, :date_time, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end

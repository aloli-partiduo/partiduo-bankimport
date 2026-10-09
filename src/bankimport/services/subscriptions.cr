# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Abonnés des événements du cœur (ADR-003 D7), appelés dans la transaction
  # de l'opération, l'extension active. Interne.
  module Subscriptions
    # `entry.cancelled` (D-BKI-009) : l'écriture d'une ligne transférée est
    # extournée — la ligne redevient à traiter (contrepartie gardée,
    # lettrage proposé retiré) et garde la trace de l'écriture annulée.
    def self.entry_cancelled(event : Partiduo::Events::Event) : Nil
      entry_id = event["entry_id"].to_i64
      Line.filter(entry_id: entry_id, status: "transferred").each do |row|
        row.status = "pending"
        row.reversed_entry_id = entry_id
        row.entry_id = nil
        row.match_line_id = nil
        row.transferred_by_id = nil
        row.transferred_at = nil
        row.save!
      end
    end
  end
end

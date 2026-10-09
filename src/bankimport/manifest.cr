# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension d'import des relevés bancaires (ADR-003 D2,
# ADR-011 D6).
#
# * Dépendance : `ACCOUNTING` — les lignes importées deviennent des
#   écritures d'un journal financier, passées par le service d'écriture du
#   module, et le pointage reprend son rapprochement.
# * Permissions (D4) : `bankimport.read` (zone d'attente, historique),
#   `bankimport.import` (importer, choisir la contrepartie, écarter,
#   transférer, pointer), `bankimport.admin` (formats CSV, règles,
#   suppression d'un import, purge). Le contrat du cœur exige en plus ses
#   propres droits : `core.attachment.write` pour conserver le fichier,
#   `accounting.entry.post` et l'écriture dans le journal pour transférer,
#   `accounting.matching.write` pour pointer (D-BKI-004).
# * Menu (D6 d'ADR-003) : rubrique « Relevés bancaires » entre la Saisie et
#   la Consultation ; formats et règles sous « Paramètres ».
# * Abonnement : `entry.cancelled` — une écriture transférée puis extournée
#   rend sa ligne de nouveau à traiter (D-BKI-009).
Partiduo::Modules.register do
  code "BANKIMPORT"
  name "bankimport.module.name"
  version Bankimport::VERSION
  requires_core "~> 0.1"
  depends_on "ACCOUNTING"

  permission "bankimport.read"
  permission "bankimport.import"
  permission "bankimport.admin"

  menu "BANKIMPORT", order: 35, permission: "bankimport.read"
  menu "BANKIMPORT_IMPORT", parent: "BANKIMPORT", order: 10, route: "bankimport:import", permission: "bankimport.import"
  menu "BANKIMPORT_LINES", parent: "BANKIMPORT", order: 20, route: "bankimport:lines", permission: "bankimport.read"
  menu "BANKIMPORT_HISTORY", parent: "BANKIMPORT", order: 30, route: "bankimport:imports", permission: "bankimport.read"
  menu "BANKIMPORT_FORMATS", parent: "SETTINGS", order: 97, route: "bankimport:formats", permission: "bankimport.admin"
  menu "BANKIMPORT_RULES", parent: "SETTINGS", order: 98, route: "bankimport:rules", permission: "bankimport.admin"

  ui "bulma", path: "ui/bulma"

  on("entry.cancelled") { |event| Bankimport::Subscriptions.entry_cancelled(event) }
end

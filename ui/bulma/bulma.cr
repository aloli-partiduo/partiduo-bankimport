# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension d'import des relevés bancaires (ADR-005 D4,
# ADR-011 D6) : import d'un fichier (aperçu puis import), lignes à traiter
# (contrepartie par ligne en HTMX, actions groupées), historique des
# imports et pointage du relevé, formats CSV, règles de catégorisation.
# Montée par `partiduo-ui-bulma` sous `/ext/BANKIMPORT/` (ADR-003 D3). La
# distribution la requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-bankimport"
# require "partiduo-bankimport/ui/bulma"
# ```
#
# puis ajoute `Bankimport::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Bankimport::Api` et
# `Partiduo::Api` (vérifié par `spec/architecture/conventions_spec.cr`) ;
# le contrôle d'accès est fait par l'interface, avant le handler, à partir
# du montage, puis par le contrat.
require "base64"

require "../../src/partiduo-bankimport"

require "./presenters"
require "./handlers/base"
require "./handlers/**"
require "./dashboard_tile"

module Bankimport
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/bankimport/`), fichiers statiques (`assets/bankimport/`)
    # et libellés d'écran (`locales/`, clés `bankimport_ui.*`).
    class App < Marten::App
      label "bankimport_ui"
    end

    INSTALLED_APPS = [Bankimport::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/BANKIMPORT/`, nommées `bankimport:<nom>` :
    # celles que citent les menus du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Bankimport::Ui::IndexHandler, name: "index"
      path "/import", Bankimport::Ui::ImportHandler, name: "import"
      path "/lines", Bankimport::Ui::LinesHandler, name: "lines"
      path "/lines/action", Bankimport::Ui::LinesActionHandler, name: "lines_action"
      path "/lines/<id:int>", Bankimport::Ui::LineHandler, name: "line"
      path "/lines/<id:int>/clear", Bankimport::Ui::LineClearHandler, name: "line_clear"
      path "/lines/<id:int>/relink", Bankimport::Ui::LineRelinkHandler, name: "line_relink"
      path "/imports", Bankimport::Ui::ImportsHandler, name: "imports"
      path "/imports/<id:int>", Bankimport::Ui::ImportDetailHandler, name: "import_detail"
      path "/imports/<id:int>/file", Bankimport::Ui::ImportFileHandler, name: "import_file"
      path "/imports/<id:int>/reconcile", Bankimport::Ui::ImportReconcileHandler, name: "import_reconcile"
      path "/imports/<id:int>/delete", Bankimport::Ui::ImportDeleteHandler, name: "import_delete"
      path "/purge", Bankimport::Ui::PurgeHandler, name: "purge"
      path "/formats", Bankimport::Ui::FormatsHandler, name: "formats"
      path "/formats/new", Bankimport::Ui::FormatNewHandler, name: "format_new"
      path "/formats/<id:int>", Bankimport::Ui::FormatEditHandler, name: "format_edit"
      path "/formats/<id:int>/delete", Bankimport::Ui::FormatDeleteHandler, name: "format_delete"
      path "/rules", Bankimport::Ui::RulesHandler, name: "rules"
      path "/rules/new", Bankimport::Ui::RuleNewHandler, name: "rule_new"
      path "/rules/<id:int>", Bankimport::Ui::RuleEditHandler, name: "rule_edit"
      path "/rules/<id:int>/delete", Bankimport::Ui::RuleDeleteHandler, name: "rule_delete"
    end

    # Routes qui importent ou traitent les lignes : `bankimport.import` ;
    # paramétrage, suppression et purge : `bankimport.admin` ; les autres :
    # `bankimport.read`. Le contrat vérifie encore les permissions du cœur
    # (pièce jointe, écriture, rapprochement).
    IMPORT_ROUTES = %w[import lines_action line line_clear line_relink import_reconcile]
    ADMIN_ROUTES  = %w[import_delete purge formats format_new format_edit format_delete rules rule_new rule_edit
      rule_delete]
  end
end

PartiduoUi::Extensions.mount Bankimport::CODE, Bankimport::Ui::ROUTES, permission: Bankimport::Api::READ,
  permissions: Bankimport::Ui::IMPORT_ROUTES.to_h { |route| {route, Bankimport::Api::IMPORT} }
    .merge(Bankimport::Ui::ADMIN_ROUTES.to_h { |route| {route, Bankimport::Api::ADMIN} })

# Compteur du menu « Lignes à traiter » et ligne de « À traiter » du
# tableau de bord du dossier.
PartiduoUi::Extensions.counter("BANKIMPORT_LINES", route: "bankimport:lines", todo: "bankimport_ui.todo", tone: "warn") do |actor|
  Bankimport::Api.pending_count(actor)
end

# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Ui
    # Tuile « Relevés bancaires » des tableaux de bord du dossier : lignes à
    # traiter, dont celles qui ont une contrepartie proposée, et date de la
    # plus ancienne. Rien si aucune ligne n'attend, si l'extension est
    # inactive ou l'acteur sans droit.
    module Tile
      def self.for(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) : PartiduoUi::Dashboard::Tile?
        view = Api.tile(actor) || return
        return if view.pending_count.zero?
        PartiduoUi::Dashboard::Tile.new(Bankimport::CODE, I18n.t("bankimport_ui.tile.label"), view.pending_count.to_s,
          sub: I18n.t("bankimport_ui.tile.sub", count: view.ready_count),
          alert: view.oldest_date.try { |date| I18n.t("bankimport_ui.tile.oldest", date: fmt.date(date)) },
          url: Ui.url("lines"))
      end
    end
  end
end

# Point d'accroche de l'interface commune (`PartiduoUi::Extensions.tile`) :
# appelé seulement quand l'extension est active.
PartiduoUi::Extensions.tile Bankimport::CODE do |actor, fmt|
  Bankimport::Ui::Tile.for(actor, fmt).try { |tile| [tile] } || [] of PartiduoUi::Dashboard::Tile
end

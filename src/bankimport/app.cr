# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"
require "digest/sha256"

require "./manifest"
require "./models/**"
require "./parsers/parsed"
require "./parsers/**"
require "./services/**"
require "./api/**"

# Extension d'import des relevés bancaires de Partiduo (ADR-011 D6) :
# fichiers CSV paramétrables par établissement, OFX et QIF ; lignes
# proposées dans une zone d'attente, doublons écartés, règles de
# catégorisation apprises des choix de l'utilisateur, passage dans un
# journal financier par `Partiduo::Api::Accounting.post_financial`,
# pointage par `reconcile`, historique des imports. Même plan qu'une
# application du cœur (DECISIONS C1 du cœur) : `manifest.cr`, `models/`,
# `migrations/`, `parsers/` et `services/` (internes), `api/` (contrat
# public `Bankimport::Api`), `locales/`.
module Bankimport
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Code du registre (ADR-003 D2) : `bankimport` dans `PARTIDUO_MODULES`.
  CODE = "BANKIMPORT"

  # Application Marten du métier : modèles (tables `bankimport_*`),
  # migrations et libellés.
  class App < Marten::App
    label "bankimport"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Bankimport::App] of Marten::Apps::Config.class
end

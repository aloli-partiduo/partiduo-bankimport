# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-bankimport` : le métier de l'extension
# d'import des relevés bancaires (manifeste, modèles, lecture des fichiers,
# abonnements, contrat `Bankimport::Api`), sans interface. L'interface Bulma
# est dans `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-bankimport/ui/bulma"`.
#
# La distribution ajoute ensuite `Bankimport::INSTALLED_APPS` à ses
# applications Marten, et `require "partiduo-bankimport/cli"` à sa ligne de
# commande (migrations).
require "partiduo"

require "./bankimport/app"

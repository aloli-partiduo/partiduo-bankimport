# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Règles de catégorisation (D-BKI-006) : application aux lignes à traiter
  # sans contrepartie, et apprentissage d'une règle à partir d'un choix de
  # l'utilisateur. Une règle *propose* : la ligne reste à traiter tant que
  # l'utilisateur ne la transfère pas. Une règle peut aussi poser le
  # bénéficiaire (A-PER-2, D-BKI-012). Sans règle, l'IBAN de la contrepartie
  # lu dans le fichier propose la fiche qui le porte (D-BKI-013). Interne.
  module Categorizer
    # Nombre de mots gardés du libellé pour une règle apprise.
    LEARNED_WORDS = 4

    # Texte comparé : majuscules, sans accents, espaces réduites.
    def self.normalize(text : String) : String
      text.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").upcase.gsub(/\s+/, " ").strip
    end

    # Clé apprise d'un libellé : ses premiers mots sans chiffre (dates,
    # numéros de carte, références et montants changent d'un mois à
    # l'autre), au plus `LEARNED_WORDS` ; vide si rien ne reste.
    def self.learned_key(label : String) : String
      words = normalize(label).split(' ').reject { |word| word.empty? || word.matches?(/\d/) || word.size < 2 }
      words.first(LEARNED_WORDS).join(' ')[0, 120]
    end

    def self.direction(amount : BigDecimal) : String
      amount > 0 ? "in" : "out"
    end

    # La règle s'applique-t-elle à la ligne ?
    def self.matches?(rule : Rule, line : Line) : Bool
      return false unless rule.active
      return false if (ledger = rule.ledger_id) && ledger != line.ledger_id
      direction = rule.direction.to_s
      return false if direction != "any" && direction != direction(line.amount!)
      if amount = rule.amount
        return false unless amount == line.amount!.abs
      end
      needle = normalize(rule.label_contains.to_s)
      return true if needle.empty?
      haystack = normalize([line.label, line.extra, line.counterparty, line.payee].join(' '))
      haystack.includes?(needle)
    end

    # Règles actives, dans l'ordre d'essai : position, puis montant donné,
    # puis libellé le plus long, puis règle saisie avant règle apprise.
    def self.ordered_rules : Array(Rule)
      Rule.filter(active: true).to_a.sort_by! do |rule|
        {rule.position!.to_i32, rule.amount ? 0 : 1, -rule.label_contains.to_s.size, rule.learned ? 1 : 0, rule.id!.to_i64}
      end
    end

    # Propose une contrepartie aux lignes à traiter qui n'en ont pas : la
    # première règle qui s'applique (et son bénéficiaire, s'il est donné),
    # à défaut la fiche de l'IBAN de la contrepartie. Rend le nombre de
    # lignes catégorisées.
    def self.apply(actor : Partiduo::Api::Actor, lines : Array(Line), rules : Array(Rule) = ordered_rules) : Int32
      count = 0
      now = Partiduo::Config.now
      cards = {} of String => String?
      lines.each do |line|
        next unless line.status == "pending" && line.card_code.to_s.empty? && line.account.to_s.empty?
        if rule = rules.find { |candidate| matches?(candidate, line) }
          line.card_code = rule.card_code.to_s
          line.account = rule.account.to_s
          line.rule_id = rule.id
          rule.payee.to_s.presence.try { |payee| line.payee = payee }
          line.save!
          rule.hits = rule.hits!.to_i32 + 1
          rule.last_used_at = now
          rule.save!
          count += 1
        elsif (iban = line.iban.to_s.presence) && (code = cards.put_if_absent(iban) { card_by_iban(actor, iban) })
          line.card_code = code
          line.rule_id = nil
          line.save!
          count += 1
        end
      end
      count
    end

    # Fiche active qui porte cet IBAN (`CardQuery#iban`, A-BKI-2), si elle
    # est seule et que l'acteur lit les fiches ; `nil` sinon.
    def self.card_by_iban(actor : Partiduo::Api::Actor, iban : String) : String?
      found = Partiduo::Api::Cards.cards(actor, Partiduo::Api::Cards::CardQuery.new(iban: iban, limit: 2))
      found.size == 1 ? found.first.code : nil
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Apprend une règle du choix fait pour `line` : même clé de libellé et
    # même sens ; `payee` : bénéficiaire choisi par l'utilisateur, appris
    # avec la contrepartie (`nil` : la règle garde le sien). Rien n'est
    # appris si la règle qui s'applique déjà à la ligne donne ce choix. Une
    # règle apprise de même clé est mise à jour ; une règle saisie à la main
    # n'est jamais modifiée. Rend la règle, ou `nil` si le libellé ne donne
    # pas de clé.
    def self.learn(actor : Partiduo::Api::Actor, line : Line, payee : String? = nil) : Rule?
      current = ordered_rules.find { |rule| matches?(rule, line) }
      if current && current.card_code == line.card_code && current.account == line.account &&
         (payee.nil? || current.payee.to_s == payee)
        return current
      end
      key = learned_key(line.label.to_s)
      return if key.empty?
      direction = direction(line.amount!)
      rule = Rule.filter(learned: true, label_contains: key, direction: direction, amount__isnull: true, ledger_id__isnull: true).first ||
             Rule.new(learned: true, label_contains: key, direction: direction, position: 100, active: true,
               created_by_id: actor.user_id, hits: 0)
      rule.card_code = line.card_code.to_s
      rule.account = line.account.to_s
      payee.try { |value| rule.payee = value }
      rule.active = true
      rule.save!
      rule
    end

    # Écritures ouvertes de la fiche de la ligne, de même montant, qu'un
    # transfert pourrait lettrer : la créance d'un client pour une entrée,
    # la dette d'un fournisseur pour une sortie.
    def self.open_items(actor : Partiduo::Api::Actor, line : Line) : Array(Api::OpenItemView)
      code = line.card_code.to_s
      return [] of Api::OpenItemView if code.empty?
      query = Partiduo::Api::Accounting::StatementQuery.new(card: code, unmatched_only: true)
      statement = Partiduo::Api::Accounting.account_statement(actor, query)
      amount = line.amount!.abs
      statement.lines.compact_map do |item|
        next unless item.matching_id.nil?
        open = line.amount! > 0 ? item.debit : item.credit
        next unless open == amount
        Api::OpenItemView.new(line_id: item.line_id, entry_id: item.entry_id, date: item.date, ledger_code: item.ledger_code,
          receipt: item.receipt, label: item.label, amount: open)
      end
    rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
      [] of Api::OpenItemView
    end
  end
end

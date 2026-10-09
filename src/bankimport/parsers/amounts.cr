# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Parsers
    # Lecture des montants (D-BKI-008) : en `BigDecimal`, jamais en
    # flottant. Signe en tête ou en fin (`12,50-`), parenthèses comptables,
    # symbole ou code de la devise et espaces (insécables comprises)
    # ignorés.
    module Amounts
      SEPARATORS = {"comma" => ',', "dot" => '.'}
      THOUSANDS  = {"none" => nil, "space" => ' ', "dot" => '.', "comma" => ',', "apostrophe" => '\''}

      # Montant écrit avec les séparateurs donnés ; `decimal` nul : séparateur
      # reconnu (voir `guess`). `nil` si le texte n'est pas un montant.
      def self.parse(text : String, decimal : Char? = nil, thousands : Char? = nil) : BigDecimal?
        value = text.strip
        return if value.empty?
        value, negative = sign(value, thousands, decimal)
        value = decimal ? normalize(value, decimal) : guess(value)
        return if value.nil? || !value.matches?(/\A\d+(\.\d+)?\z/)
        amount = BigDecimal.new(value)
        negative ? -amount : amount
      rescue InvalidBigDecimalException
        nil
      end

      # Chiffres du montant, sans devise, espaces ni séparateur de milliers,
      # et son signe : parenthèses comptables, `-` en tête ou en fin.
      private def self.sign(text : String, thousands : Char?, decimal : Char?) : {String, Bool}
        value = text
        negative = false
        if value.starts_with?('(') && value.ends_with?(')')
          negative = true
          value = value[1..-2]
        end
        value = value.gsub(/[\s\x{00A0}\x{202F}]|€|EUR|\$|£|CHF/i, "")
        value = value.gsub(thousands, "") if thousands && thousands != decimal
        if value.ends_with?('-') || value.starts_with?('-')
          negative = !negative
        end
        {value.strip('+').strip('-'), negative}
      end

      # Séparateur décimal reconnu (OFX, QIF) : le dernier de `,` et `.`
      # quand les deux sont présents (l'autre sépare les milliers) ; un seul,
      # présent une fois, est décimal ; répété, il sépare les milliers.
      def self.guess(value : String) : String?
        comma = value.rindex(',')
        dot = value.rindex('.')
        if comma && dot
          return normalize(value, comma > dot ? ',' : '.')
        end
        separator = comma ? ',' : (dot ? '.' : nil)
        return value if separator.nil?
        return value.delete(separator) if value.count(separator) > 1
        normalize(value, separator)
      end

      private def self.normalize(value : String, decimal : Char) : String?
        other = decimal == ',' ? '.' : ','
        value = value.delete(other) if value.includes?(decimal)
        parts = value.split(decimal)
        return if parts.size > 2
        parts.size == 2 ? "#{parts[0].empty? ? "0" : parts[0]}.#{parts[1]}" : value
      end
    end
  end
end

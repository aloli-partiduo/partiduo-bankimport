# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Parsers
    # Décodage du contenu d'un fichier : UTF-8 (marque d'ordre retirée) ou
    # Windows-1252, le jeu de nombreux exports bancaires (D-BKI-002). Le
    # décodage est fait en Crystal, sans iconv : sa table tient en 32
    # caractères au-delà de Latin-1.
    module Text
      ENCODINGS = %w[utf-8 windows-1252]

      # Caractères 0x80 à 0x9F de Windows-1252 (Latin-1 au-delà).
      CP1252 = {
        0x80 => '€', 0x82 => '‚', 0x83 => 'ƒ', 0x84 => '„', 0x85 => '…', 0x86 => '†', 0x87 => '‡', 0x88 => 'ˆ',
        0x89 => '‰', 0x8A => 'Š', 0x8B => '‹', 0x8C => 'Œ', 0x8E => 'Ž', 0x91 => '‘', 0x92 => '’', 0x93 => '“',
        0x94 => '”', 0x95 => '•', 0x96 => '–', 0x97 => '—', 0x98 => '˜', 0x99 => '™', 0x9A => 'š', 0x9B => '›',
        0x9C => 'œ', 0x9E => 'ž', 0x9F => 'Ÿ',
      }

      def self.decode(bytes : Bytes, encoding : String) : String
        text = encoding == "windows-1252" ? cp1252(bytes) : utf8(bytes)
        text.lchop('\u{FEFF}')
      end

      # UTF-8 s'il est valide, sinon Windows-1252 : pour un OFX ou un QIF
      # dont l'en-tête ne dit rien de son jeu de caractères.
      def self.guess(bytes : Bytes) : String
        text = String.new(bytes)
        (text.valid_encoding? ? text : cp1252(bytes)).lchop('\u{FEFF}')
      end

      def self.utf8(bytes : Bytes) : String
        String.new(bytes).scrub
      end

      def self.cp1252(bytes : Bytes) : String
        String.build(bytes.size) do |io|
          bytes.each do |byte|
            io << (CP1252[byte.to_i32]? || byte.unsafe_chr)
          end
        end
      end
    end
  end
end

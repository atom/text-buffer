module.exports = (character1, character2) ->
  charCodeA = character1.charCodeAt(0)
  charCodeB = character2.charCodeAt(0)
  isSurrogatePair(charCodeA, charCodeB) or
    isVariationSequence(charCodeA, charCodeB) or
    isCombinedCharacter(charCodeA, charCodeB)

isCombinedCharacter = (charCodeA, charCodeB) ->
  not isCombiningCharacter(charCodeA) and isCombiningCharacter(charCodeB)

isSurrogatePair = (charCodeA, charCodeB) ->
  isHighSurrogate(charCodeA) and isLowSurrogate(charCodeB)

isVariationSequence = (charCodeA, charCodeB) ->
  not isVariationSelector(charCodeA) and isVariationSelector(charCodeB)

isHighSurrogate = (charCode) ->
  0xD800 <= charCode <= 0xDBFF

isLowSurrogate = (charCode) ->
  0xDC00 <= charCode <= 0xDFFF

isVariationSelector = (charCode) ->
  0xFE00 <= charCode <= 0xFE0F

isCombiningCharacter = (charCode) ->
  0x0300 <= charCode <= 0x036F or
  0x1AB0 <= charCode <= 0x1AFF or
  0x1DC0 <= charCode <= 0x1DFF or
  0x20D0 <= charCode <= 0x20FF or
  0xFE20 <= charCode <= 0xFE2F
